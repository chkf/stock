import Foundation

public struct SecurityCoverage {
    public let symbol:String
    public let firstBar,lastBar,firstSignal,lastSignal,listed:String?
    public let missingDays:Int
}
public struct StudyWindow: Equatable { public let start,end:String }

/// Scan once per data generation. Open/close evidence and signal eligibility are different tests.
public struct HistoryCoverage {
    public let from,through:String
    public let securities:[SecurityCoverage]
    public let issues:[HistoryIssue]
    public let windows:[StudyWindow]
    public let warmup:Int
    private let problems:[String:HistoryIssue], samples:[String:Int], calendar:Sessions
    public func sampleCount(on day:String) -> Int { samples[day] ?? 0 }
    public func problem(start:String,end:String,completed:String?=nil) -> String? {
        guard ExchangeDay.date(start) != nil, ExchangeDay.date(end) != nil else { return "请选择有效的上海公历日期" }
        guard let a=try? calendar.index(start) else { return "\(start) 不是交易日或不在已知交易日历内" }
        guard let b=try? calendar.index(end) else { return "\(end) 不是交易日或不在已知交易日历内" }
        guard a<=b else { return "起始日 \(start) 晚于结束日 \(end)" }
        if let completed, end>completed { return "\(end) 晚于最近已完成收盘 \(completed)" }
        guard start>=from, end<=through else { return "所选区间超出本快照的请求范围 \(from) 至 \(through)" }
        if windows.contains(where:{ $0.start<=start && $0.end>=end }) { return nil }
        for i in a...b { if let issue=problems[calendar.days[i]] { return issue.message } }
        return "\(start) 前一交易日缺少 \(warmup) 日连续已核信号"
    }
    static func noTrade(_ s:String,_ d:String,_ market:MarketSnapshot,_ rules:PublicRules) -> Bool {
        if let notice=SplitNotice.published.first(where:{ $0.symbol==s && $0.ex==d }) { return notice.halted }
        if let g=market.history?.symbols[s]?.gaps[d] { return [.halted,.noTrades].contains(g.state) }
        if let status=market.securities[s]?.statuses?[d], status.assumption != true, let source=status.source, market.sources[source] != nil,
           status.state=="halted" || status.state=="no_trades_confirmed" { return true }
        return rules.members[s]?.halts[d] != nil
    }
    public init(market:MarketSnapshot,sessions:Sessions,strategies:[StrategyFile]) throws {
        let rules=try PublicRules.load()
        guard !strategies.isEmpty, Set(market.securities.keys)==MarketSnapshot.pool else { throw ResearchError("回测缺少策略或原固定 28 只 ETF") }
        try market.history?.validate(sources:market.sources,calendar:sessions)
        let observed=market.securities.values.compactMap { $0.bars.keys.min() }.min()
        guard let first=market.history?.from ?? observed else { throw ResearchError("28 只证券均无真实原价") }
        let a=try sessions.index(first), b=try sessions.index(market.as_of)
        guard b>=a else { throw ResearchError("行情请求范围倒置") }
        self.from=first; through=market.as_of; calendar=sessions
        let days=Array(sessions.days[a...b]), n=days.count
        let lookback=strategies.map { s in ["GB","MV"].contains(s.id) && s.history==253 ? 252 : s.history }.max()!
        warmup=lookback
        var counts=Array(repeating:0,count:n), domestic=counts
        var dayProblem=[HistoryIssue?](repeating:nil,count:n), dirty=[HistoryIssue?](repeating:nil,count:n)
        var diagnostics=[HistoryIssue](), descriptions=[SecurityCoverage]()
        for s in market.securities.keys.sorted() {
            try Task.checkCancellation()
            let sec=market.securities[s]!, member=rules.members[s]!, review=market.history?.symbols[s]
            let firstBar=sec.bars.keys.min(), listing=review?.listing?.date
            let eventDays=Dictionary(grouping:sec.events,by:\.date)
            var eventIssues=[String:HistoryIssue]()
            func flag(_ date:String,_ field:String,_ reason:String) { eventIssues[date]=HistoryIssue(symbol:s,date:date,field:field,reason:reason) }
            for issue in review?.issues ?? [] { eventIssues[issue.date]=issue }
            if s=="512010.SH" {
                for d in ["2020-08-21","2020-08-24","2020-08-25","2020-08-26","2020-08-27"] where review?.priceResolutions?[d]==nil {
                    flag(d,"原价","两源 OHLC 相差 0.001 元，缺定价复核原件")
                }
            }
            for (d,events) in eventDays {
                if events.count>1 { flag(d,"公司行动","同日多项事件缺少已核执行次序"); continue }
                let e=events[0], cash=e.cash_per_share ?? 0, split=e.share_factor ?? 1
                if e.supported==false { flag(d,"公司行动","原事件标明不支持执行，缺独立复核后的可执行事件"); continue }
                if e.date_needs_reconciliation==true { flag(d,"事件日期","待核登记、除权或执行时点"); continue }
                if (try? sessions.index(d))==nil { throw ResearchError("\(s) \(d) 公司行动除权日期不在交易日历内") }
                if cash<0 || !cash.isFinite || !split.isFinite || split<=0 || (cash>0 && split != 1) { flag(d,"公司行动","金额、比例或组合执行次序无效"); continue }
                if cash>0, e.record_date.flatMap({ try? sessions.index($0) })==nil || (e.record_date ?? "")>=d || e.payment_date.flatMap(ExchangeDay.date)==nil || (e.payment_date ?? "")<d {
                    flag(d,"现金分红","缺独立登记日、除息日或到账日")
                }
                if split != 1 {
                    let fallback=member.events.first { $0.date==d && $0.share_factor==e.share_factor }
                    do { _=try SplitTerms(e,symbol:s,calendar:sessions,halted:Self.noTrade(s,d,market,rules),fallback:fallback) }
                    catch { flag(d,"份额变更",error.localizedDescription) }
                }
            }
            for e in member.events where first<=e.date && e.date<=market.as_of {
                if !(eventDays[e.date] ?? []).contains(where:{ Self.sameEvent($0,e) }) {
                    flag(e.date,"已核事件","与原版核定的登记、金额、因子或到账日不符")
                }
            }
            for notice in SplitNotice.published where notice.symbol==s && first<=notice.ex && notice.ex<=market.as_of {
                if !(eventDays[notice.ex] ?? []).contains(where:notice.matches) { flag(notice.ex,"除权日","缺与基金管理人公告相符的事件") }
            }
            for e in review?.events ?? [] where first<=e.date && e.date<=market.as_of {
                if !(eventDays[e.date] ?? []).contains(where:{ Self.sameTerms($0,e) }) {
                    flag(e.date,"事件清单","原始快照与审核事件不符")
                }
            }
            if let review, let known=review.earliestObserved, let firstBar, known<firstBar, known>=first {
                flag(known,"原价","已知更早原始记录，当前数据被截短")
            }
            var streak=0, missing=0, previousPrice:Double?, previousSignal:Double?, lastIssue:HistoryIssue?, lastIndex = -lookback-1
            for (i,d) in days.enumerated() {
                let bar=sec.bars[d], signal=sec.signal_close[d], g=review?.gaps[d], pre=listing.map { d<$0 } ?? false
                var issue=eventIssues[d]
                func problem(_ field:String,_ why:String) { if issue==nil { issue=HistoryIssue(symbol:s,date:d,field:field,reason:why) } }
                if let bar, !bar.valid { problem("原价","OHLC 或成交量无效") }
                if pre && (bar != nil || signal != nil) { problem("上市","上市公告前存在行情或信号") }
                if !pre {
                    let nonTrading=Self.noTrade(s,d,market,rules)
                    if let notice=SplitNotice.published.first(where:{ $0.symbol==s && $0.ex==d }),
                       let g, [.halted,.noTrades].contains(g.state) != notice.halted { problem("交易状态","与实施公告中的交易安排冲突") }
                    if g?.state == .missing || g?.state == .unknown { problem("原价",g!.state.rawValue+" 缺可核验的处理依据") }
                    if let bar, nonTrading && bar.volume>0 { problem("成交量","真实成交与已核停牌或无成交冲突") }
                    if bar==nil && !nonTrading {
                        missing+=1
                        problem("原价",firstBar.map { d<$0 } ?? true ? "UNKNOWN 缺上市依据或更早原价" : "SOURCE_MISSING 缺原价或正式停牌证据")
                    }
                    let covered=review?.spans.contains { $0.from<=d && d<=$0.through } ?? false
                    if d<rules.anchor && !covered { problem("公司行动","该日期缺历史行动完整性核验区间") }
                    if d>rules.reviewedThrough && !covered && sec.provider_events==nil { problem("公司行动","缺更新后的提供方原件或审核区间") }
                    let e=eventDays[d]?.first, cash=e?.cash_per_share ?? 0, split=e?.share_factor ?? 1
                    var mark=bar?.close
                    if let prev=previousPrice, prev>cash, split>0 {
                        let ref=(prev-cash)/split
                        if let bar, issue==nil {
                            if let up=sec.statuses?[d]?.upper_limit,let down=sec.statuses?[d]?.lower_limit {
                                if up<down || down<=0 || bar.high>up+0.001 || bar.low<down-0.001 { problem("价格区间","与历史涨跌停证据相冲突") }
                            } else {
                                do { try PublicFeed.validateBand(bar,reference:ref,band:d<(member.bandFrom ?? "2016-01-01") ? 0.1:member.band,symbol:s,date:d) }
                                catch { problem("价格区间",error.localizedDescription) }
                            }
                        }
                        if nonTrading && mark==nil { mark=ref }
                        if let sig=signal, let old=previousSignal, let price=mark, ref>0 {
                            let expected=old*price/ref
                            if abs(sig-expected)>max(1e-10,abs(expected)*1e-9) { problem("复权信号","与原价、分红拆合正推不一致") }
                        }
                    }
                    if let sig=signal, sig.isFinite, sig>0 {} else { problem("复权信号","缺少有效信号价") }
                    previousPrice=mark; previousSignal=signal
                } else { previousPrice=nil; previousSignal=nil }
                if let issue {
                    if dayProblem[i]==nil { dayProblem[i]=issue }
                    // Keep detailed event/gap evidence; consecutive unreviewed dates have one UI diagnostic.
                    if issue.field != lastIssue?.field || issue.reason != lastIssue?.reason || i != lastIndex+1 { diagnostics.append(issue) }
                    lastIssue=issue; lastIndex=i; streak=0
                } else { streak = pre ? 0 : streak+1 }
                if i-lastIndex<lookback, let lastIssue, dirty[i]==nil { dirty[i]=lastIssue }
                if streak>=lookback { counts[i]+=1; if sec.group.hasPrefix("domestic") { domestic[i]+=1 } }
            }
            descriptions.append(.init(symbol:s,firstBar:firstBar,lastBar:sec.bars.keys.max(),firstSignal:sec.signal_close.keys.min(),lastSignal:sec.signal_close.keys.max(),listed:listing,missingDays:missing))
        }
        var result=[StudyWindow](), sample=[String:Int](), failed=[String:HistoryIssue](), open:String?
        let needMV=strategies.contains { $0.id=="MV" }, needDomestic=strategies.contains { $0.id=="BANK_ELSE_GB" }
        for (i,d) in days.enumerated() {
            let eligible=i==0 ? 0 : counts[i-1]
            sample[d]=eligible
            var issue=dayProblem[i] ?? (i>0 ? dirty[i-1] : nil)
            if issue==nil && (eligible<(needMV ? 3 : 1) || (needDomestic && (i==0 || domestic[i-1]==0))) {
                issue = .init(symbol:"样本池",date:d,field:"预热",reason:"前一交易日仅 \(eligible) 只满足连续 \(lookback) 日，尚无足够合格样本")
            }
            if let issue {
                failed[d]=issue
                if let start=open { result.append(.init(start:start,end:days[i-1])); open=nil }
            } else if open==nil { open=d }
        }
        if let start=open { result.append(.init(start:start,end:days.last!)) }
        issues=diagnostics; securities=descriptions; windows=result; problems=failed; samples=sample
    }
    static func sameEvent(_ a:MarketEvent,_ b:MarketEvent) -> Bool {
        a.date==b.date && a.record_date==b.record_date && a.payment_date==b.payment_date &&
        abs((a.cash_per_share ?? 0)-(b.cash_per_share ?? 0))<1e-12 && (a.share_factor ?? 1)==(b.share_factor ?? 1)
    }
    static func sameTerms(_ a:MarketEvent,_ b:MarketEvent) -> Bool {
        sameEvent(a,b) && a.available_date==b.available_date && a.rounding==b.rounding && a.exact_factor==b.exact_factor &&
        a.share_timing==b.share_timing && a.settlement==b.settlement &&
        a.supported==b.supported && a.date_needs_reconciliation==b.date_needs_reconciliation
    }
    static func forActivation(_ market:MarketSnapshot,calendar:Sessions) throws -> HistoryCoverage {
        guard !market.sources.isEmpty,market.as_of <= (try calendar.completed()) else { throw ResearchError("待启用行情缺来源或截止日尚未收盘") }
        let target=market.history?.replayTarget
        let all=try WorkspaceVersion.bundled().design.strategies
        let chosen=all.filter { target?.strategies?.contains($0.id) ?? true }
        if let ids=target?.strategies,Set(chosen.map(\.id)) != Set(ids) { throw ResearchError("回测目标含未知策略") }
        let c=try Self(market:market,sessions:calendar,strategies:chosen)
        if let target,let why=c.problem(start:target.start,end:target.end) { throw ResearchError(why) }
        guard !c.windows.isEmpty else { throw ResearchError(c.issues.first?.message ?? "目标行情没有完成预热的可回测区间") }
        return c
    }
}
