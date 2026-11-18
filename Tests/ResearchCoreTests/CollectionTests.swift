import XCTest
@testable import ResearchCore

final class CollectionTests:XCTestCase {
    let code="512800.SH"
    let bar=Bar(open:1,close:1,high:1,low:1,volume:100)
    func testPagesCross640AndWeekend() async throws {
        let cal=try Sessions(),last=try cal.index("2024-10-08")
        let days=Array(cal.days[(last-645)...last])
        var cursors=[String]()
        let rows=try await HistoryPages.collect(symbol:code,from:days[0],through:days.last!,calendar:cal,previous:[:]) { cursor,index in
            cursors.append(cursor)
            let page=days.filter { $0<=cursor }.suffix(640)
            XCTAssertEqual(page.count,index==0 ? 640:6)
            return Dictionary(uniqueKeysWithValues:page.map { ($0,self.bar) })
        }
        XCTAssertEqual(rows.count,646); XCTAssertEqual(cursors.count,2)
        let previous=ExchangeDay.calendar.date(byAdding:.day,value:-1,to:try XCTUnwrap(ExchangeDay.date(days[6])))
        XCTAssertEqual(cursors[1],ExchangeDay.string(try XCTUnwrap(previous)))
        func refuse(_ body:[String:Bar],_ old:[String:Bar],_ expected:String) async {
            do {
                _=try await HistoryPages.collect(symbol:code,from:"2024-08-09",through:"2024-08-12",calendar:cal,previous:old) { _,_ in body }
                XCTFail("应拒绝 "+expected)
            } catch { XCTAssertTrue(error.localizedDescription.contains(expected),error.localizedDescription) }
        }
        await refuse(["2024-08-12":bar],[:],"分页未前进")
        await refuse(["2024-08-10":bar],[:],"非交易日")
        await refuse([:],["2024-08-09":bar],"不完整")
        await refuse(["2024-08-09":bar],["2024-08-09":.init(open:2,close:2,high:2,low:2,volume:100)],"重叠")
    }
    func testResponseIdentityStatusAndDuplicateRows() throws {
        let u=PublicFeed.quoteURL(code,"2024-08-09","2024-08-12"),data=Data([1])
        XCTAssertEqual(try PublicFeed.checkedHTTP(status:200,responseURL:u,requested:u,bytes:data),data)
        for (status,url,bytes) in [(404,u,data),(200,URL(string:"https://example.org/quote")!,data),(200,u,Data())] {
            XCTAssertThrowsError(try PublicFeed.checkedHTTP(status:status,responseURL:url,requested:u,bytes:bytes))
        }
        func decode(_ dates:[String],symbol:String="sh512800",field:String="day") throws -> [String:Bar] {
            let rows=dates.map { [$0,"1","1","1","0.99","42"] }
            let bytes=try JSONSerialization.data(withJSONObject:["data":[symbol:[field:rows]]])
            return try PublicFeed.quotes(bytes,symbol:code,from:"2024-08-09",through:"2024-08-12")
        }
        XCTAssertThrowsError(try decode(["2024-08-09","2024-08-09"]))
        XCTAssertThrowsError(try decode(["2024-08-13"]))
        XCTAssertThrowsError(try decode(["2024-08-09"],symbol:"sh512010"))
        XCTAssertThrowsError(try decode(["2024-08-09"],field:"qfqday"))
        XCTAssertThrowsError(try decode(["2024-02-30"]))
        XCTAssertTrue(try decode(["2024-07-01"]).isEmpty)
    }
    func testApprovedDividendDatesAndNewProviderClue() throws {
        let rules=try PublicRules.load(),symbol="511260.SH",member=try XCTUnwrap(rules.members[symbol])
        let dates=["2025-09-23","2025-12-26","2026-06-25","2026-09-18"]
        for date in dates {
            let official=try XCTUnwrap(member.provider.first { $0.date==date })
            func revised(_ cash:Double) -> ProviderEvent {
                .init(date:date,record_date:"2000-01-01",cash_per_share:cash,share_factor:1,supported:official.supported,date_needs_reconciliation:official.date_needs_reconciliation,payment_date:"2000-02-01")
            }
            XCTAssertNoThrow(try PublicFeed.validateHistory([revised(official.cash_per_share)],old:[official],through:date,symbol:symbol))
            XCTAssertThrowsError(try PublicFeed.validateHistory([revised(official.cash_per_share+0.01)],old:[official],through:date,symbol:symbol))
            XCTAssertThrowsError(try PublicFeed.validateHistory([revised(official.cash_per_share)],old:[official],through:date,symbol:code))
        }
        let calendar=try Sessions(),day=try calendar.next(rules.reviewedThrough)
        let e=ProviderEvent(date:day,record_date:rules.reviewedThrough,cash_per_share:0.1,share_factor:1,supported:true,date_needs_reconciliation:false,payment_date:day)
        let securities=rules.members.mapValues { MarketSecurity(name:$0.name,group:$0.group,bars:[day:bar],signal_close:[day:1],events:[],provider_events:[e]) }
        let market=MarketSnapshot(schema:"test",as_of:day,securities:securities,sources:[:],extras:[:],limitations:[])
        let c=try HistoryCoverage(market:market,sessions:calendar,strategies:WorkspaceVersion.bundled().design.strategies)
        XCTAssertTrue(c.windows.isEmpty); XCTAssertTrue(c.issues.contains { $0.date==day && $0.field=="供应商行动" })
    }
    func testImmutableRefusedReceiptsAndPausedCandidates() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let url=PublicFeed.actionsURL(code),rules=Integrity.sha(Data("规则".utf8))
        func open() throws -> HistoryCandidate { try .init(root:dir,parent:nil,from:"2024-08-09",through:"2024-08-12",rules:rules) }
        var c=try open(),count=0
        let initial=c.journal.id
        _=try await c.capture(url,name:"page",fetch:{ _ in count+=1; return Data([123]) },validate:{ _ in })
        _=try c.record("paused")
        c=try open()
        _=try await c.capture(url,name:"page",fetch:{ _ in XCTFail("重复下载"); return Data() },validate:{ _ in })
        XCTAssertEqual(count,1); XCTAssertEqual(initial,c.journal.id)
        let (path,hash)=try c.record("refused",reason:"缺份额到账依据")
        c=try open()
        XCTAssertNotEqual(initial,c.journal.id)
        XCTAssertEqual(try Integrity.sha(Data(contentsOf:dir.appendingPathComponent(path))),hash)
        try HistoryWriters.shared.claim(dir)
        XCTAssertThrowsError(try HistoryWriters.shared.claim(dir))
        HistoryWriters.shared.release(dir)
    }
    func testSelectedSourceSurvivesEmptyLibraryAndMissingAccountTab() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=WorkspaceStore(root:root)
        try store.installIfNeeded()
        let manifest=store.working.appendingPathComponent("workspace.json")
        var config=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any])
        config["tabs"]=["market","replay","library"]
        let data=try JSONSerialization.data(withJSONObject:config)
        try data.write(to:manifest)
        let page=store.working.appendingPathComponent("页面/回测.json")
        let old=try String(contentsOf:page,encoding:.utf8).replacingOccurrences(of:"dateField",with:"field")
        try Data(old.utf8).write(to:page)
        let a=try store.activate()
        try store.installIfNeeded()
        XCTAssertEqual(try store.active()?.hash,a.hash)
        XCTAssertEqual(try Data(contentsOf:manifest),data)
        XCTAssertEqual(try String(contentsOf:page,encoding:.utf8),old)
        XCTAssertEqual(a.design.tabs,["market","replay","library"])
        let invalid=old.replacingOccurrences(of:"\"field\"",with:"\"dateField\"").replacingOccurrences(of:"replayEnd",with:"unknownKey")
        try Data(invalid.utf8).write(to:page)
        XCTAssertThrowsError(try store.activate())
        let vault=PrivateLibrary(root:root.appendingPathComponent("数据"))
        try await vault.selectMarket(.archive)
        let opened=PrivateLibrary(root:vault.root),origin=try await opened.selectedMarket(),archive=try await opened.active()
        XCTAssertEqual(origin,.archive); XCTAssertNil(archive)
        try await opened.selectMarket(.phone)
        let chosen=try await vault.selectedMarket()
        XCTAssertEqual(chosen,.phone)
    }
}
