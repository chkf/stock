import Foundation

public struct Fees: Codable {
    public var commission_rate = 0.0003, minimum_commission = 5.0, slippage_rate = 0.0005
    public init() {}
}
public struct Position: Codable {
    public let symbol: String
    public let quantity, available: Int
    public let close: Double?
    public let entry_date: String?
    public init(symbol: String, quantity: Int, available: Int, close: Double? = nil, entry: String? = nil) {
        self.symbol = symbol; self.quantity = quantity; self.available = available
        self.close = close; self.entry_date = entry
    }
}
public struct Account: Codable {
    public var as_of: String
    public let confirmed: Bool
    public let cash: Double
    public let positions: [Position]
    public let fees: Fees
    public init(date: String, cash: Double, positions: [Position] = [], confirmed: Bool = false, fees: Fees = Fees()) {
        self.as_of = date; self.cash = cash; self.positions = positions; self.confirmed = confirmed; self.fees = fees
    }
    public func validate() throws {
        guard AccountInput.validDate(as_of), cash.isFinite, cash >= (confirmed ? 0 : 1000), cash <= 100_000_000,
              confirmed || positions.isEmpty,
              (0...0.01).contains(fees.commission_rate), (0...100).contains(fees.minimum_commission),
              (0...0.02).contains(fees.slippage_rate) else { throw ResearchError("账户现金或费用超出原版范围") }
        var seen = Set<String>()
        for p in positions {
            guard (try AccountInput.symbol(p.symbol)) == p.symbol, p.quantity >= 0, p.available >= 0, p.available <= p.quantity, seen.insert(p.symbol).inserted,
                  p.close.map({ $0.isFinite && $0 > 0 }) ?? true,
                  p.entry_date.map({ AccountInput.validDate($0) && $0 <= as_of }) ?? true else { throw ResearchError("持仓、可卖份额或起始日无效") }
        }
    }
}
public struct OrderCosts: Codable {
    public var commission = 0.0, stamp_tax = 0.0, transfer_fee = 0.0, slippage = 0.0, total = 0.0
    public var order_quantities = [Int]()
}
public struct Intention: Codable {
    public let symbol, side: String
    public let quantity, requested_quantity, deferred_quantity: Int
    public let funded_quantity, conditional_quantity: Int?
    public let reference_price, reference_value: Double
    public let costs: OrderCosts
}
public struct Plan: Codable {
    public let equity, initial_cash, estimated_costs, projected_cash: Double
    public let requested_quantities: [String: Int]
    public let orders: [Intention]
    public let actual_trades_recorded, projected_cash_conditional_on_sales: Bool
    public var action: String { orders.contains { $0.quantity > 0 } ? "ADJUST" : orders.isEmpty ? "HOLD" : "WAIT" }
}

