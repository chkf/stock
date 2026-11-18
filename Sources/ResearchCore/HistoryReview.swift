import Foundation

public enum HistoryDayState: String, Codable {
    case beforeListing = "BEFORE_LISTING", halted = "HALTED", noTrades = "NO_TRADES_CONFIRMED"
    case missing = "SOURCE_MISSING", unknown = "UNKNOWN"
    public var title:String {
        switch self {
        case .beforeListing: return "上市前"
        case .halted: return "已证停牌"
        case .noTrades: return "已证无成交"
        case .missing: return "行情来源缺记录"
        case .unknown: return "原因未知"
        }
    }
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
    public var quoteSources:[String]?
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
    /// Supplemental input can add earlier reviewed intervals without discarding previously adopted evidence.
    func extending(_ earlier:HistoryReview?) throws -> HistoryReview {
        guard let earlier else { return self }
        var merged=earlier.symbols
        for (symbol,new) in symbols {
            guard var old=merged[symbol] else { merged[symbol]=new; continue }
            if let before=old.listing,let after=new.listing,before.date != after.date { throw ResearchError("\(symbol) 上市依据与旧代冲突") }
            old.listing = old.listing ?? new.listing
            old.earliestObserved=[old.earliestObserved,new.earliestObserved].compactMap{$0}.min()
            if let additional=new.quoteSources { old.quoteSources=Array(Set((old.quoteSources ?? [])+additional)).sorted() }
            for span in new.spans where !old.spans.contains(where: { $0.from==span.from && $0.through==span.through && $0.evidence==span.evidence }) {
                old.spans.append(span)
            }
            for (d,g) in new.gaps {
                if let previous=old.gaps[d], [.halted,.noTrades,.beforeListing].contains(previous.state), previous.state != g.state {
                    throw ResearchError("\(symbol) \(d) 已确认交易状态与新证据冲突")
                }
                old.gaps[d]=g
            }
            for e in new.events {
                if let prior=old.events.first(where:{ $0.date==e.date }) {
                    guard HistoryCoverage.sameTerms(e,prior) else { throw ResearchError("\(symbol) \(e.date) 行动审核与旧代冲突") }
                } else { old.events.append(e) }
            }
            old.issues.append(contentsOf:new.issues.filter { !old.issues.contains($0) })
            if let resolutions=new.priceResolutions { old.priceResolutions=(old.priceResolutions ?? [:]).merging(resolutions) { original,_ in original } }
            merged[symbol]=old
        }
        return HistoryReview(schema:Self.version,from:min(from,earlier.from),through:max(through,earlier.through),symbols:merged,replayTarget:replayTarget ?? earlier.replayTarget)
    }
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
            if let quotes=r.quoteSources, !quotes.allSatisfy({ evidence($0) }) { throw ResearchError("\(s) 未找到声明的原价响应") }
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
    func verifyPrices(in market:MarketSnapshot,read:(String)throws->Data) throws {
        let anchor=try PublicRules.load().anchor
        for (symbol,review) in symbols where !review.spans.isEmpty && from<anchor {
            try Task.checkCancellation()
            guard let security=market.securities[symbol] else { throw ResearchError("审核证券不存在 "+symbol) }
            let required=Set(security.bars.keys.filter { day in day<anchor && review.spans.contains { $0.from<=day && day<=$0.through } })
            if required.isEmpty { continue }
            let captured=market.sources.keys.filter { path in
                let name=path.split(separator:"/").last.map(String.init) ?? ""
                return name.hasPrefix(symbol+".") && name.hasSuffix(".quotes.json")
            }
            var matched=Set<String>()
            for key in Set(captured+(review.quoteSources ?? [])) {
                guard market.sources[key] != nil else { throw ResearchError("\(symbol) 缺少原价原件 "+key) }
                let rows=try PublicFeed.quotes(read(key),symbol:symbol,from:from,through:market.as_of)
                for (d,bar) in rows where required.contains(d) {
                    guard bar==security.bars[d] || review.priceResolutions?[d] != nil else { throw ResearchError("\(symbol) \(d) 导入原价或成交量与来源原件不符") }
                    matched.insert(d)
                }
            }
            if let missing=required.subtracting(matched).min() { throw ResearchError("\(symbol) \(missing) 已核区间缺可逐行核对的未复权响应") }
            for (day,key) in review.priceResolutions ?? [:] {
                struct Resolution:Decodable { let schema,symbol,date,tencent,eastmoney,decision,reason:String; let chosen:Bar }
                let r=try JSONDecoder().decode(Resolution.self,from:read(key))
                guard r.schema=="etf-price-resolution-1",r.symbol==symbol,r.date==day,r.chosen==security.bars[day],
                      !r.reason.isEmpty,Set([key,r.tencent,r.eastmoney,r.decision]).count==4,
                      [r.tencent,r.eastmoney,r.decision].allSatisfy({market.sources[$0] != nil}),
                      let t=try PublicFeed.quotes(read(r.tencent),symbol:symbol,from:day,through:day)[day],
                      let content=try JSONSerialization.jsonObject(with:read(r.eastmoney)) as? [String:Any],
                      let data=content["data"] as? [String:Any], data["code"] as? String==String(symbol.prefix(6)),
                      let rows=data["klines"] as? [String],let line=rows.first(where:{$0.hasPrefix(day+",")}) else {
                    throw ResearchError("\(symbol) \(day) 两源价格裁定缺原始日线、正式依据或选用值")
                }
                let v=line.components(separatedBy:",").dropFirst().prefix(5).compactMap(Double.init)
                guard v.count==5 else { throw ResearchError("\(symbol) \(day) 交叉来源 OHLC 字段异常") }
                let other=Bar(open:v[0],close:v[1],high:v[2],low:v[3],volume:v[4])
                guard other.valid,(r.chosen==t || r.chosen==other),!(try read(r.decision)).isEmpty else { throw ResearchError("\(symbol) \(day) 价格裁定与原件不符") }
            }
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
