import Foundation

extension VerifiedUniverse {
    func check(_ symbol:String,day:String,windowStart:String,history:Int) throws -> (PointMetadata,Int) {
        if let reason=issues[symbol]?[day] { throw ResearchError("\(symbol) \(day) · \(reason)") }
        guard day>=from, let entry=listings[symbol], let meta=entry.metadata(on:day), let length=lengths[symbol]?[day] else { throw ResearchError("\(symbol) \(day) 缺已核行情或历史资格") }
        if length<history && (entry.listed<=windowStart || (windowStart<from && entry.listed<from)) { throw ResearchError("\(symbol) \(day) 已上市，窗口内缺已核历史，不能作为上市预热") }
        return (meta,length)
    }
}

extension WorkspaceVersion {
    static func strategyConfig(_ bytes:Data?,on date:String) throws -> [String:Any] {
        guard let bytes else { return [:] }
        guard let config=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],config["schema"] as? String=="etf-strategy-config-1",let versions=config["versions"] as? [[String:Any]] else { throw ResearchError("策略配置缺带时间的参数版本") }
        var selected=[String:Any](),previous:(String,String)?
        for version in versions {
            guard let effective=version["effective"] as? String,let known=version["known"] as? String,let values=version["values"] as? [String:Any],
                  ExchangeDay.date(effective) != nil,ExchangeDay.date(known) != nil,previous.map({ $0 < (effective,known) }) ?? true else { throw ResearchError("策略配置版本日期无效或重复") }
            if effective<=date && known<=date { selected=values };previous=(effective,known)
        }
        return selected
    }
    func universeDecision(_ strategy:StrategyFile,req:UniverseRequirements,market:MarketSnapshot,calendar:Sessions,date:String,previous:String,sectors:[String:String],code:String,config:Data?) throws -> Decision {
        guard let data=market.universe, date>=data.from else { throw ResearchError("目录策略需要已核目录行情") }
        let last=try calendar.index(date), first=last-strategy.history+1
        guard first>=0 else { throw ResearchError("窗口超出已核交易日历") }
        let visible=data.listings.keys.filter { data.listings[$0]!.active(date) }.sorted()
        guard visible.count<=min(32_768,200_000/req.screenHistory) else { throw ResearchError("screen 输入超过本机预算") }
        var ready=Set<String>(), info=[String:[String:Any]](), listings=[String:[String]](), metaHashes=[String:String]()
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        for symbol in visible {
            try Task.checkCancellation()
            let entry=data.listings[symbol]!, (meta,length)=try data.check(symbol,day:date,windowStart:calendar.days[first],history:strategy.history)
            let allowed=meta.candidate && length>=strategy.history
            if allowed { ready.insert(symbol) }
            listings[symbol]=[entry.listed,entry.listingEvidence]; metaHashes[symbol]=Integrity.sha(try encoder.encode(meta))
            info[symbol]=["name":meta.name,"group":meta.group,"assetClass":meta.assetClass,"role":meta.role,"indexID":meta.indexID,
                "candidate":meta.candidate,"eligible":allowed,"listed":entry.listed,"listedEvidence":entry.listingEvidence,
                "state":market.securities[symbol]?.statuses?[date]?.state ?? "unknown","verifiedHistory":length,
                "reason":allowed ? NSNull() as Any : (meta.candidate ? "listingWarmup":"notCandidate"),
                "effective":meta.effective,"known":meta.known,"evidence":meta.evidence]
        }
        let catalogVersion=Integrity.sha(try encoder.encode(listings)), metadataVersion=Integrity.sha(try encoder.encode(metaHashes))
        func invoke(_ stage:String,symbols:[String],window:Int) throws -> Data {
            guard symbols.count<=200_000/window else { throw ResearchError("\(stage) 输入窗口超过本机单次预算") }
            let days=Array(calendar.days[(last-window+1)...last]); var securities=[String:[String:Any]]()
            for symbol in symbols {
                var row=info[symbol]!
                row["close"]=days.map { market.securities[symbol]?.signal_close[$0] as Any? ?? NSNull() }
                row["turnover"]=days.map { data.turnover[symbol]?[$0] as Any? ?? NSNull() }; securities[symbol]=row
            }
            let encoded=try JSONSerialization.data(withJSONObject:securities,options:[.sortedKeys])
            guard encoded.count<=8*1024*1024 else { throw ResearchError("\(stage) 策略输入超过 8 MiB") }
            let input:[String:Any]=["contractVersion":2,"catalogVersion":catalogVersion,"metadataVersion":metadataVersion,
                "marketVersion":Integrity.sha(encoded),"stage":stage,"strategy":strategy.id,"date":date,"dates":days,
                "previousState":previous,"previousSectors":sectors,"securities":securities,"turnoverUnit":"CNY",
                "config":try Self.strategyConfig(config,on:date)]
            let prelude="globalThis.Date=undefined; Math.random=()=>{throw Error('random not available in replay')};\n"
            let script=prelude+code+(stage=="screen" ? "\n;globalThis.run=screen;" : "")
            return try Self.execute(script,file:strategy.file,input:JSONSerialization.data(withJSONObject:input,options:[.sortedKeys]))
        }
        let selected=ready.isEmpty ? [] : try JSONDecoder().decode([String].self,from:invoke("screen",symbols:visible,window:req.screenHistory))
        guard Set(selected).count==selected.count,Set(selected).isSubset(of:ready) else { throw ResearchError("screen 返回重复、未预热或非候选证券") }
        if selected.isEmpty {
            let why=visible.isEmpty ? "noListedProducts" : ready.isEmpty ? (visible.contains { data.listings[$0]?.metadata(on:date)?.candidate==true } ? "listingWarmup":"noCandidates") : "screenEmpty"
            guard req.insufficient=="cash" else { throw ResearchError("\(date) · \(why)") }
            return Decision(strategy:strategy.id,route:"CASH",marketState:previous,date:date,selected:[],weights:[:],scores:[:],breadth:[:],sectorStates:sectors,protection:[],waitReason:why)
        }
        let decision=try JSONDecoder().decode(Decision.self,from:invoke("run",symbols:selected,window:strategy.history))
        let allowed=Set(selected)
        guard decision.strategy==strategy.id, decision.date==date,Set(decision.selected).count==decision.selected.count,
              Set(decision.selected).isSubset(of:allowed), Set(decision.weights.keys).isSubset(of:allowed), Set(decision.scores.keys).isSubset(of:allowed),
              Set(decision.protection ?? []).isSubset(of:allowed), decision.weights.values.allSatisfy({ $0.isFinite && $0>=0 }),
              decision.weights.values.reduce(0,+)<=1.0000000001,(decision.exitDrawdown ?? 0.2)>0,(decision.exitDrawdown ?? 0.2)<=1,decision.waitReason==nil
        else { throw ResearchError("\(strategy.file) 输出超出已核候选或权重范围") }
        return decision
    }
}
