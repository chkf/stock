import Foundation

enum ReplayFunding {
    static let maximumFill = 1_000_000
    static func fee(_ quantity:Int, price:Double, settings:StudySettings) -> Double {
        let gross=Double(quantity)*price
        return Planning.money(Planning.money(max(settings.minimumCommission,gross*settings.commissionRate))+Planning.money(gross*settings.slippageRate))
    }
    static func required(_ quantity:Int, price:Double, settings:StudySettings) -> Double {
        var remaining=quantity/100*100, cash=0.0
        while remaining>=100 {
            let q=min(remaining,maximumFill)
            cash=Planning.money(cash+Planning.money(Double(q)*price+fee(q,price:price,settings:settings)))
            remaining-=q
        }
        return cash
    }
    static func budgets(_ required:[String:Double], cash:Double) -> [String:Double] {
        let symbols=required.keys.sorted()
        if symbols.count==1 { return [symbols[0]:cash] }
        let total=symbols.reduce(0) { $0+required[$1]! }
        if total<=cash { return required }
        return Dictionary(uniqueKeysWithValues:symbols.map { ($0,cash*required[$0]!/total) })
    }
}

public struct StudyPoint: Codable { public let date: String; public let equity, drawdown: Double }
public struct StudyFill: Codable {
    public let date, symbol, side: String
    public let quantity: Int
    public let price, fees: Double
}
public struct ClosedCycle: Codable {
    public let symbol, entry, exit, route: String
    public let net: Double
}
private struct CycleBook: Codable {
    let entry, route: String
    var balance = 0.0
}
struct Lot: Codable {
    var shares: Int; var available: String; var basis:Double
    init(shares:Int,available:String,basis:Double=0) { self.shares=shares; self.available=available; self.basis=basis }
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        shares=try c.decode(Int.self,forKey:.shares); available=try c.decode(String.self,forKey:.available)
        basis=try c.decodeIfPresent(Double.self,forKey:.basis) ?? 0
    }
}
private struct Claim: Codable { let ex, pay: String; var amount: Double }
private struct SimBook: Codable {
    var price = 0.0, high: Double?, lots = [Lot](), claims = [Claim]()
    var firstFill: CycleBook?
    var quantity: Int { lots.reduce(0) { $0+$1.shares } }
    mutating func convert(_ terms:SplitTerms, pending:inout Int?) throws {
        let quantities = try terms.allocation(lots.map(\.shares))
        if terms.factor >= 1 {
            let old=lots
            for (j,lot) in old.enumerated() where quantities[j]>lot.shares {
                let original=Planning.money(lot.basis*Double(lot.shares)/Double(quantities[j]))
                lots[j].basis=original
                lots.append(.init(shares:quantities[j]-lot.shares,available:max(lot.available,terms.available),basis:Planning.money(lot.basis-original)))
            }
        } else {
            for j in lots.indices { lots[j].shares=quantities[j]; lots[j].available=max(lots[j].available,terms.available) }
            let remainder=lots.filter { $0.shares==0 }.reduce(0) { $0+$1.basis }
            lots.removeAll { $0.shares==0 }
            if remainder>0 {
                guard !lots.isEmpty else { throw ResearchError("全部零碎权益的现金处置尚无可执行依据") }
                lots[0].basis=Planning.money(lots[0].basis+remainder)
            }
        }
        if let q=pending { pending = (q<0 ? -1 : 1) * (try terms.converted(abs(q))) }
    }
}
public struct StudyLedgerDay {
    public struct Holding {
        public let shares,available,pending:Int
        public let mark,basis,receivable:Double
        public let lots:[Int]
    }
    public let date:String
    public let cash,equity:Double
    public let holdings:[String:Holding]
}
public struct ReplayReport: Codable {
    public let snapshot, strategy, start, end: String
    public let capital: Double
    public fileprivate(set) var curve = [StudyPoint](), trades = [StudyFill](), cycles = [ClosedCycle]()
    fileprivate var cash, peak: Double
    fileprivate var books = [String: SimBook](), pending = [String: Int](), locks = [String: String]()
    fileprivate var active: Decision?
    public private(set) var ledgerVersion:Int?
    public fileprivate(set) var warmupFrom:String?, firstSignal:String?, waiting:[String:Int]?
    fileprivate var contentDigest:String?
    public fileprivate(set) var inputs:[String:String]?
    public fileprivate(set) var firstTrade:String?
    public static func fingerprint(market:String,workspace:String,dynamic:Bool) throws -> String {
        guard dynamic else { return fingerprint(market:market,workspace:workspace) }
        let calendar=Integrity.sha(try FrozenInputs.data("XSHG.txt"))
        return Integrity.sha(Data("etf-ledger-4|contract-2|session-feed-1|\(calendar)|\(market)|\(workspace)".utf8))
    }
    public static let currentLedgerVersion=3
    public static func fingerprint(market:String,workspace:String) -> String {
        Integrity.sha(Data(("etf-ledger-\(currentLedgerVersion)|"+market+"|"+workspace).utf8))
    }
    public var finished: Bool { curve.last?.date == end }
    public var outcomeDate: String { curve.last?.date ?? start }
}