public enum Planning {
    static func money(_ x: Double) -> Double {
        // Python Decimal(str(value)), followed by quantize(".01", ROUND_HALF_UP).
        var decimal = Decimal(string: String(x), locale: Locale(identifier: "en_US_POSIX"))!
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 2, .plain)
        return Double(NSDecimalNumber(decimal: rounded).stringValue)!
    }

    static func costs(_ q: Int, _ px: Double, sell: Bool, symbol: String, date: String, fees: Fees) throws -> OrderCosts {
        guard date >= "2016-01-01", symbol.hasSuffix(".SH") || symbol.hasSuffix(".SZ") else {
            throw ResearchError("日期或证券交易规则未获支持")
        }
        if symbol.hasPrefix("68") && date < "2019-07-22" { throw ResearchError("科创板规则尚未生效") }
        let etf = ["51", "52", "56", "58", "159"].contains { symbol.hasPrefix($0) }
        let cap = symbol.hasPrefix("68") || (symbol.hasPrefix("30") && date >= "2020-08-24") ? 100_000 : 1_000_000
        let stampRate = etf || !sell ? 0.0 : date >= "2023-08-28" ? 0.0005 : 0.001
        let transferRate = etf ? 0.0 : date >= "2022-04-29" ? 0.00001 : 0.00002
        var feesPaid = OrderCosts(), remaining = q
        while remaining > 0 {
            let part = min(remaining, cap), value = money(Double(part) * px)
            let commission = money(max(fees.minimum_commission, value * fees.commission_rate))
            let stamp = money(value * stampRate), transfer = money(value * transferRate), slip = money(value * fees.slippage_rate)
            feesPaid.commission = money(feesPaid.commission + commission)
            feesPaid.stamp_tax = money(feesPaid.stamp_tax + stamp)
            feesPaid.transfer_fee = money(feesPaid.transfer_fee + transfer)
            feesPaid.slippage = money(feesPaid.slippage + slip)
            feesPaid.total = money(feesPaid.total + money(commission + stamp + transfer + slip))
            feesPaid.order_quantities.append(part)
            remaining -= part
        }
        return feesPaid
    }

    public static func make(market: MarketSnapshot, date: String, next: String, account: Account,
                            weights: [String: Double], fixed: [String: Int]? = nil, forced: Set<String> = []) throws -> Plan {
        try account.validate()
        guard date == account.as_of else { throw ResearchError("请确认同一收盘日的账户与可卖份额") }
        guard date <= market.as_of, weights.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              weights.values.reduce(0, +) <= 1 + 1e-9 else { throw ResearchError("行情日期或目标权重无效") }
        let positions = account.positions.filter { $0.quantity > 0 }
        let held = Dictionary(uniqueKeysWithValues: positions.map { ($0.symbol, $0) })
        func price(_ symbol: String) throws -> Double {
            let extra = market.extras[symbol]
            let px = market.securities[symbol]?.bars[date]?.close ?? (extra?.date == date ? extra?.close : nil) ?? held[symbol]?.close
            guard let px, px.isFinite, px > 0 else { throw ResearchError("\(symbol) 缺少本次收盘价；请刷新或按账户日期补录") }
            return px
        }
        let positionValue = try positions.reduce(0.0) { try $0 + Double($1.quantity) * price($1.symbol) }
        let equity = money(account.cash + positionValue)
        var targets = fixed ?? [:]
        if fixed == nil {
            for s in Set(held.keys).union(weights.keys) {
                let w = weights[s] ?? 0, qty = held[s]?.quantity ?? 0
                var q = 0
                if w > 0 {
                    let px = try price(s), desired = equity * w / px
                    guard desired.isFinite && desired < Double(Int.max) else { throw ResearchError("目标份额超出范围") }
                    q = Int(desired) / 100 * 100
                    if !forced.contains(s) && qty > 0 && Double(abs(q - qty)) * px < 0.03 * equity { q = qty }
                }
                targets[s] = q
            }
        }
        for s in forced { targets[s] = 0 }
        var rows = [Intention](), cash = account.cash, available = account.cash, total = 0.0
        for s in Set(held.keys).union(targets.keys).sorted() {
            let delta = (held[s]?.quantity ?? 0) - (targets[s] ?? 0)
            guard delta > 0 else { continue }
            let px = try price(s), q = min(delta, held[s]?.available ?? 0)
            let fee = try costs(q, px, sell: true, symbol: s, date: next, fees: account.fees)
            cash = money(cash + Double(q) * px - fee.total)
            total += fee.total
            rows.append(.init(symbol: s, side: "SELL", quantity: q, requested_quantity: delta, deferred_quantity: delta - q,
                              funded_quantity: nil, conditional_quantity: nil, reference_price: px,
                              reference_value: money(Double(q) * px), costs: fee))
        }
        let buys = targets.keys.sorted {
            let a = weights[$0] ?? 0, b = weights[$1] ?? 0
            return a == b ? $0 < $1 : a > b
        }
        for s in buys {
            let delta = targets[s]! - (held[s]?.quantity ?? 0)
            guard delta > 0 else { continue }
            let px = try price(s)
            func buyCost(_ n: Int) throws -> OrderCosts {
                try costs(n, px, sell: false, symbol: s, date: next, fees: account.fees)
            }
            func affordable(_ quantity: Int, _ budget: Double) throws -> Int {
                var lo = 0, hi = quantity / 100
                while lo < hi {
                    let mid = (lo + hi + 1) / 2
                    if try money(Double(mid * 100) * px) + buyCost(mid * 100).total <= budget + 1e-8 { lo = mid }
                    else { hi = mid - 1 }
                }
                return lo * 100
            }
            let q = try affordable(delta, cash), funded = try affordable(q, available), fee = try buyCost(q)
            cash = money(cash - Double(q) * px - fee.total)
            if funded > 0 { available = try money(available - Double(funded) * px - buyCost(funded).total) }
            total += fee.total
            rows.append(.init(symbol: s, side: "BUY", quantity: q, requested_quantity: delta, deferred_quantity: delta - q,
                              funded_quantity: funded, conditional_quantity: q - funded, reference_price: px,
                              reference_value: money(Double(q) * px), costs: fee))
        }
        guard cash >= -0.001, available >= -0.001 else { throw ResearchError("资金预算出现负数") }
        return .init(equity: equity, initial_cash: account.cash, estimated_costs: money(total), projected_cash: cash,
                     requested_quantities: targets, orders: rows, actual_trades_recorded: false, projected_cash_conditional_on_sales: true)
    }
}
