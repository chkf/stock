import Foundation

extension PrivateLibrary {
    func collectHistory(from requested:String?, through:String, fetch:@escaping (URL) async throws -> Data,
                        progress:@escaping (TransferProgress)->Void) async throws -> PhoneSnapshot {
        guard !updatingQuotes else { throw ResearchError("行情候选正在收集") }
        try HistoryWriters.shared.claim(root); defer { HistoryWriters.shared.release(root) }
        updatingQuotes=true; defer { updatingQuotes=false }
        let rules=try PublicRules.load(), cal=try Sessions(), prior=try phoneMarket()
        let dir=root.appendingPathComponent("public-market"), old=prior?.market
        let oldFrom=old?.history?.from ?? old?.securities.values.compactMap { $0.bars.keys.min() }.min()
        let requestedStart=requested ?? oldFrom ?? rules.anchor
        guard try cal.index(requestedStart)<=cal.index(through), through >= old?.as_of ?? through,
              through <= (try cal.completed()) else { throw ResearchError("请求须使用已收盘的交易日，已有快照的截止日不能倒退") }
        if let prior, through==prior.market.as_of, let oldFrom, requestedStart>=oldFrom { return prior }
        let backfill=oldFrom.map { requestedStart<$0 } ?? (requestedStart<rules.anchor)
        let first=backfill ? requestedStart : (old?.as_of ?? min(requestedStart,rules.anchor))
        let pivot=(backfill || old==nil) ? rules.anchor : old!.as_of
        let prefixOnly=backfill && old?.as_of==through
        let fetchEnd=prefixOnly ? pivot : max(through,pivot), firstIndex=try cal.index(first), end=try cal.index(fetchEnd)
        let days=Array(cal.days[firstIndex...end])
        let input=try ReviewInput.read(root.deletingLastPathComponent().appendingPathComponent("输入/历史核验"),into:dir)
        let supplied=try input?.review.extending(old?.history) ?? old?.history
        let enc=JSONEncoder(); enc.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        var contract=try FrozenInputs.data("PublicRules.json")
        contract.append(try FrozenInputs.data("XSHG.txt")); contract.append(Data(HistoryCandidate.parser.utf8))
        if let supplied { contract.append(try enc.encode(supplied)) }
        let rulesID=Integrity.sha(contract)
        var stage=try HistoryCandidate(root:dir,parent:prior?.hash,from:first,through:through,rules:rulesID)
        let marketFrom=min(oldFrom ?? first,first)
        var sources=old?.sources ?? [:]; sources.merge(input?.sources ?? [:]) { old,_ in old }
        var market=MarketSnapshot(schema:"iphone-public-market-2",as_of:through,securities:old?.securities ?? [:],sources:sources,
            extras:old?.extras ?? [:],limitations:["原始日线用于成交，归一化信号用于选取；结算按单账户建模。"],
            history:HistoryReview(schema:HistoryReview.version,from:marketFrom,through:through,symbols:supplied?.symbols ?? [:],replayTarget:supplied?.replayTarget))
        do {
            for (index,s) in rules.members.keys.sorted().enumerated() {
                try Task.checkCancellation()
                let member=rules.members[s]!, review=market.history?.symbols[s], previous=old?.securities[s]
                let base=review?.listing.map { max(first,$0.date) } ?? first
                // Ask for the previous real session as context only when price events require it on day one.
                let needsContext=review?.events.contains(where:{ $0.date==base }) == true || member.events.contains { $0.date==base }
                let baseIndex=try cal.index(base)
                let low=needsContext && baseIndex>0 ? cal.days[baseIndex-1] : base
                let bars=try await HistoryPages.collect(symbol:s,from:low,through:fetchEnd,calendar:cal,previous:previous?.bars ?? [:]) { cursor,page in
                    progress(.init(phase:"\(s) 原价第 \(page+1) 页 · 至 \(cursor)",completed:index*2,total:56))
                    let url=PublicFeed.quoteURL(s,low,cursor), name=page==0 ? s+".quotes.json" : s+"."+cursor+".quotes.json"
                    let data=try await stage.capture(url,name:name,fetch:fetch) { bytes in
                        let decoded=try PublicFeed.quotes(bytes,symbol:s,from:low,through:cursor)
                        for d in decoded.keys { _=try cal.index(d) }
                    }
                    return try PublicFeed.quotes(data,symbol:s,from:low,through:cursor)
                }
                progress(.init(phase:"\(s) 公司行动和连续性",completed:index*2+1,total:56))
                let html=try await stage.capture(PublicFeed.actionsURL(s),name:s+".actions-0.html",fetch:fetch) { data in
                    let events=try PublicFeed.actions(data,symbol:s,rules:rules)
                    try PublicFeed.validateHistory(events,old:member.provider,through:min(fetchEnd,rules.reviewedThrough),symbol:s)
                    if let p=previous?.provider_events, let old { try PublicFeed.validateHistory(events,old:p,through:old.as_of,symbol:s) }
                }
                do {
                    let provider=try PublicFeed.actions(html,symbol:s,rules:rules)
                    var events=(review?.events ?? []).filter { $0.date<rules.anchor && $0.date<=fetchEnd }
                    events+=member.events.filter { $0.date<=fetchEnd }
                    for e in provider where rules.reviewedThrough<e.date && e.date<=fetchEnd {
                        guard e.share_factor==1,e.supported,!e.needsReview,let record=e.record_date, let pay=e.payment_date,
                              record<e.date,pay>=e.date else { throw ResearchError("\(s) \(e.date) 新事件缺审核、权益登记或到账依据") }
                        events.append(.init(date:e.date,cash_per_share:e.cash_per_share,share_factor:1,record_date:record,source:PublicFeed.actionsURL(s).absoluteString,payment_date:pay))
                    }
                    if first<rules.anchor {
                        for e in provider where base<=e.date && e.date<rules.anchor {
                            let matches=events.contains { HistoryCoverage.matchesProvider(e,reviewed:$0) }
                            guard matches else { throw ResearchError("\(s) \(e.date) 供应商行动线索缺正式登记、精确比例或去向复核") }
                        }
                    }
                    for d in days where d>=base && d<rules.anchor && !(review?.spans.contains { $0.from<=d && d<=$0.through } ?? false) {
                        throw ResearchError("\(s) \(d) 缺历史公司行动完整性审核，可补入核验材料后续算")
                    }
                    func previousMark(before day:String) -> Double? {
                        guard let previous,let lastDay=previous.bars.keys.filter({ $0<day && !HistoryCoverage.noTrade(s,$0,market,rules) }).max(),var mark=previous.bars[lastDay]?.close else { return nil }
                        for e in previous.events.filter({lastDay<$0.date && $0.date<day}).sorted(by:{$0.date<$1.date}) {
                            mark=(mark-(e.cash_per_share ?? 0))/(e.share_factor ?? 1)
                        }
                        return mark
                    }
                    let anchor=bars[pivot]?.close ?? previous?.bars[pivot]?.close
                    guard anchor != nil || HistoryCoverage.noTrade(s,pivot,market,rules),
                          let seed=previous?.signal_close[pivot] ?? (pivot==rules.anchor ? member.anchorSignal : nil),
                          pivot != rules.anchor || anchor==member.anchorClose else { throw ResearchError("\(s) \(pivot) 原价或信号锚点冲突") }
                    if first<=rules.reviewedThrough && rules.reviewedThrough<=fetchEnd, bars[rules.reviewedThrough]?.close != member.reviewedClose {
                        throw ResearchError("\(s) \(rules.reviewedThrough) 核定收盘已修订")
                    }
                    let signals=try HistoryAdjustment.signals(symbol:s,days:days,bars:bars,anchor:pivot,anchorSignal:seed,
                        previousClose:(needsContext && low<first ? bars[low]?.close:nil) ?? previousMark(before:first),events:events,
                        listed:review?.listing?.date,nonTrading:{ HistoryCoverage.noTrade(s,$0,market,rules) },
                        band:{ $0 < (member.bandFrom ?? "2016-01-01") ? 0.1 : member.band })
                    var sec=previous ?? MarketSecurity(name:member.name,group:member.group,bars:[:],signal_close:[:],events:[],provider_events:nil)
                    for (day,px) in signals where day<=through {
                        if let prior=sec.signal_close[day],abs(prior-px)>max(1e-10,abs(px)*1e-9) { throw ResearchError("\(s) \(day) 与旧信号不一致") }
                        if sec.signal_close[day]==nil { sec.signal_close[day]=px }
                    }
                    for (day,bar) in bars where first<=day && day<=through { sec.bars[day]=bar }
                    for e in events where first<=e.date && e.date<=through {
                        if let existing=sec.events.first(where:{ $0.date==e.date }) {
                            guard HistoryCoverage.sameTerms(existing,e) else { throw ResearchError("\(s) \(e.date) 旧事件有修订") }
                        } else { sec.events.append(e) }
                    }
                    sec.events.sort { $0.date<$1.date }
                    if let old, let priorEvents=previous?.provider_events {
                        sec.provider_events=priorEvents + provider.filter { old.as_of<$0.date && $0.date<=through }
                    } else { sec.provider_events=provider.filter { $0.date<=through } }
                    market.securities[s]=sec
                    stage.journal.blockers?[s]=nil
                } catch is CancellationError { throw CancellationError() }
                catch {
                    stage.journal.blockers=(stage.journal.blockers ?? [:]).merging([s:error.localizedDescription]) { _,new in new }
                    try stage.save()
                }
            }
            if let blockers=stage.journal.blockers,!blockers.isEmpty {
                let reasons=blockers.keys.sorted().compactMap { blockers[$0] }
                throw ResearchError("\(blockers.count) 只 ETF 无法启用；"+reasons.joined(separator:"\n"))
            }
            market.sources.merge(stage.sources) { keep,_ in keep }
            let coverage=try HistoryCoverage.forActivation(market,calendar:cal)
            if let i=coverage.issues.first(where:{ $0.date>=first && $0.date<=through }) { throw ResearchError(i.message) }
            guard let firstWindow=coverage.windows.first else { throw ResearchError("目标区间尚未满足策略预热或核验要求") }
            try Task.checkCancellation()
            let current=try readQuoteID()
            guard current==prior?.hash else { throw ResearchError("采集时活动行情已切换，请基于新版本重试") }
            let candidate=PhoneSnapshot(market:market,hash:"",usableFrom:nil)
            for key in market.sources.keys {
                try Task.checkCancellation()
                _=try onlineEvidence(key,snapshot:candidate)
            }
            try market.history?.verifyEvidence(sources:market.sources) { try onlineEvidence($0,snapshot:candidate) }
            try market.history?.verifyPrices(in:market) { try onlineEvidence($0,snapshot:candidate) }
            try Task.checkCancellation()
            let (receipt,sha)=try stage.record("accepted")
            guard Integrity.sha(try Data(contentsOf:dir.appendingPathComponent(receipt)))==sha else { throw ResearchError("候选核验回执写入失败") }
            market.sources[receipt]=sha
            let bytes=try enc.encode(market),id=Integrity.sha(bytes)
            try publishQuote(bytes,id:id,through:through,parent:prior?.hash)
            progress(.init(phase:"已核验并启用",completed:56,total:56))
            return PhoneSnapshot(market:market,hash:id,usableFrom:cal.days[try cal.index(firstWindow.start)-1])
        } catch {
            _ = try? stage.record(error is CancellationError || error is HistoryFetchPause ? "paused" : "refused",reason:error.localizedDescription)
            throw error
        }
    }
}
