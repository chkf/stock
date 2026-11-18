import Foundation
import ResearchCore

enum WorkspaceCheck {
    static func decisions(_ expected:[String:[String:Any]],strategy:String,engine:StrategyEngine) throws {
        var prior:Decision?
        for day in expected.keys.sorted() {
            let signal=try engine.decision(strategy,on:day,previousState:prior?.marketState ?? "UNKNOWN",previousSectors:prior?.sectorStates ?? [:])
            guard let target=expected[day]?["weights"] as? [String:Double],signal.route==expected[day]?["route"] as? String,
                  signal.selected==expected[day]?["selected"] as? [String],
                  Set(target.keys)==Set(signal.weights.keys),target.allSatisfy({ abs(signal.weights[$0.key]!-$0.value)<=1e-12 }) else {
                throw ResearchError("\(strategy) \(day) 选取或权重与独立 Python 不同")
            }
            prior=signal
        }
    }
    static func run(directory: URL, output: URL) throws {
        let data=try Data(contentsOf:directory.appendingPathComponent("market.json"))
        let m=try JSONDecoder().decode(MarketSnapshot.self,from:data)
        let expected=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("expected.json"))) as! [String:Any]
        let hash=Integrity.sha(data)
        guard hash == expected["snapshot"] as? String else { throw ResearchError("原始快照标识不同") }
        let w=try WorkspaceVersion.bundled(), engine=try StrategyEngine(market:m,sessions:Sessions(),workspace:w)
        var problems=[String](), summary=[[String:Any]]()
        let signals=expected["signals"] as! [[String:Any]]
        for signal in signals {
            let d=try engine.decision("BANK_ELSE_GB",on:signal["date"] as! String)
            let weights=signal["weights"] as! [String:Double], breadth=signal["breadth"] as! [String:Double]
            if d.route != signal["route"] as? String || d.marketState != signal["state"] as? String ||
                Set(d.weights.keys) != Set(weights.keys) || Set(d.breadth.keys) != Set(breadth.keys) ||
                breadth.contains(where:{ abs((d.breadth[$0.key] ?? -1)-$0.value)>1e-12 }) ||
                  weights.contains(where:{ abs((d.weights[$0.key] ?? -1)-$0.value)>1e-9 }) { problems.append("\(d.date) 混合分支或目标与 Python 不同") }
        }
        let reference=expected["studies"] as! [String:[String:Any]], start=expected["start"] as! String, end=expected["end"] as! String
        for strategy in w.design.strategies {
            let exp=reference[strategy.id]!, curve=exp["curve"] as! [[Any]], orders=exp["orders"] as! [[Any]]
            let scheduled=exp["decisions"] as? [String:[String:Any]] ?? [:]
            try decisions(scheduled,strategy:strategy.id,engine:engine)
            var resume: ReplayReport?
            let report=try engine.replay(strategy.id,snapshot:hash,start:start,end:end,checkpoint:{ r,_ in if resume == nil { resume=r } })
            let continued=try engine.replay(strategy.id,snapshot:hash,start:start,end:end,resume:resume)
            let enc=JSONEncoder(); enc.outputFormatting=[.sortedKeys]
            if try enc.encode(report) != enc.encode(continued) { problems.append("\(strategy.id) 恢复结果不一致") }
            let matchedCurve = report.curve.count==curve.count && zip(report.curve,curve).allSatisfy { a,b in
                a.date == b[0] as? String && (a.equity*100).rounded()==((b[1] as! Double)*100).rounded()
            }
            let matchedFills = report.trades.count==orders.count && zip(report.trades,orders).allSatisfy { a,b in
                a.date==b[0] as? String && a.symbol==b[1] as? String && a.side==b[2] as? String && a.quantity==b[3] as? Int && a.price==b[4] as? Double && a.fees==b[5] as? Double
            }
            if !matchedCurve || !matchedFills {
                let wrong=zip(report.curve,curve).first { a,b in abs(a.equity-(b[1] as! Double))>=0.005 }
                problems.append("\(strategy.id) 逐日资金 \(matchedCurve) 成交 \(matchedFills)；首处分歧 \(wrong?.0.date ?? "无")")
            }
            summary.append(["strategy":strategy.id,"sessions":report.curve.count,"fills":report.trades.count,"closed":report.cycles.count,"curveMatchesToCent":matchedCurve,"tradesMatch":matchedFills,"decisions":scheduled.count])
        }
        let evidence:[String:Any]=["snapshot":hash,"workspace":w.hash,"start":start,"end":end,"routeDates":signals.map { [$0["date"]!,$0["route"]!] },"studies":summary,"issues":problems]
        try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys,.prettyPrinted]).write(to:output,options:.atomic)
        for problem in problems { print(problem) }
        guard problems.isEmpty else { throw ResearchError("工作区回测存在 \(problems.count) 处差异") }
        print("原版四种混合分支、五套资金曲线、逐笔成交、检查点恢复全部通过")
    }
}
