import Foundation

public enum HistoryDayState: String, Codable {
    case beforeListing = "BEFORE_LISTING", halted = "HALTED", noTrades = "NO_TRADES_CONFIRMED"
    case missing = "SOURCE_MISSING", unknown = "UNKNOWN"
}
public struct EvidenceDay: Codable { public let date, evidence: String }
public struct ReviewedSpan: Codable { public let from, through, evidence: String }
public struct ReviewedGap: Codable { public let state: HistoryDayState; public let evidence: String? }
public struct HistoryIssue: Codable, Equatable {
    public let symbol, date, field, reason: String
    public var message: String { "\(symbol) \(date) · \(field) · \(reason)" }
}
public struct SecurityReview: Codable {
    public var listing: EvidenceDay?
    public var spans: [ReviewedSpan]
    public var gaps: [String:ReviewedGap]
    public var events: [MarketEvent]
    public var issues: [HistoryIssue]
    public var earliestObserved: String?
    public var priceResolutions:[String:String]?
}
public struct HistoryReplayTarget: Codable {
    public let start,end:String
    public var strategies:[String]?
}
public struct HistoryReview: Codable {
    public let schema, from, through: String
    public var symbols: [String:SecurityReview]
    public var replayTarget:HistoryReplayTarget?
    public static let version = "etf-history-review-1"
    func validate(sources:[String:String], calendar:Sessions) throws {
        guard schema == Self.version, try calendar.index(from) <= calendar.index(through),
              Set(symbols.keys).isSubset(of:MarketSnapshot.pool) else { throw ResearchError("历史核验清单的版本、证券或请求区间无效") }
        func evidence(_ key:String?) -> Bool { key.flatMap { sources[$0] }.map(Integrity.digestID) ?? false }
        if let t=replayTarget {
            guard try calendar.index(t.start)<=calendar.index(t.end),t.start>=from,t.end<=through,
                  t.strategies.map({ !$0.isEmpty && Set($0).count==$0.count }) ?? true
            else { throw ResearchError("请求的回测目标超出审核清单或策略重复") }
        }
        for (s,r) in symbols {
            if let l=r.listing { guard evidence(l.evidence), (try? calendar.index(l.date)) != nil else { throw ResearchError("\(s) 上市日期缺少可追溯公告") } }
            if let observed=r.earliestObserved { _ = try calendar.index(observed) }
            for span in r.spans {
                guard try calendar.index(span.from) <= calendar.index(span.through), evidence(span.evidence)
                else { throw ResearchError("\(s) \(span.from) 公司行动核验区间缺来源") }
            }
            for (d,g) in r.gaps {
                _ = try calendar.index(d)
                switch g.state {
                case .beforeListing: guard let l=r.listing, d < l.date else { throw ResearchError("\(s) \(d) 上市前状态缺上市证明") }
                case .halted,.noTrades: guard evidence(g.evidence) else { throw ResearchError("\(s) \(d) 停牌或确证无成交缺来源") }
                case .missing,.unknown: break
                }
            }
            for e in r.events where !evidence(e.source) { throw ResearchError("\(s) \(e.date) 公司行动缺可定位的来源原件") }
            for (day,key) in r.priceResolutions ?? [:] { guard AccountInput.validDate(day),evidence(key) else { throw ResearchError("\(s) \(day) 价格分歧缺复核原件") } }
            for i in r.issues { guard i.symbol == s, AccountInput.validDate(i.date), !i.reason.isEmpty else { throw ResearchError("\(s) 待核项目缺日期或原因") } }
        }
    }
    func verifyEvidence(sources:[String:String], read:(String)throws->Data) throws {
        struct Audit:Decodable { let schema,symbol,from,through:String; let events:[MarketEvent]; let sources:[String] }
        for (s,r) in symbols {
            for span in r.spans {
                let bytes=try read(span.evidence)
                let a=try JSONDecoder().decode(Audit.self,from:bytes)
                let expected=r.events.filter { span.from<=$0.date && $0.date<=span.through }
                guard a.schema=="etf-action-audit-1", a.symbol==s, a.from==span.from, a.through==span.through,
                      !a.sources.isEmpty, a.sources.allSatisfy({ $0 != span.evidence && sources[$0] != nil }),
                      Set(a.sources).count==a.sources.count,
                      a.events.count==expected.count, expected.allSatisfy({ e in e.source.map(a.sources.contains)==true && a.events.contains { HistoryCoverage.sameTerms(e,$0) && e.source==$0.source } })
                else { throw ResearchError("\(s) \(span.from) 审核文件的区间、原件或事件明细不符") }
            }
        }
    }
}

/// One Gregorian Shanghai exchange day, including the same conversion used by both iOS wheels.
public enum ExchangeDay {
    public static let zone = TimeZone(identifier:"Asia/Shanghai")!
    public static var calendar: Calendar { var c=Calendar(identifier:.gregorian); c.timeZone=zone; return c }
    public static func string(_ date:Date) -> String {
        let c=calendar.dateComponents([.year,.month,.day],from:date)
        return String(format:"%04d-%02d-%02d",c.year!,c.month!,c.day!)
    }
    public static func date(_ text:String) -> Date? {
        let parts=text.split(separator:"-").compactMap { Int($0) }
        guard parts.count==3, let d=calendar.date(from:DateComponents(year:parts[0],month:parts[1],day:parts[2],hour:12)),
              string(d)==text else { return nil }
        return d
    }
}
