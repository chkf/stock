import XCTest
@testable import ResearchCore

final class CoreTests: XCTestCase {
    func testShanghaiCloseAndHolidays() throws {
        let cal = try Sessions()
        let utc = ISO8601DateFormatter()
        XCTAssertEqual(try cal.completed(now: utc.date(from: "2026-11-13T07:59:59Z")!), "2026-11-12")
        XCTAssertEqual(try cal.completed(now: utc.date(from: "2026-11-13T08:00:00Z")!), "2026-11-13")
        XCTAssertEqual(try cal.completed(now: utc.date(from: "2026-11-15T12:00:00Z")!), "2026-11-13")
        XCTAssertEqual(try cal.next("2024-02-08"), "2024-02-19")
        XCTAssertThrowsError(try cal.next("2026-12-31"))
        XCTAssertTrue(try cal.monthEnd("2026-10-30"))
        XCTAssertThrowsError(try cal.completed(asOf: "2026-11-19", now: utc.date(from: "2026-11-18T10:00:00Z")!))
    }

    func testIntegrityAndRounding() throws {
        XCTAssertEqual(Integrity.sha(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertThrowsError(try Integrity.gunzip(Data([0x1f, 0x8b])))
        XCTAssertEqual(Planning.money(1.005), 1.01)
        XCTAssertEqual(Planning.money(-1.005), -1.01)
        let f = try Planning.costs(1_000_100, 0.01, sell: false, symbol: "512800.SH", date: "2026-11-18", fees: Fees())
        XCTAssertEqual(f.order_quantities, [1_000_000, 100])
        XCTAssertEqual(f.commission, 10)
        XCTAssertEqual(f.stamp_tax, 0)
    }

    func testFreshPersonalAccountVersions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = PrivateLibrary(root: root)
        let before = try await vault.personalAccount()
        XCTAssertNil(before)
        let now = ISO8601DateFormatter().date(from: "2026-11-17T09:00:00Z")!
        let p = Position(symbol: try AccountInput.symbol("sz159919"), quantity: 104, available: 0, close: 3.5, entry: "2026-11-16")
        let entered = Account(date: "2026-11-17", cash: 0, positions: [p], confirmed: true)
        try await vault.savePersonal(entered, now: now)
        let restored = try await PrivateLibrary(root: root).personalAccount()
        XCTAssertEqual(restored?.positions.first?.symbol, "159919.SZ")
        XCTAssertEqual(restored?.positions.first?.quantity, 104)
        XCTAssertEqual(restored?.positions.first?.close, 3.5)
        XCTAssertEqual(restored?.cash, 0)
        let priorID = try AccountInput.identity(entered)
        let noArchive = try await vault.active()
        XCTAssertNil(noArchive)
        for invalid in [
            Account(date: "2026-11-17", cash: 5000),
            Account(date: "2026-11-18", cash: 0, confirmed: true),
            Account(date: "2026-11-17", cash: -1, confirmed: true),
            Account(date: "2026-11-17", cash: 0, positions: [p, p], confirmed: true),
            Account(date: "2026-11-17", cash: 0, positions: [Position(symbol: "159919.SZ", quantity: 10, available: 11)], confirmed: true)
        ] {
            do { try await vault.savePersonal(invalid, now: now); XCTFail("无效的真实账户被保存") }
            catch { }
        }
        let current = try await vault.personalAccount()
        XCTAssertEqual(try current.map(AccountInput.identity), priorID)
        try await vault.savePersonal(Account(date: "2026-11-17", cash: 12, positions: [
            Position(symbol: "159919.SZ", quantity: 0, available: 0)
        ], confirmed: true), now: now)
        let edited = try await vault.personalAccount()
        XCTAssertEqual(edited?.positions.count, 0)
        let history = try await vault.personalHistory()
        XCTAssertEqual(history.count, 2)
        let old = try await vault.personalRecord(id: priorID)
        XCTAssertEqual(old.cash, 0)
        XCTAssertThrowsError(try AccountInput.symbol("159919.SH"))
        XCTAssertThrowsError(try AccountInput.symbol("SHSZ159919"))
        XCTAssertThrowsError(try AccountInput.symbol("123"))
        let saved = root.appendingPathComponent("personal/accounts/\(try AccountInput.identity(edited!)).json")
        try Data("{}".utf8).write(to: saved, options: .atomic)
        do { _ = try await vault.personalAccount(); XCTFail("损坏的当前账户未被拒绝") } catch { }
        let intact = try await vault.personalRecord(id: priorID)
        XCTAssertEqual(intact.positions.count, 1)
    }
}
