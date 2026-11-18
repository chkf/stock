import Foundation

public struct SecurityCoverage {
    public let symbol:String
    public let firstBar,lastBar,firstSignal,lastSignal,listed:String?
    public let missingDays:Int
    public let gaps:[GapInterval]
}
public struct GapInterval {
    public let state:HistoryDayState,start:String,evidence:String?
    public fileprivate(set) var end:String,days:Int
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
        let requiredDays=strategies.map { s in ["GB","MV"].contains(s.id) && s.history==253 ? 252 : s.history }
        let lookback=requiredDays.max()!, thresholds=Array(Set(requiredDays))
        warmup=lookback
        let empty=Array(repeating:0,count:n)
        var counts=Dictionary(uniqueKeysWithValues:thresholds.map{($0,empty)}), domestic=counts
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
            for (d,events) in eventDays where first<=d && d<=market.as_of {
                if events.count>1 { flag(d,"公司行动","同日多项事件缺少已核执行次序"); continue }
                let e=events[0], cash=e.cash_per_share ?? 0, split=e.share_factor ?? 1
                if d>rules.reviewedThrough && (!(review?.spans.contains { $0.from<=d && d<=$0.through } ?? false) ||
                    !(review?.events.contains { Self.sameTerms(e,$0) } ?? false)) {
                    flag(d,"公司行动","超出原版已核日期，新事件缺公告和独立审核"); continue
                }
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
            for clue in sec.provider_events ?? [] where first<=clue.date && (clue.date<rules.anchor || clue.date>rules.reviewedThrough) && clue.date<=market.as_of {
                if let listing,clue.date<listing { continue }
                let reviewed=review?.spans.contains { $0.from<=clue.date && clue.date<=$0.through } ?? false
                if (reviewed || clue.date>rules.reviewedThrough) && !sec.events.contains(where:{ Self.matchesProvider(clue,reviewed:$0) }) {
                    flag(clue.date,"供应商行动","展示记录尚缺公告核定的除权、登记、到账或可卖安排")
                }
            }
            if let review, let known=review.earliestObserved, let firstBar, known<firstBar, known>=first {
                flag(known,"原价","已知更早原始记录，当前数据被截短")
            }
            var streak=0, missing=0, previousPrice:Double?, previousSignal:Double?, lastIssue:HistoryIssue?, lastIndex = -lookback-1
            var gaps=[GapInterval](),lastGap = -2
            for (i,d) in days.enumerated() {
                let bar=sec.bars[d], signal=sec.signal_close[d], g=review?.gaps[d], pre=listing.map { d<$0 } ?? false
                var issue=eventIssues[d]
                func problem(_ field:String,_ why:String) { if issue==nil { issue=HistoryIssue(symbol:s,date:d,field:field,reason:why) } }
                if let bar, !bar.valid { problem("原价","OHLC 或成交量无效") }
                if pre && (bar != nil || signal != nil) { problem("上市","上市公告前存在行情或信号") }
                if bar==nil {
                    let state:HistoryDayState
                    let evidence:String?
                    if pre { state = .beforeListing; evidence=review?.listing?.evidence }
                    else if let g { state=g.state; evidence=g.evidence }
                    else if Self.noTrade(s,d,market,rules) {
                        state=sec.statuses?[d]?.state=="no_trades_confirmed" ? .noTrades:.halted
                        evidence=sec.statuses?[d]?.source ?? member.halts[d] ?? "基金管理人折算实施公告"
                    } else { state=firstBar.map { d>=$0 } == true || listing != nil ? .missing:.unknown; evidence=nil }
                    if !pre { missing+=1 }
                    if lastGap==i-1,let last=gaps.last,last.state==state,last.evidence==evidence {
                        gaps[gaps.count-1].end=d; gaps[gaps.count-1].days+=1
                    } else { gaps.append(.init(state:state,start:d,evidence:evidence,end:d,days:1)) }
                    lastGap=i
                }
                if !pre {
                    let nonTrading=Self.noTrade(s,d,market,rules)
                    if let notice=SplitNotice.published.first(where:{ $0.symbol==s && $0.ex==d }),
                       let g, [.halted,.noTrades].contains(g.state) != notice.halted { problem("交易状态","与实施公告中的交易安排冲突") }
                    if g?.state == .missing || g?.state == .unknown { problem("原价",g!.state.rawValue+" 缺可核验的处理依据") }
                    if let bar, nonTrading && bar.volume>0 { problem("成交量","真实成交与已核停牌或无成交冲突") }
                    if bar==nil && !nonTrading {
                        problem("原价",firstBar.map { d<$0 } ?? true ? "UNKNOWN 缺上市依据或更早原价" : "SOURCE_MISSING 缺原价或正式停牌证据")
                    }
                    let covered=review?.spans.contains { $0.from<=d && d<=$0.through } ?? false
                    if d<rules.anchor && !covered { problem("公司行动","该日期缺历史行动完整性核验区间") }
                    if d>rules.reviewedThrough && !covered && sec.provider_events==nil { problem("公司行动","缺更新后的提供方原件或审核区间") }
                    let e=eventDays[d]?.first, cash=e?.cash_per_share ?? 0, split=e?.share_factor ?? 1
                    var mark=nonTrading ? nil : bar?.close
                    if let prev=previousPrice, prev>cash, split>0 {
                        let ref=(prev-cash)/split
                        if let bar, !nonTrading, issue==nil {
                            if let up=sec.statuses?[d]?.upper_limit,let down=sec.statuses?[d]?.lower_limit {
                                if up<down || down<=0 || bar.high>up+0.001 || bar.low<down-0.001 { problem("价格区间","与历史涨跌停证据相冲突") }
                            } else {
                                do { try PublicFeed.validateBand(bar,reference:ref,band:d<(member.bandFrom ?? "2016-01-01") ? 0.1:member.band,symbol:s,date:d) }
                                catch { problem("价格区间",error.localizedDescription) }
                            }
                        }
                        if nonTrading { mark=ref }
                        if let sig=signal, let old=previousSignal, let price=mark, ref>0 {
                            let expected=old*price/ref
                            if abs(sig-expected)>max(1e-10,abs(expected)*1e-9) { problem("复权信号","与原价、分红拆合正推不一致") }
                        }
                    }
                    if nonTrading && mark==nil { problem("停牌估值","缺事件前的已核参考价") }
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
                for length in thresholds where streak>=length {
                    counts[length]![i]+=1
                    if sec.group.hasPrefix("domestic") { domestic[length]![i]+=1 }
                }
            }
            descriptions.append(.init(symbol:s,firstBar:firstBar,lastBar:sec.bars.keys.max(),firstSignal:sec.signal_close.keys.min(),lastSignal:sec.signal_close.keys.max(),listed:listing,missingDays:missing,gaps:gaps))
        }
        var result=[StudyWindow](), sample=[String:Int](), failed=[String:HistoryIssue](), open:String?
        for (i,d) in days.enumerated() {
            let eligible=i==0 ? 0 : counts[lookback]![i-1]
            sample[d]=eligible
            var issue=dayProblem[i] ?? (i>0 ? dirty[i-1] : nil)
            if d<"2006-07-01" { issue = .init(symbol:"交易规则",date:d,field:"执行口径",reason:"早于原版支持的交易规则范围") }
            for (strategy,length) in zip(strategies,requiredDays) where issue==nil {
                let available=i==0 ? 0 : counts[length]![i-1]
                if available<(strategy.id=="MV" ? 3:1) || (strategy.id=="BANK_ELSE_GB" && (i==0 || domestic[length]![i-1]==0)) {
                    issue = .init(symbol:strategy.id,date:d,field:"预热",reason:"前一交易日仅 \(available) 只满足连续 \(length) 日，策略尚无足够合格样本")
                }
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
        (a.supported != false)==(b.supported != false) && (a.date_needs_reconciliation==true)==(b.date_needs_reconciliation==true)
    }
    static func matchesProvider(_ clue:ProviderEvent,reviewed:MarketEvent) -> Bool {
        if clue.share_factor==1 { return reviewed.date==clue.date && (reviewed.share_factor ?? 1)==1 && abs((reviewed.cash_per_share ?? 0)-clue.cash_per_share)<1e-10 }
        // Four displayed decimals identify a clue. Settlement always uses the separately audited exact factor.
        return (reviewed.date==clue.date || reviewed.record_date==clue.date) && abs((reviewed.share_factor ?? 1)-clue.share_factor)<=0.000051
    }
    static func forActivation(_ market:MarketSnapshot,calendar:Sessions) throws -> HistoryCoverage {
        guard !market.sources.isEmpty,market.as_of <= (try calendar.completed()) else { throw ResearchError("待启用行情缺来源或截止日尚未收盘") }
        let target=market.history?.replayTarget
        let all=try WorkspaceVersion.bundled().design.strategies
        let chosen=all.filter { target?.strategies?.contains($0.id) ?? true }
        if let ids=target?.strategies,Set(chosen.map(\.id)) != Set(ids) { throw ResearchError("回测目标含未知策略") }
        let c=try Self(market:market,sessions:calendar,strategies:chosen)
        let rules=try PublicRules.load()
        for (s,sec) in market.securities {
            guard sec.bars.keys.allSatisfy({ (try? calendar.index($0)) != nil && $0<=market.as_of }),
                  sec.signal_close.keys.allSatisfy({ (try? calendar.index($0)) != nil && $0<=market.as_of }) else { throw ResearchError("\(s) 原价或信号日期超出快照或交易日历") }
            let member=rules.members[s]!
            if let actual=sec.bars[rules.anchor]?.close, actual != member.anchorClose { throw ResearchError("\(s) \(rules.anchor) 原价与冻结锚点不同") }
            if let actual=sec.signal_close[rules.anchor],abs(actual-member.anchorSignal)>max(1e-10,abs(member.anchorSignal)*1e-9) { throw ResearchError("\(s) \(rules.anchor) 信号与冻结锚点不同") }
            if let actual=sec.bars[rules.reviewedThrough]?.close, actual != member.reviewedClose { throw ResearchError("\(s) \(rules.reviewedThrough) 原价与核定收盘不同") }
        }
        if let target,let why=c.problem(start:target.start,end:target.end) { throw ResearchError(why) }
        guard !c.windows.isEmpty else { throw ResearchError(c.issues.first?.message ?? "目标行情没有完成预热的可回测区间") }
        return c
    }
}