public struct CycleEvidence {
    public let count, wins, comparable, tests: Int
    public let forecast: Double?
    public let reason: String
}
extension ReplayReport {
    public func evidence(symbol: String, route: String, asOf: String) -> CycleEvidence {
        let rows = cycles.filter { $0.symbol == symbol && $0.exit < asOf }
        var hits = 0, same = 0, sameWins = 0, tests = 0, loss = 0.0, baselineLoss = 0.0
        for row in rows {
            let win = row.net > 0 ? 1 : 0
            if row.route == route {
                if same >= 20 {
                    let estimate = Double(sameWins+1)/Double(same+2)
                    let base = Double(hits+1)/Double((rows.prefix { $0.exit < row.exit }).count+2)
                    loss += pow(estimate-Double(win),2)
                    baselineLoss += pow(base-Double(win),2)
                    tests += 1
                }
                same += 1; sameWins += win
            }
            hits += win
        }
        let allowed = tests >= 12 && sameWins > 0 && sameWins < same && loss <= baselineLoss
        let why = tests < 12 ? "同一标的与分支需先有 20 个完整周期，再逐笔验证 12 次，目前验证 \(tests) 次。" :
            allowed ? "按同一标的和分支的历史周期估计，使用逐笔时间外检验和加一平滑。" : "时间外检验或盈亏样本未满足显示条件。"
        return CycleEvidence(count: rows.count, wins: hits, comparable: same, tests: tests,
                             forecast: allowed ? Double(sameWins+1)/Double(same+2) : nil, reason: why)
    }
}

