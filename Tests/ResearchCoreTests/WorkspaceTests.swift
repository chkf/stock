import XCTest
@testable import ResearchCore

final class WorkspaceTests: XCTestCase {
    func testFileEditRecomputeRollbackAndLegacyMigration() throws {
        let fm=FileManager.default, dir=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at:dir) }
        let previous=dir.appendingPathComponent("support/StockResearch"), docs=dir.appendingPathComponent("Documents")
        try fm.createDirectory(at:previous,withIntermediateDirectories:true)
        let receipt=Data("既有账户记录".utf8)
        try receipt.write(to:previous.appendingPathComponent("old.json"))
        let vault=try PrivateLibrary.openWorkspace(documents:docs,previous:previous)
        XCTAssertEqual(try Data(contentsOf:vault.root.appendingPathComponent("old.json")),receipt)
        let store=WorkspaceStore(root:vault.root.deletingLastPathComponent())
        try store.installIfNeeded()
        let a=try store.activate()
        XCTAssertEqual(a.design.strategies.count,5)
        let m=MarketSnapshot(schema:"test",as_of:"2026-11-17",securities:[:],sources:[:],extras:[:],limitations:[])
        let cal=try Sessions()
        func signal(_ version:WorkspaceVersion) throws -> Decision {
            try StrategyEngine(market:m,sessions:cal,workspace:version).decision("BANK_ELSE_GB",on:m.as_of)
        }
        XCTAssertEqual(try signal(a).route,"CASH")
        let strategy=store.working.appendingPathComponent("策略/混合.js")
        var script=try String(contentsOf:strategy,encoding:.utf8)
        script=script.replacingOccurrences(of:"return d;",with:"d.headline='手机修改已生效'; return d;")
        try Data(script.utf8).write(to:strategy,options:.atomic)
        let page=store.working.appendingPathComponent("页面/市场.json")
        let newPage=#"{"title":"我的首页","icon":"star","blocks":[{"type":"text","text":"按我的顺序显示"},{"type":"decision"}]}"#
        try Data(newPage.utf8).write(to:page,options:.atomic)
        let b=try store.activate { _=try signal($0) }
        XCTAssertNotEqual(a.hash,b.hash)
        XCTAssertEqual(b.pages["market"]?.title,"我的首页")
        XCTAssertEqual(try signal(b).headline,"手机修改已生效")
        XCTAssertEqual(try store.active()?.hash,b.hash)
        let output=try b.action("coverage",input:Data(#"{"asOf":"2026-11-17","market":{"512800.SH":{"name":"银行ETF","bars":253}}}"#.utf8))
        XCTAssertTrue(String(decoding:output,as:UTF8.self).contains("253 个交易日"))
        try Data("function run(故意破坏".utf8).write(to:strategy,options:.atomic)
        XCTAssertThrowsError(try store.activate())
        XCTAssertEqual(try store.active()?.hash,b.hash)
        XCTAssertEqual(try store.rollback().hash,a.hash)
        XCTAssertNil(try signal(XCTUnwrap(store.active())).headline)
        XCTAssertEqual(try Data(contentsOf:vault.root.appendingPathComponent("old.json")),receipt)
    }
    func testStrengthVotesAndThreshold() throws {
        let sample=["count":18.0,"threshold":0.6,"up60":3.0/18,"up200":2.0/18,"down60":12.0/18,"down200":11.0/18]
        let v=try XCTUnwrap(StrengthDistance(sample))
        XCTAssertEqual(v.required,11); XCTAssertEqual(v.shortGap,8); XCTAssertEqual(v.longGap,9)
        XCTAssertNil(StrengthDistance(["count":0,"threshold":0.6]))
        var at=sample; at["count"]=5; at["up60"]=0.6; at["up200"]=0.8
        let atThreshold=try XCTUnwrap(StrengthDistance(at))
        XCTAssertEqual(atThreshold.required,3); XCTAssertEqual(atThreshold.shortGap,0); XCTAssertEqual(atThreshold.longGap,0)
    }
    func testLocalFunctionTimeout() {
        XCTAssertThrowsError(try WorkspaceVersion.execute("function run(){for(;;){}}",file:"test.js",input:Data("{}".utf8)))
    }
}
