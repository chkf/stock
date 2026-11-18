import XCTest
@testable import ResearchCore

final class ReplayFundingTests:XCTestCase {
    func reviewed(_ days:[String]) throws -> MarketSnapshot {
        let rules=try PublicRules.load(), proof="synthetic-funding-test"
        var securities=[String:MarketSecurity](), reviews=[String:SecurityReview]()
        for s in MarketSnapshot.pool {
            let bars=Dictionary(uniqueKeysWithValues:days.map { ($0,Bar(open:10,close:10,high:10,low:10,volume:100000)) })
            securities[s] = .init(name:s,group:rules.members[s]!.group,bars:bars,signal_close:bars.mapValues(\.close),events:[],provider_events:[])
            reviews[s] = .init(listing:.init(date:days.first!,evidence:proof),spans:[.init(from:days.first!,through:days.last!,evidence:proof)],gaps:[:],events:[],issues:[])
        }
        return .init(schema:"advice-market-v1",as_of:days.last!,securities:securities,sources:[proof:Integrity.sha(Data("synthetic".utf8))],extras:[:],limitations:["合成资金测试"],
                     history:.init(schema:HistoryReview.version,from:days.first!,through:days.last!,symbols:reviews))
    }
    func testFullCostBudgetAndSplitCommission() {
        let settings=StudySettings.original
        let a=ReplayFunding.required(100,price:141.36,settings:settings)
        let b=ReplayFunding.required(100,price:135.943,settings:settings)
        XCTAssertEqual(a,14148.07); XCTAssertEqual(b,13606.10)
        let required=["511010.SH":a,"511260.SH":b]
        XCTAssertEqual(ReplayFunding.budgets(required,cash:48040.36),required)
        XCTAssertEqual(ReplayFunding.budgets(required,cash:27754.17),required)
        let scarce=ReplayFunding.budgets(required,cash:27000)
        XCTAssertEqual(scarce.values.reduce(0,+),27000,accuracy:1e-8)
        XCTAssertEqual(scarce["511010.SH"]!/scarce["511260.SH"]!,a/b,accuracy:1e-12)
        XCTAssertEqual(ReplayFunding.budgets([:],cash:0),[:])
        XCTAssertEqual(ReplayFunding.required(99,price:10,settings:settings),0)
        let minimumOnly=StudySettings(capital:50000,commissionRate:0,minimumCommission:5,slippageRate:0,rebalanceBand:0.03)
        XCTAssertEqual(ReplayFunding.required(1_000_100,price:0.01,settings:minimumOnly),10011)
    }

    func workspace(capital:Double=50000,price:Double?=nil) throws -> WorkspaceVersion {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store=WorkspaceStore(root:dir); try store.installIfNeeded()
        let config=store.working.appendingPathComponent("workspace.json")
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:config)) as? [String:Any])
        json["strategies"]=[["id":"FUNDING","file":"策略/资金.js","title":"资金测试","short":"资金","history":2,"rebalance":"monthly"]]
        var study=try XCTUnwrap(json["study"] as? [String:Any]); study["capital"]=capital; json["study"]=study
        try JSONSerialization.data(withJSONObject:json).write(to:config)
        let w=price==nil ? 0.35 : 0.5
        let script="""
        function run(input) { return {strategy:input.strategy,date:input.date,route:'MV',marketState:'TRANSITION',
          selected:['511010.SH','511260.SH'],weights:{'511010.SH':\(w),'511260.SH':\(w)},scores:{},breadth:{},protection:[]}; }
        """
        try Data(script.utf8).write(to:store.working.appendingPathComponent("策略/资金.js"))
        return try store.activate()
    }

    func testActualBondFillsResumeAndOldVersionIsolation() throws {
        let cal=try Sessions(),i=try cal.index("2024-12-02"),days=Array(cal.days[i...i+27])
        var m=try reviewed(days)
        for (s,p) in ["511010.SH":141.36,"511260.SH":135.943] {
            for d in days { m.securities[s]!.bars[d] = .init(open:p,close:p,high:p,low:p,volume:100000); m.securities[s]!.signal_close[d]=p }
        }
        let engine=StrategyEngine(market:m,sessions:cal,workspace:try workspace())
        var prefix:ReplayReport?, seen=[StudyLedgerDay]()
        let full=try engine.replay("FUNDING",snapshot:"fixed",start:days[2],end:days.last!,observe:{ seen.append($0) }) { r,_ in if prefix==nil { prefix=r } }
        XCTAssertEqual(full.trades.count,2)
        XCTAssertEqual(full.trades.map(\.quantity),[100,100]); XCTAssertEqual(full.trades.map(\.fees),[12.07,11.80])
        XCTAssertEqual(seen.first!.cash,22245.83); XCTAssertEqual(seen.first!.equity,49976.13,accuracy:1e-8)
        XCTAssertTrue(seen.allSatisfy { $0.cash>=0 && $0.holdings.values.allSatisfy { $0.pending==0 } })
        let restored=try engine.replay("FUNDING",snapshot:"fixed",start:days[2],end:days.last!,resume:prefix)
        let enc=JSONEncoder(); enc.outputFormatting=[.sortedKeys]
        XCTAssertEqual(try enc.encode(full),try enc.encode(restored))
        XCTAssertEqual(full.ledgerVersion,3)
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:enc.encode(try XCTUnwrap(prefix))) as? [String:Any])
        json["ledgerVersion"]=2
        let old=try JSONDecoder().decode(ReplayReport.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertThrowsError(try engine.replay("FUNDING",snapshot:"fixed",start:days[2],end:days.last!,resume:old))
        XCTAssertNotEqual(ReplayReport.fingerprint(market:"m",workspace:"w"),Integrity.sha(Data("etf-ledger-2|m|w".utf8)))
    }

    func testScarceCashLeavesWholeLotIntents() throws {
        let cal=try Sessions(),i=try cal.index("2024-12-30"),days=Array(cal.days[i...i+4])
        var m=try reviewed(days)
        for s in ["511010.SH","511260.SH"] {
            for d in days { m.securities[s]!.bars[d] = .init(open:1,close:1,high:1,low:1,volume:100000); m.securities[s]!.signal_close[d]=1 }
        }
        var seen=[StudyLedgerDay]()
        let r=try StrategyEngine(market:m,sessions:cal,workspace:workspace(capital:2000,price:1)).replay(
            "FUNDING",snapshot:"scarce",start:days[2],end:days.last!,observe:{ seen.append($0) })
        XCTAssertEqual(r.trades.map(\.quantity),[900,900])
        XCTAssertEqual(seen.last!.cash,189.10)
        for s in ["511010.SH","511260.SH"] { XCTAssertEqual(seen.last!.holdings[s]?.pending,100) }
    }
}
