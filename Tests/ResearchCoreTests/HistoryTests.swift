import XCTest
@testable import ResearchCore

final class HistoryTests:XCTestCase {
    let proof="test-price-and-action-evidence"
    func reviewed(_ days:[String],active:Set<String> = MarketSnapshot.pool) throws -> MarketSnapshot {
        let rules=try PublicRules.load(), cal=try Sessions()
        var securities=[String:MarketSecurity](), reviews=[String:SecurityReview]()
        for s in MarketSnapshot.pool {
            let available=active.contains(s)
            let rows=available ? days : []
            let bars=Dictionary(uniqueKeysWithValues:rows.map { ($0,Bar(open:10,close:10,high:10,low:10,volume:5000)) })
            securities[s] = .init(name:s,group:rules.members[s]!.group,bars:bars,signal_close:bars.mapValues(\.close),events:[],provider_events:[])
            let listing=available ? days.first! : try cal.next(days.last!)
            reviews[s] = .init(listing:.init(date:listing,evidence:proof),spans:[.init(from:days.first!,through:days.last!,evidence:proof)],gaps:[:],events:[],issues:[])
        }
        return .init(schema:"advice-market-v1",as_of:days.last!,securities:securities,sources:[proof:Integrity.sha(Data("synthetic".utf8))],extras:[:],limitations:["合成账簿测试"],
                     history:.init(schema:HistoryReview.version,from:days.first!,through:days.last!,symbols:reviews))
    }
    func custom(symbol:String,record:String,exitSignal:String?,history:Int=2) throws -> WorkspaceVersion {
        let fm=FileManager.default,dir=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at:dir) }
        let store=WorkspaceStore(root:dir); try store.installIfNeeded()
        let config=store.working.appendingPathComponent("workspace.json")
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:config)) as? [String:Any])
        json["strategies"]=[["id":"EVENT","file":"策略/案例.js","title":"合成账户","short":"案例","history":history,"rebalance":"daily"]]
        try JSONSerialization.data(withJSONObject:json).write(to:config)
        let code="""
        function run(input) {
          const w = input.date >= '\(exitSignal ?? "9999")' ? 0 : (input.date < '\(record)' ? 0.25 : 0.75);
          return {strategy:input.strategy,date:input.date,route:"CASE",marketState:"TRANSITION",selected:w?["\(symbol)"]:[],
                  weights:w?{"\(symbol)":w}:{},scores:{},breadth:{},protection:[]};
        }
        """
        try Data(code.utf8).write(to:store.working.appendingPathComponent("策略/案例.js"))
        return try store.activate()
    }
    func testRangeWarmupListingAndUnknown() throws {
        let cal=try Sessions(), i=try cal.index("2015-01-05"), days=Array(cal.days[i...i+259])
        let active:Set<String>=["512800.SH","510880.SH","511010.SH"]
        var m=try reviewed(days,active:active)
        let definitions=try WorkspaceVersion.bundled().design.strategies
        func c(_ id:String)throws -> HistoryCoverage { try HistoryCoverage(market:m,sessions:cal,strategies:definitions.filter{$0.id==id}) }
        let gb=try c("GB"),mom=try c("MOM20")
        XCTAssertEqual(gb.windows.first?.start,days[252]); XCTAssertEqual(mom.windows.first?.start,days[253])
        XCTAssertEqual(mom.sampleCount(on:days[253]),3)
        XCTAssertNotNil(mom.problem(start:"2015-10-01",end:days.last!))
        XCTAssertNotNil(mom.problem(start:days.last!,end:days[253]))
        XCTAssertNotNil(mom.problem(start:days[253],end:days.last!,completed:days[255]))
        m.history!.symbols["159611.SZ"]!.listing=nil
        XCTAssertTrue(try c("GB").windows.isEmpty)
        m=try reviewed(days,active:[])
        XCTAssertTrue(try c("GB").windows.isEmpty)
        m=try reviewed(days,active:active)
        m.securities["510880.SH"]!.bars[days[255]]=nil
        m.securities["510880.SH"]!.statuses=[days[255]:.init(state:"halted",upper_limit:nil,lower_limit:nil,source:"UNVERIFIED",assumption:true)]
        let broken=try c("GB")
        XCTAssertTrue(broken.problem(start:days[253],end:days[256])?.contains("510880.SH")==true)
        XCTAssertTrue(broken.problem(start:days[253],end:days[256])?.contains(days[255])==true)
        m.history!.symbols["510880.SH"]!.gaps[days[255]] = .init(state:.noTrades,evidence:proof)
        XCTAssertNil(try c("GB").problem(start:days[253],end:days[256]))
    }
    func testNoticeLedgerAndResume() throws {
        let cal=try Sessions()
        for n in SplitNotice.published {
            let i=try cal.index(n.ex),days=Array(cal.days[i-30...i+3])
            var m=try reviewed(days)
            let e=MarketEvent(date:n.ex,cash_per_share:0,share_factor:Double(n.factor),record_date:n.record,source:proof,payment_date:nil,
                            available_date:n.available,rounding:n.rounding,exact_factor:n.factor,share_timing:n.atClose ? "record_close":"before_open")
            let s=n.symbol, ratio=Double(n.factor)!, post=(10/ratio*1000).rounded()/1000
            m.securities[s]!.events=[e]; m.history!.symbols[s]!.events=[e]
            if n.halted { m.history!.symbols[s]!.gaps[n.ex] = .init(state:.halted,evidence:proof); m.securities[s]!.bars[n.ex]=nil }
            for d in days where d>n.ex || (d==n.ex && !n.halted) {
                m.securities[s]!.bars[d] = .init(open:post,close:post,high:post,low:post,volume:5000)
                m.securities[s]!.signal_close[d]=post*ratio
            }
            let w=try custom(symbol:s,record:cal.days[i-3],exitSignal:n.ex)
            let engine=StrategyEngine(market:m,sessions:cal,workspace:w)
            var seen=[String:StudyLedgerDay](), partial:ReplayReport?
            let r=try engine.replay("EVENT",snapshot:"current",start:days[3],end:days.last!,observe:{ seen[$0.date]=$0 }) { if partial==nil { partial=$0 }; _=$1 }
            let pre=try XCTUnwrap(seen[cal.days[i-1]]), ex=try XCTUnwrap(seen[n.ex])
            let before=try XCTUnwrap(pre.holdings[s]), after=try XCTUnwrap(ex.holdings[s])
            let terms=try SplitTerms(e,symbol:s,calendar:cal,halted:n.halted)
            XCTAssertGreaterThanOrEqual(before.lots.count,2,n.symbol)
            XCTAssertEqual(after.shares,try terms.converted(before.shares),s)
            XCTAssertEqual(after.lots.reduce(0,+),after.shares); XCTAssertEqual(after.basis,before.basis)
            XCTAssertEqual(ex.cash,pre.cash)
            XCTAssertEqual(after.available,n.available==n.ex ? after.shares : before.shares)
            XCTAssertEqual(after.pending,-after.shares)
            XCTAssertEqual(ex.equity-pre.equity,Double(after.shares)*after.mark-Double(before.shares)*before.mark,accuracy:1e-7)
            let sale=try XCTUnwrap(r.trades.first { $0.symbol==s && $0.side=="SELL" })
            XCTAssertEqual(sale.quantity,after.shares); XCTAssertEqual(sale.date,cal.days[i+1]); XCTAssertGreaterThan(sale.fees,0)
            let enc=JSONEncoder(); enc.outputFormatting=[.sortedKeys]
            let resumed=try engine.replay("EVENT",snapshot:"current",start:days[3],end:days.last!,resume:partial)
            XCTAssertEqual(try enc.encode(r),try enc.encode(resumed))
            XCTAssertThrowsError(try engine.replay("EVENT",snapshot:"new-generation",start:days[3],end:days.last!,resume:partial))
            let liquidation=try custom(symbol:s,record:cal.days[i-3],exitSignal:cal.days[i-1])
            let queued=try StrategyEngine(market:m,sessions:cal,workspace:liquidation).replay("EVENT",snapshot:"pending",start:days[3],end:days.last!)
            let saleAtFirstOpen=try XCTUnwrap(queued.trades.first { $0.side=="SELL" })
            XCTAssertEqual(saleAtFirstOpen.date,n.available,n.symbol)
            XCTAssertEqual(saleAtFirstOpen.quantity,after.shares,n.symbol)
        }
    }
    func testIndependentNoticeOriginalsAndAccountRounding() throws {
        struct Case:Decodable { let symbol,record,ex,available,factor:String; let rounding:String?; let halted,atClose:Bool; let originals:[String]; let shares,allocation:[Int] }
        struct Source:Decodable { let sha256:String }
        let dir=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/history/notices")
        let cases=try JSONDecoder().decode([Case].self,from:Data(contentsOf:dir.appendingPathComponent("cases.json")))
        let manifest=try JSONDecoder().decode([String:Source].self,from:Data(contentsOf:dir.appendingPathComponent("manifest.json")))
        XCTAssertEqual(cases.count,3); XCTAssertEqual(Set(cases.flatMap(\.originals)),Set(manifest.keys))
        for c in cases {
            for file in c.originals { XCTAssertEqual(try Integrity.sha(Data(contentsOf:dir.appendingPathComponent(file))),manifest[file]?.sha256) }
            let e=MarketEvent(date:c.ex,cash_per_share:0,share_factor:Double(c.factor),record_date:c.record,source:c.originals.last,payment_date:nil)
            let t=try SplitTerms(e,symbol:c.symbol,calendar:Sessions(),halted:c.halted)
            XCTAssertEqual(t.atClose,c.atClose); XCTAssertEqual(t.available,c.available); XCTAssertEqual(t.rounding,c.rounding)
            XCTAssertEqual(try t.allocation(c.shares),c.allocation)
            XCTAssertEqual(try t.converted(c.shares.reduce(0,+)),c.allocation.reduce(0,+))
        }
    }
    func testCashAndNoTradeAcrossAnAction() throws {
        let cal=try Sessions(),index=try cal.index("2017-03-16"),days=Array(cal.days[index-7...index+3]),s="512800.SH"
        let ex=cal.days[index],record=cal.days[index-1],pay=cal.days[index+2]
        var m=try reviewed(days)
        let event=MarketEvent(date:ex,cash_per_share:0.2,share_factor:1,record_date:record,source:proof,payment_date:pay)
        m.securities[s]!.events=[event];m.history!.symbols[s]!.events=[event]
        for d in [ex,cal.days[index+1]] { m.securities[s]!.bars[d]=nil; m.history!.symbols[s]!.gaps[d] = .init(state:.halted,evidence:proof) }
        for d in days where d>=pay { m.securities[s]!.bars[d] = .init(open:9.8,close:9.8,high:9.8,low:9.8,volume:5000) }
        let signals=try HistoryAdjustment.signals(symbol:s,days:days,bars:m.securities[s]!.bars,anchor:days.last!,anchorSignal:10,previousClose:nil,events:[event],listed:nil,nonTrading:{ [ex,cal.days[index+1]].contains($0) },band:{ _ in 0.1 })
        XCTAssertTrue(signals.values.allSatisfy { abs($0-10)<1e-12 }); m.securities[s]!.signal_close=signals
        let w=try custom(symbol:s,record:"9999",exitSignal:nil),engine=StrategyEngine(market:m,sessions:cal,workspace:w)
        var rows=[String:StudyLedgerDay]()
        _=try engine.replay("EVENT",snapshot:"dividend",start:days[2],end:days.last!,observe:{ rows[$0.date]=$0 })
        let prior=try XCTUnwrap(rows[record]),exDay=try XCTUnwrap(rows[ex]),paid=try XCTUnwrap(rows[pay])
        let cash=Double(prior.holdings[s]!.shares)*0.2
        XCTAssertEqual(prior.cash,exDay.cash); XCTAssertEqual(exDay.holdings[s]!.receivable,cash,accuracy:0.00001)
        XCTAssertEqual(prior.equity,exDay.equity,accuracy:0.00001); XCTAssertEqual(paid.holdings[s]!.receivable,0)
        XCTAssertEqual(paid.cash,prior.cash+cash,accuracy:0.00001)
    }
    func testUnsupportedTermsAndShanghaiDate() throws {
        let cal=try Sessions()
        func terms(_ e:MarketEvent)throws -> SplitTerms { try SplitTerms(e,symbol:"512800.SH",calendar:cal,halted:true) }
        var e=MarketEvent(date:"2024-08-12",cash_per_share:0,share_factor:0.5,record_date:"2024-08-09",source:proof,payment_date:nil,available_date:"2024-08-12")
        XCTAssertThrowsError(try terms(e)); e.rounding="ceil"; e.available_date=nil; XCTAssertThrowsError(try terms(e))
        e.available_date="2024-08-12"; e.settlement="cash_in_lieu"; XCTAssertThrowsError(try terms(e))
        XCTAssertNil(ExchangeDay.date("2024-02-30")); XCTAssertNil(ExchangeDay.date("2024-2-01"))
        XCTAssertEqual(ExchangeDay.string(try XCTUnwrap(ISO8601DateFormatter().date(from:"2024-08-11T17:00:00Z"))),"2024-08-12")
    }
}
