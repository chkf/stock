import Foundation

public struct Advice: Codable {
    public let decision: Decision
    public let next, status, action: String
    public let plan: Plan?
    public let reason: String?
}

extension StrategyEngine {
    public func advice(_ strategy: String, requested: String, account: Account) throws -> Advice {
        _ = try sessions.index(requested)
        let date = min(market.as_of, requested)
        let decision = try self.decision(strategy, on: date), next = try sessions.next(date)
        do {
            guard date == requested else { throw ResearchError("行情滞后：这些目标只对应历史日期，不生成当前操作数量") }
            guard date == account.as_of else {
                throw ResearchError("请更新或确认本日账户；当前现金/可卖份额仍是 " + account.as_of)
            }
            let plan = try Planning.make(market: market, date: date, next: next, account: account, weights: decision.weights)
            if decision.route == "MV" {
                // BLAS implementations may differ by a few ulps at the active 35% constraint.
                // Check both funding priorities when two capped holdings compete for scarce cash.
                let capped=Set(decision.weights.filter { abs($0.value-0.35) <= 16*Double(0.35).ulp }.map(\.key))
                if capped.count > 1 {
                    let other=try Planning.make(market:market,date:date,next:next,account:account,weights:decision.weights,upperBoundFirst:capped)
                    let compare=Dictionary(uniqueKeysWithValues:other.orders.map { ($0.symbol,$0) })
                    guard plan.orders.allSatisfy({ row in
                        guard let second=compare[row.symbol] else { return false }
                        return row.quantity==second.quantity && row.funded_quantity==second.funded_quantity &&
                            row.conditional_quantity==second.conditional_quantity && row.deferred_quantity==second.deferred_quantity
                    }) else { throw ResearchError("两只 ETF 同在 35% 上限，末位精度影响现金分配，当前仅展示市场权重。") }
                }
            }
            return Advice(decision: decision, next: next, status: "ready", action: plan.action, plan: plan, reason: nil)
        } catch {
            return Advice(decision: decision, next: next, status: "blocked", action: "UNKNOWN", plan: nil,
                          reason: error.localizedDescription)
        }
    }
}

public struct ExitLock: Codable {
    public let symbol, date: String
    public let high, close, threshold: Double
}

/// A new native record. Python tracking contracts remain immutable provenance.
public struct TrackingState: Codable {
    public let version: String
    public var decision: Decision
    public var through, selection: String
    public var highs: [String: Double]
    public var locks: [String: ExitLock]
    public var events: [ExitLock]
    public var quantities, heldLast: [String: Int]
}

extension StrategyEngine {
    public func begin(_ strategy: String, account: Account) throws -> TrackingState {
        try account.validate()
        guard account.confirmed else { throw ResearchError("持续跟踪需要同日已确认的真实账户") }
        let date = account.as_of
        let d = try decision(strategy, on: date)
        let plan = try Planning.make(market: market, date: date, next: sessions.next(date), account: account, weights: d.weights)
        var highs = [String: Double]()
        let positions = account.positions.filter { $0.quantity > 0 }
        if d.protection?.isEmpty == false || ["MOM", "BANK", "GROUP"].contains(d.route) {
            for p in positions where protected(d, p.symbol) {
                guard let px = market.securities[p.symbol]?.bars[date]?.close else { throw ResearchError("缺持仓保护行情") }
                highs[p.symbol] = px
            }
        }
        return TrackingState(version: "swift-advice-1", decision: d, through: date, selection: date,
                             highs: highs, locks: [:], events: [], quantities: plan.requested_quantities,
                             heldLast: Dictionary(uniqueKeysWithValues: positions.map { ($0.symbol, $0.quantity) }))
    }

    public func advance(_ old: TrackingState, account: Account) throws -> TrackingState {
        try account.validate()
        let date = account.as_of
        guard old.version == "swift-advice-1", account.confirmed, date >= old.through, date <= market.as_of else {
            throw ResearchError("状态版本、行情日期或账户确认不满足续接条件")
        }
        let first = try sessions.index(old.through), last = try sessions.index(date)
        var state = old
        let positions = account.positions.filter { $0.quantity > 0 }
        let held = Dictionary(uniqueKeysWithValues: positions.map { ($0.symbol, $0.quantity) })
        let additions = positions.filter { old.heldLast[$0.symbol] == nil && market.securities[$0.symbol] != nil }
        let newSymbols = Set(additions.map(\.symbol))
        for p in additions {
            guard let entry = p.entry_date, entry >= old.through,
                  let price = market.securities[p.symbol]?.bars[entry]?.close else {
                throw ResearchError("\(p.symbol) 新增持仓需补充有效的连续持仓起始日和行情")
            }
            state.highs[p.symbol] = price
        }
        let repeatDay = first == last
        let days = sessions.days[(repeatDay ? last : first + 1)...last]
        var selected = false
        for d in days {
            state.highs = state.highs.filter { held[$0.key] != nil }
            if state.decision.protection?.isEmpty == false || ["MOM", "BANK", "GROUP"].contains(state.decision.route) {
                for p in positions where protected(state.decision, p.symbol) {
                    guard let sec = market.securities[p.symbol] else { continue }
                    if newSymbols.contains(p.symbol) && (p.entry_date ?? "") > d { continue }
                    guard let close = sec.bars[d]?.close else { throw ResearchError("\(p.symbol) 缺少持仓保护所需的行情") }
                    var high = state.highs[p.symbol] ?? close
                    if !repeatDay && state.highs[p.symbol] != nil && (!newSymbols.contains(p.symbol) || d > (p.entry_date ?? "")) {
                        for e in sec.events where e.date == d {
                            let factor = e.share_factor ?? 1
                            guard factor.isFinite && factor > 0 else { throw ResearchError("拆合比例异常") }
                            high = (high - (e.cash_per_share ?? 0)) / factor
                        }
                    }
                    high = max(high, close)
                    state.highs[p.symbol] = high
                    let limit = (1 - (state.decision.exitDrawdown ?? 0.2)) * high
                    if close <= limit + 1e-10 && state.locks[p.symbol] == nil {
                        let event = ExitLock(symbol: p.symbol, date: d, high: high, close: close, threshold: limit)
                        state.locks[p.symbol] = event
                        state.events.append(event)
                        state.quantities[p.symbol] = 0
                    }
                }
            }
            if !repeatDay, try review(old.decision.strategy,on:d) {
                state.locks = state.locks.filter { held[$0.key] != nil || d <= $0.value.date }
                let prior = state.decision
                state.decision = try decision(old.decision.strategy, on: d, previousState: prior.marketState,
                                              previousSectors: prior.sectorStates ?? [:])
                if prior.route != state.decision.route && (state.decision.resetHighOnEntry ?? ["MOM", "BANK"].contains(state.decision.route)) {
                    state.highs = [:]
                    for p in positions where !newSymbols.contains(p.symbol) || (p.entry_date ?? "") <= d {
                        state.highs[p.symbol] = market.securities[p.symbol]?.bars[d]?.close
                    }
                }
                state.selection = d
                selected = true
            }
        }
        if selected {
            let plan = try Planning.make(market: market, date: date, next: sessions.next(date), account: account,
                                         weights: state.decision.weights, forced: Set(state.locks.keys))
            state.quantities = plan.requested_quantities
        }
        for s in state.locks.keys { state.quantities[s] = 0 }
        state.through = date
        state.heldLast = held
        return state
    }
}
