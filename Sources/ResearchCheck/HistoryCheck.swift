import Foundation
import ResearchCore

/// Offline replay of unmodified public responses and a legacy PHONE data copy. Does not open personal data.
enum HistoryCheck {
    static func run(example:URL, oldRoot:URL, output:URL, export:URL?=nil) async throws {
        let fm=FileManager.default, temp=fm.temporaryDirectory.appendingPathComponent("history-study-"+UUID().uuidString)
        defer { try? fm.removeItem(at:temp) }
        let data=temp.appendingPathComponent("数据"), input=temp.appendingPathComponent("输入")
        try fm.createDirectory(at:data,withIntermediateDirectories:true); try fm.createDirectory(at:input,withIntermediateDirectories:true)
        try fm.copyItem(at:oldRoot.appendingPathComponent("public-market"),to:data.appendingPathComponent("public-market"))
        try fm.copyItem(at:example.appendingPathComponent("历史核验"),to:input.appendingPathComponent("历史核验"))
        let vault=PrivateLibrary(root:data), start="2024-10-08"
        guard let before=try await vault.phoneMarket(),before.market.schema=="iphone-public-market-1" else { throw ResearchError("需要旧版手机公开行情副本") }
        let through=before.market.as_of,cal=try Sessions(),workspace=try WorkspaceVersion.bundled()
        let oldCoverage=try HistoryCoverage(market:before.market,sessions:cal,strategies:workspace.design.strategies)
        let oracle=try JSONSerialization.jsonObject(with:Data(contentsOf:example.appendingPathComponent("oracle/expected.json"))) as! [String:Any]
        let studies=oracle["studies"] as! [String:[String:Any]],studyFrom=oracle["start"] as! String,studyEnd=oracle["end"] as! String
        guard oldCoverage.problem(start:studyFrom,end:studyEnd) != nil else { throw ResearchError("该区间在旧库已有足够预热") }
        var requests=0
        func replay(_ url:URL) async throws ->Data {
            requests+=1
            if let param=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first?.value {
                let parts=param.components(separatedBy:",")
                guard parts.count==6,parts[2]==start,parts[3]=="2025-01-02" else { throw ResearchError("出现未实取的分页 URL "+url.absoluteString) }
                let s=String(parts[0].suffix(6))+"."+String(parts[0].prefix(2)).uppercased()
                return try Data(contentsOf:example.appendingPathComponent(s+".json"))
            }
            let code=String(url.deletingPathExtension().lastPathComponent.suffix(6))
            guard let key=before.market.sources.keys.sorted().first(where:{ $0.contains("/"+code+".") && $0.contains(".actions-") }) else { throw ResearchError("缺行动原件 "+code) }
            return try await vault.onlineEvidence(key,snapshot:before)
        }
        do {
            _=try await vault.rebuildPublicMarket(from:start,through:through,fetch:{ url in
                if requests==4 { throw CancellationError() }; return try await replay(url)
            },progress:{ _ in })
            throw ResearchError("模拟中断未停止")
        } catch is CancellationError {}
        guard try await PrivateLibrary(root:data).phoneMarket()?.hash==before.hash else { throw ResearchError("取消覆盖旧代") }
        let resumed=PrivateLibrary(root:data)
        let updated=try await resumed.rebuildPublicMarket(from:start,through:through,fetch:replay,progress:{ _ in })
        guard updated.hash != before.hash, requests==56 else { throw ResearchError("同截止日未扩展，或已完成页被重复下载 \(requests)") }
        let repeated=try await resumed.rebuildPublicMarket(from:start,through:through,fetch:{ _ in throw ResearchError("完成后又联网") },progress:{ _ in })
        guard repeated.hash==updated.hash else { throw ResearchError("重跑不幂等") }
        for (s,old) in before.market.securities {
            guard let current=updated.market.securities[s],old.bars.allSatisfy({ current.bars[$0.key]==$0.value }),
                  old.signal_close.allSatisfy({ current.signal_close[$0.key]==$0.value }) else { throw ResearchError(s+" 旧区间改变") }
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            guard try encoder.encode(old.events)==encoder.encode(current.events.filter { $0.date>="2025-01-02" }) else { throw ResearchError(s+" 旧公司行动改变") }
        }
        guard before.market.sources.allSatisfy({updated.market.sources[$0.key]==$0.value}) else { throw ResearchError("旧原件来源身份改变") }
        let coverage=try HistoryCoverage(market:updated.market,sessions:cal,strategies:workspace.design.strategies)
        if let why=coverage.problem(start:studyFrom,end:studyEnd) { throw ResearchError(why) }
        let engine=StrategyEngine(market:updated.market,sessions:cal,workspace:workspace)
        var rows=[[String:Any]]()
        for s in workspace.design.strategies {
            let expected=studies[s.id]!, orders=expected["orders"] as! [[Any]], curve=expected["curve"] as! [[Any]]
            guard let decisions=expected["decisions"] as? [String:[String:Any]],!decisions.isEmpty else { throw ResearchError(s.id+" 缺独立 Python 调仓记录") }
            try WorkspaceCheck.decisions(decisions,strategy:s.id,engine:engine)
            var checkpoint:ReplayReport?
            let report=try engine.replay(s.id,snapshot:updated.hash,start:studyFrom,end:studyEnd,checkpoint:{ if checkpoint==nil { checkpoint=$0 }; _=$1 })
            let continued=try engine.replay(s.id,snapshot:updated.hash,start:studyFrom,end:studyEnd,resume:checkpoint)
            let enc=JSONEncoder(); enc.outputFormatting=[.sortedKeys]
            guard try enc.encode(report)==enc.encode(continued), report.trades.count==orders.count,report.curve.count==curve.count,
                  zip(report.trades,orders).allSatisfy({ f,r in f.date==r[0] as? String && f.symbol==r[1] as? String && f.side==r[2] as? String && f.quantity==r[3] as? Int && f.price==r[4] as? Double && f.fees==r[5] as? Double }),
                  zip(report.curve,curve).allSatisfy({ point,r in point.date==r[0] as? String && (point.equity*100).rounded()==((r[1] as! Double)*100).rounded() })
            else { throw ResearchError(s.id+" 旧版 Python 与 Swift 的逐笔成交、权益或恢复不一致") }
            rows.append(["strategy":s.id,"fills":orders.count,"sessions":curve.count,"decisions":decisions.count])
        }
        if let export {
            try fm.createDirectory(at:export,withIntermediateDirectories:true)
            let bytes=try Data(contentsOf:data.appendingPathComponent("public-market/snapshots/"+updated.hash+".json"))
            guard Integrity.sha(bytes)==updated.hash else { throw ResearchError("导出样例的原始快照发生变化") }
            try bytes.write(to:export.appendingPathComponent("phone-verified.json"),options:.withoutOverwriting)
            for key in updated.market.sources.keys {
                let to=export.appendingPathComponent(key)
                try fm.createDirectory(at:to.deletingLastPathComponent(),withIntermediateDirectories:true)
                try await resumed.onlineEvidence(key,snapshot:updated).write(to:to,options:.withoutOverwriting)
            }
        }
        let restored=try await resumed.restorePreviousPhoneMarket()
        guard restored.hash==before.hash else { throw ResearchError("还原未找回原手机快照") }
        let recovered=try await PrivateLibrary(root:data).restorePreviousPhoneMarket()
        guard recovered.hash==updated.hash else { throw ResearchError("切回上一代后不能重新启用已验证的回填代") }
        let empty=temp.appendingPathComponent("cold/数据"),cold=PrivateLibrary(root:empty)
        try fm.createDirectory(at:empty.deletingLastPathComponent().appendingPathComponent("输入"),withIntermediateDirectories:true)
        try fm.copyItem(at:input.appendingPathComponent("历史核验"),to:empty.deletingLastPathComponent().appendingPathComponent("输入/历史核验"))
        let rebuilt=try await cold.rebuildPublicMarket(from:start,through:through,fetch:{ url in
            if let csv=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first?.value {
                let parts=csv.components(separatedBy:",")
                let s=String(parts[0].suffix(6))+"."+String(parts[0].prefix(2)).uppercased()
                if parts[3]<"2025-01-02" { return try Data(contentsOf:example.appendingPathComponent(s+".json")) }
                guard let key=before.market.sources.keys.first(where:{$0.hasSuffix("/"+s+".quotes.json")}) else { throw ResearchError(s+" 旧原价响应缺失") }
                return try await vault.onlineEvidence(key,snapshot:before)
            }
            let code=String(url.deletingPathExtension().lastPathComponent.suffix(6))
            guard let key=before.market.sources.keys.first(where:{$0.contains("/"+code+".") && $0.contains(".actions-")}) else { throw ResearchError(code+" 行动响应缺失") }
            return try await vault.onlineEvidence(key,snapshot:before)
        },progress:{ _ in })
        for (s,sec) in updated.market.securities {
            guard let fresh=rebuilt.market.securities[s],fresh.bars==sec.bars,Set(fresh.signal_close.keys)==Set(sec.signal_close.keys),
                  sec.signal_close.allSatisfy({abs(fresh.signal_close[$0.key]!-$0.value)<=max(1e-10,abs($0.value)*1e-9)}) else { throw ResearchError(s+" 空库回填与延长已有库不一致") }
        }
        let proof:[String:Any]=["source":"腾讯未复权、封存基金行动 HTML、Windows Python 封存快照","oldPhone":before.hash,"candidate":updated.hash,
            "firstBar":coverage.from,"through":coverage.through,"verifiedIntervals":coverage.windows.map { [$0.start,$0.end] },
            "pythonComparison":[studyFrom,studyEnd],"studies":rows,"resumedRequests":requests,"unchangedTail":true,"rollbackChecked":true,"coldBackfillChecked":true,"device":"桌面 Swift 离线复算"]
        try JSONSerialization.data(withJSONObject:proof,options:[.sortedKeys,.prettyPrinted]).write(to:output,options:.atomic)
        print("同截止日真实回填、断点、幂等、原价信号和原件不变；五套策略 "+studyFrom+" 至 "+studyEnd+" 通过 Python 逐笔对账")
    }
}