extension StrategyEngine {
    public func replay(_ strategy: String, snapshot: String, start: String, end: String,
                       resume: ReplayReport? = nil, observe:((StudyLedgerDay)->Void)?=nil,
                       checkpoint: (ReplayReport, Double) throws -> Void = { _,_ in }) throws -> ReplayReport {
        let first = try sessions.index(start), last = try sessions.index(end)
        guard first > 0, first <= last, end <= market.as_of, start >= "2006-07-01" else { throw ResearchError("回测区间超出已验证行情或交易规则") }
        let before = sessions.days[first-1], symbols = market.securities.keys.sorted(), rules = market.isUniverse ? nil : try PublicRules.load()
        let version=try workspace ?? Self.seed.get()
        guard let definition=version.design.strategies.first(where:{ $0.id==strategy }) else { throw ResearchError("工作区缺少策略 "+strategy) }
        let coverage=try HistoryCoverage(market:market,sessions:sessions,strategies:[definition])
        if let reason=coverage.problem(start:start,end:end) { throw ResearchError(reason) }
        let settings=version.design.study ?? StudySettings.original
        let ledger=market.isUniverse ? 4 : ReplayReport.currentLedgerVersion
        if let data=market.universe {
            guard snapshot == (try ReplayReport.fingerprint(market:data.id,workspace:version.hash,dynamic:true)) else { throw ResearchError("目录回测指纹不符") }
        }
        let ex = market.securities.mapValues { Dictionary(grouping: $0.events, by: \.date) }
        let reg = market.isUniverse ? [:] : market.securities.mapValues { Dictionary(grouping: $0.events.filter { ($0.cash_per_share ?? 0) > 0 }, by: { $0.record_date ?? "" }) }
        var st = resume ?? ReplayReport(snapshot: snapshot, strategy: strategy, start: start, end: end, capital: settings.capital, cash: settings.capital, peak: settings.capital, ledgerVersion:ledger)
        guard st.ledgerVersion==ledger, st.snapshot == snapshot, st.strategy == strategy, st.start == start, st.end == end, st.capital == settings.capital else {
            throw ResearchError("回测检查点的账簿版本、输入或区间不同；请以当前版本重新回测，保留旧记录")
        }
        if let data=market.universe {
            let pins=["market":data.id,"workspace":version.hash,"catalog":data.catalog,"scopeEvidence":data.scopeEvidence,"contract":"2","execution":"4","calendar":Integrity.sha(try FrozenInputs.data("XSHG.txt"))]
            if resume != nil {
                guard st.inputs==pins,Set(st.books.keys)==Set(symbols),Set(st.pending.keys).isSubset(of:Set(symbols)),st.active != nil,
                      st.curve.count<=last-first+1,st.curve.enumerated().allSatisfy({ $0.element.date==sessions.days[first+$0.offset] }),st.cash>=0 else { throw ResearchError("目录检查点损坏") }
            } else { st.inputs=pins; st.warmupFrom=max(data.from,sessions.days[first-definition.history]); st.waiting=[:] }
        }
        if st.finished { return st }
        func equity(_ date: String) -> Double {
            var value = st.cash
            for s in symbols {
                let b = st.books[s]!
                value += Double(b.quantity)*b.price + b.claims.filter { $0.ex <= date }.reduce(0) { $0+$1.amount }
            }
            return value
        }
        func select(_ date: String) throws {
            let old = st.active
            let d = try decision(strategy, on: date, previousState: old?.marketState ?? "UNKNOWN", previousSectors: old?.sectorStates ?? [:])
            let value = equity(date)
            if market.isUniverse,d.waitReason==nil,st.firstSignal==nil { st.firstSignal=date }
            for s in symbols {
                var b = st.books[s]!
                if let day = st.locks[s], b.quantity == 0, day < date { st.locks.removeValue(forKey: s) }
                if old?.route != d.route && (d.resetHighOnEntry ?? (!market.isUniverse && ["MOM","BANK"].contains(d.route))) { b.high = b.quantity > 0 ? b.price : nil; st.books[s] = b }
                guard st.locks[s] == nil else { continue }
                let w = d.weights[s] ?? 0
                guard w == 0 || b.price > 0 else { throw ResearchError("\(s) 缺少建仓参考价") }
                let shares=w>0 ? value*w/b.price : 0
                guard shares.isFinite, shares<Double(Int.max) else { throw ResearchError("\(s) 目标份额超出可表示范围") }
                let target = Int(shares)/100*100
                var diff = target-b.quantity
                if b.quantity > 0, w > 0, Double(abs(diff))*b.price < settings.rebalanceBand*value { diff = 0 }
                st.pending[s] = diff == 0 ? nil : diff
            }
            st.active = d
        }
        if st.active == nil {
            for s in symbols {
                var b = SimBook()
                let sec = market.securities[s]!
                if let day = sec.bars.keys.filter({ $0 <= before && !HistoryCoverage.noTrade(s,$0,market,rules) }).max() {
                    b.price=sec.bars[day]!.close
                    for e in sec.events.filter({ day<$0.date && $0.date<=before }).sorted(by:{ $0.date<$1.date }) {
                        b.price=(b.price-(e.cash_per_share ?? 0))/(e.share_factor ?? 1)
                    }
                }
                st.books[s] = b
            }
            try select(before)
        }
        let position = try st.curve.last.map { try sessions.index($0.date)+1 } ?? first
        let marketHalts = market.securities.mapValues { $0.statuses ?? [:] }
        for index in position...last {
            try Task.checkCancellation()
            let date = sessions.days[index]
            if let why=st.active?.waitReason,market.isUniverse { st.waiting?[why,default:0]+=1 }
            var executable = [String: Double]()
            var closingSplits = [String:SplitTerms]()
            for s in symbols {
                var b = st.books[s]!
                if let entry=market.universe?.listings[s],!entry.active(date) {
                    guard b.quantity==0,st.pending[s]==nil else { throw ResearchError("\(s) \(date) 退市/转换存在持仓或挂单，缺结算依据") }
                }
                for e in ex[s]?[date] ?? [] {
                    let factor = e.share_factor ?? 1, cash = e.cash_per_share ?? 0
                    if market.isUniverse,cash>0,b.quantity>0 {
                        guard let pay=e.payment_date else { throw ResearchError("\(s) \(date) 缺分红到账日") }
                        for lot in b.lots {
                            let amount=Double(lot.shares)*cash; b.claims.append(.init(ex:date,pay:pay,amount:amount));b.firstFill?.balance+=Planning.money(amount)
                        }
                    }
                    if b.price > 0 { b.price = (b.price-cash)/factor }
                    if let high = b.high { b.high = (high-cash)/factor }
                    if factor != 1 && (b.quantity > 0 || st.pending[s] != nil) {
                        let proof = e.available_date == nil ? rules?.members[s]?.events.first(where: { $0.date == e.date && $0.share_factor == e.share_factor }) : nil
                        let terms=try SplitTerms(e,symbol:s,calendar:sessions,halted:HistoryCoverage.noTrade(s,date,market,rules),fallback:proof,legacy:!market.isUniverse)
                        if terms.atClose { closingSplits[s]=terms }
                        else { try b.convert(terms,pending:&st.pending[s]) }
                    }
                }
                for claim in b.claims where claim.pay <= date { st.cash = Planning.money(st.cash + claim.amount) }
                b.claims.removeAll { $0.pay <= date }
                st.books[s] = b
                if let entry=market.universe?.listings[s],!entry.active(date) { continue }
                let status = marketHalts[s]?[date]
                let halted = HistoryCoverage.noTrade(s,date,market,rules)
                guard let bar = market.securities[s]?.bars[date] else {
                    guard market.history?.symbols[s]?.listing.map({ date<$0.date }) == true || halted else { throw ResearchError("\(s) \(date) 缺行情或停牌证据") }
                    continue
                }
                if halted, bar.volume > 0 { throw ResearchError("\(s) \(date) 停牌记录与成交量冲突") }
                guard let q = st.pending[s], q != 0, !halted, bar.volume > 0, b.price > 0 else { continue }
                if market.isUniverse {
                    guard let up=status?.upper_limit,let down=status?.lower_limit else { throw ResearchError("\(s) \(date) 缺执行日价格限制") }
                    if q>0 && bar.open>=up-1e-8 || q<0 && bar.open<=down+1e-8 { continue }
                    executable[s]=bar.open; continue
                }
                guard let member=rules?.members[s] else { throw ResearchError("\(s) 缺旧版执行规则") }
                let band = date < (member.bandFrom ?? "2016-01-01") ? 0.1 : member.band
                let up = status?.upper_limit ?? Self.priceTick(b.price*(1+band)), down = status?.lower_limit ?? Self.priceTick(b.price*(1-band))
                guard bar.high <= up+0.001, bar.low >= down-0.001 else { throw ResearchError("\(s) \(date) 行情越界") }
                if q > 0 && (bar.open >= up-1e-8 || bar.open > b.price*(1+band)+1e-8) { continue }
                if q < 0 && (bar.open <= down+1e-8 || bar.open < b.price*(1-band)-1e-8) { continue }
                executable[s] = bar.open
            }
            func fill(_ s: String, budget: Double) {
                var b = st.books[s]!, remaining = st.pending[s]!, budget = budget
                let p = executable[s]!, sell = remaining < 0
                func fee(_ q: Int) -> Double {
                    ReplayFunding.fee(q,price:p,settings:settings)
                }
                while remaining != 0 {
                    var qty = min(abs(remaining),ReplayFunding.maximumFill)
                    if sell {
                        let available = b.lots.filter { $0.available <= date }.reduce(0) { $0+$1.shares }
                        qty = min(qty,available)
                        if qty < available { qty = qty/100*100 }
                    } else {
                        qty = qty/100*100
                        let available = min(budget,st.cash)
                        while qty >= 100 {
                            let excess = Planning.money(Double(qty)*p+fee(qty))-available
                            if excess <= 0.001 { break }
                            qty -= max(1,Int(ceil(excess/p/100)))*100
                        }
                    }
                    guard qty > 0 else { break }
                    let cost = fee(qty), flow = Planning.money((sell ? 1 : -1)*Double(qty)*p-cost)
                    if sell && st.cash+flow < 0 { break }
                    if !sell {
                        if b.quantity == 0 { b.firstFill = CycleBook(entry: date, route: st.active!.route); b.high = nil }
                        b.lots.append(.init(shares:qty,available:index < last ? sessions.days[index+1] : (try? sessions.next(date)) ?? "9999",basis:-flow))
                        budget += flow
                    } else {
                        var remove = qty
                        for j in b.lots.indices where b.lots[j].available <= date && remove > 0 {
                            let part = min(remove,b.lots[j].shares)
                            b.lots[j].basis=Planning.money(b.lots[j].basis*Double(b.lots[j].shares-part)/Double(b.lots[j].shares))
                            b.lots[j].shares -= part; remove -= part
                        }
                        b.lots.removeAll { $0.shares == 0 }
                    }
                    b.firstFill?.balance += flow
                    if b.quantity == 0, let entry = b.firstFill {
                        st.cycles.append(.init(symbol: s, entry: entry.entry, exit: date, route: entry.route, net: Planning.money(entry.balance)))
                        b.firstFill = nil; b.high = nil
                    }
                    st.cash = Planning.money(st.cash+flow)
                    st.trades.append(.init(date: date, symbol: s, side: sell ? "SELL" : "BUY", quantity: qty, price: p, fees: cost))
                    if market.isUniverse,st.firstTrade==nil { st.firstTrade=date }
                    remaining += sell ? qty : -qty
                }
                st.pending[s] = remaining == 0 ? nil : remaining
                st.books[s] = b
            }
            for s in executable.keys.sorted() where (st.pending[s] ?? 0) < 0 { fill(s,budget: 0) }
            let buyers = executable.keys.filter { (st.pending[$0] ?? 0) > 0 }.sorted()
            let required=Dictionary(uniqueKeysWithValues:buyers.map {
                ($0,ReplayFunding.required(st.pending[$0]!,price:executable[$0]!,settings:settings))
            })
            let budgets=ReplayFunding.budgets(required,cash:st.cash)
            for s in buyers { fill(s,budget:budgets[s]!) }
            for s in symbols {
                var b = st.books[s]!
                if let terms=closingSplits[s] { try b.convert(terms,pending:&st.pending[s]) }
                if let close = market.securities[s]?.bars[date]?.close, !HistoryCoverage.noTrade(s,date,market,rules) { b.price = close }
                for e in reg[s]?[date] ?? [] where b.quantity > 0 {
                    guard let pay = e.payment_date, pay >= e.date else { throw ResearchError("\(s) \(date) 缺少分红到账日，回测停在最后的有效检查点") }
                    for lot in b.lots {
                        let amount = Double(lot.shares)*(e.cash_per_share ?? 0)
                        b.claims.append(.init(ex: e.date,pay: pay,amount: amount))
                        b.firstFill?.balance += Planning.money(amount)
                    }
                }
                if let d = st.active, protected(d,s), b.quantity > 0 {
                    b.high = max(b.high ?? b.price,b.price)
                    if b.price <= (1-(d.exitDrawdown ?? 0.2))*b.high!+1e-10 && st.locks[s] == nil { st.locks[s] = date; st.pending[s] = -b.quantity }
                }
                st.books[s] = b
            }
            let value = equity(date)
            guard value.isFinite, value > 0, st.cash >= -0.001 else { throw ResearchError("回测资金校验失败") }
            st.peak = max(st.peak,value)
            st.curve.append(.init(date: date, equity: value, drawdown: value/st.peak-1))
            if index < last, try (market.isUniverse && st.active?.waitReason != nil) || review(strategy,on:date) { try select(date) }
            if let observe {
                var holdings=[String:StudyLedgerDay.Holding]()
                for (s,b) in st.books {
                    holdings[s] = .init(shares:b.quantity,available:b.lots.filter { $0.available<=date }.reduce(0){$0+$1.shares},
                        pending:st.pending[s] ?? 0,mark:b.price,basis:Planning.money(b.lots.reduce(0){$0+$1.basis}),
                        receivable:b.claims.filter { $0.ex<=date }.reduce(0){$0+$1.amount},lots:b.lots.map(\.shares))
                }
                observe(.init(date:date,cash:st.cash,equity:value,holdings:holdings))
            }
            if (index-first+1).isMultiple(of: 21) || index == last { try checkpoint(st,Double(index-first+1)/Double(last-first+1)) }
        }
        return st
    }
    private static func priceTick(_ x: Double) -> Double {
        var a = Decimal(string: String(x), locale: Locale(identifier: "en_US_POSIX"))!, b = Decimal()
        NSDecimalRound(&b,&a,3,.plain)
        return NSDecimalNumber(decimal: b).doubleValue
    }
}

extension PrivateLibrary {
    public nonisolated func formalReplay(market:MarketSnapshot,id:String,workspace:WorkspaceVersion,strategy:String,start:String,end:String,
                                         progress:(ReplayReport,Double)throws->Void = { _,_ in }) throws -> ReplayReport {
        let calendar=try Sessions()
        guard end <= (try calendar.completed()) else { throw ResearchError("结束日期未收盘") }
        let stamp=try ReplayReport.fingerprint(market:id,workspace:workspace.hash,dynamic:market.isUniverse)
        let path=try replayURL(snapshot:stamp,strategy:strategy,start:start,end:end)
        try HistoryWriters.shared.claim(path); defer { HistoryWriters.shared.release(path) }
        let old=try savedReplay(snapshot:stamp,strategy:strategy,start:start,end:end)
        return try StrategyEngine(market:market,sessions:calendar,workspace:workspace).replay(strategy,snapshot:stamp,start:start,end:end,resume:old) { report,value in
            try Task.checkCancellation(); try storeReplay(report); try progress(report,value)
        }
    }
    public nonisolated func studyRange(market:String, workspace:String) throws -> [String]? {
        let p=try rangeURL(market:market,workspace:workspace)
        guard FileManager.default.fileExists(atPath:p.path) else { return nil }
        let a=try JSONDecoder().decode([String].self,from:Data(contentsOf:p))
        guard a.count==2, a.allSatisfy(AccountInput.validDate) else { throw ResearchError("回测区间记录无效") }
        return a
    }
    private nonisolated func rangeURL(market:String,workspace:String) throws -> URL {
        guard Integrity.digestID(market), Integrity.digestID(workspace) else { throw ResearchError("回测输入标识无效") }
        return root.appendingPathComponent("studies/\(market)_\(workspace).json")
    }
    public nonisolated func setStudyRange(_ range:[String],market:String,workspace:String) throws {
        let p=try rangeURL(market:market,workspace:workspace)
        try FileManager.default.createDirectory(at:p.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(range).write(to:p,options:.atomic)
    }
    public nonisolated func replayURL(snapshot: String, strategy: String, start: String, end: String) throws -> URL {
        guard Integrity.digestID(snapshot), WorkspaceVersion.validID(strategy),
              AccountInput.validDate(start), AccountInput.validDate(end) else { throw ResearchError("回测索引无效") }
        return root.appendingPathComponent("studies/v1/\(snapshot)/\(start)_\(end)_\(strategy).json")
    }
    public nonisolated func savedReplay(snapshot: String, strategy: String, start: String, end: String) throws -> ReplayReport? {
        let url = try replayURL(snapshot: snapshot,strategy: strategy,start: start,end: end)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var report = try JSONDecoder().decode(ReplayReport.self, from: Data(contentsOf: url))
        if report.ledgerVersion==4 {
            let digest=report.contentDigest; report.contentDigest=nil
            guard digest == (try Integrity.sha(AccountEncoding.encodeReplay(report))) else { throw ResearchError("目录回测检查点内容摘要不符") }
        }
        guard report.snapshot == snapshot && report.strategy == strategy && report.start == start && report.end == end else { throw ResearchError("回测输入与记录不一致") }
        return report
    }
    public nonisolated func storeReplay(_ report: ReplayReport) throws {
        let url = try replayURL(snapshot: report.snapshot,strategy: report.strategy,start: report.start,end: report.end)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),withIntermediateDirectories: true)
        var copy=report
        if copy.ledgerVersion==4 { copy.contentDigest=nil; copy.contentDigest=Integrity.sha(try AccountEncoding.encodeReplay(copy)) }
        try JSONEncoder().encode(copy).write(to: url,options: .atomic)
    }
}

private enum AccountEncoding {
    static func encodeReplay(_ report:ReplayReport) throws -> Data { let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]; return try encoder.encode(report) }
}
