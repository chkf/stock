import Foundation
import ResearchCore

enum FreshCheck {
    static let date = "2026-11-17"

    static func download(_ root: URL) async throws {
        let vault = PrivateLibrary(root: root)
        guard try await vault.active() == nil, try await vault.personalAccount() == nil,
              try await vault.phoneMarket() == nil else { throw ResearchError("冷启动测试需要一个新目录") }
        let account = Account(date: date, cash: 10, positions: [
            Position(symbol: try AccountInput.symbol("159919"), quantity: 10_000, available: 8_300)
        ], confirmed: true)
        try await vault.savePersonal(account)
        let snapshot = try await vault.refreshPublicMarket(asOf: date) { p in
            print("\(p.completed)/\(p.total) \(p.phase)")
        }
        guard snapshot.market.as_of == date else { throw ResearchError("行情日期与冻结对账日期不同") }
    }

    // Run in a new process. This command only opens the new native library and never calls the network.
    static func offline(root: URL, output: URL) async throws {
        let vault = PrivateLibrary(root: root)
        guard try await vault.active() == nil, let phone = try await vault.phoneMarket(), let account = try await vault.personalAccount(),
              account.as_of == date, account.cash == 10, account.confirmed, account.positions.first?.available == 8_300 else {
            throw ResearchError("未从手机新建资料库中读回测试账户与行情")
        }
        let market = phone.market
        for key in market.sources.keys { _ = try await vault.onlineEvidence(key, snapshot: phone) }
        let advice = try StrategyEngine(market: market, sessions: Sessions()).advice("MOM20", requested: date, account: account)
        guard let plan = advice.plan, let sell = plan.orders.first(where: { $0.side == "SELL" }),
              sell.quantity == 8_300, sell.deferred_quantity == 1_700 else { throw ResearchError("测试账户可卖份额未被正确应用") }
        let accountID = try AccountInput.identity(account)
        let report = SavedAdvice(snapshot: phone.hash, requested: date, capital: account.cash, result: advice, actualAccount: true, accountID: accountID)
        try await vault.saveReport(report)
        guard try await PrivateLibrary(root: root).reports().contains(where: { $0.id == report.id && $0.accountID == accountID }),
              try await vault.personalRecord(id: accountID).positions.first?.available == 8_300 else {
            throw ResearchError("本机复算报告未能重开")
        }
        let results = try Parity.run(phone: phone)
        let incremental = try await checkUpdate(vault: vault, phone: phone)
        struct Proof: Encodable {
            let platform, date, snapshot, warmup: String
            let noImport, manualTestAccountReloaded, offlineReportReloaded, badUpdatePreservedPrior, damagedEvidenceRejected: Bool
            let securities, evidenceFilesChecked, sellableShares, deferredShares: Int
            let incrementalParityCases: Int
            let cases: [ParityResult]
        }
        let proof = Proof(platform: "桌面 Swift，共用本机计算及存储代码", date: date, snapshot: phone.hash, warmup: phone.usableFrom,
                          noImport: true, manualTestAccountReloaded: true, offlineReportReloaded: true, badUpdatePreservedPrior: true,
                          damagedEvidenceRejected: true, securities: market.securities.count, evidenceFilesChecked: market.sources.count,
                          sellableShares: sell.quantity, deferredShares: sell.deferred_quantity, incrementalParityCases: incremental, cases: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(proof).write(to: output, options: .atomic)
        let failed = results.filter { !$0.differences.isEmpty }
        for r in failed { print(r.name, r.differences.prefix(6)) }
        guard failed.isEmpty else { throw ResearchError("\(failed.count) 项本机新建库对账存在差异") }
        print("空库联网、账户重填、重开离线计算与 \(results.count) 项 Python 对账通过")
    }

    private static func checkUpdate(vault: PrivateLibrary, phone: PhoneSnapshot) async throws -> Int {
        // Replay the previously downloaded public responses. No original project or live account is used.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("fresh-update-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temp) }
        let replica = PrivateLibrary(root: temp)
        let files = phone.market.sources.keys.sorted()
        func captured(_ url: URL) async throws -> Data {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let filename: String
            if let param = components?.queryItems?.first(where: { $0.name == "param" })?.value,
               let ticker = param.components(separatedBy: ",").first, ticker.count == 8 {
                filename = String(ticker.suffix(6)) + "." + String(ticker.prefix(2)).uppercased() + ".quotes.json"
            } else {
                let code = String(url.deletingPathExtension().lastPathComponent.suffix(6))
                guard let key = files.last(where: { $0.contains("/\(code).") && $0.contains(".actions-") }) else {
                    throw ResearchError("缺少此前下载的行动原件")
                }
                return try await vault.onlineEvidence(key, snapshot: phone)
            }
            guard let key = files.first(where: { $0.hasSuffix("/" + filename) }) else { throw ResearchError("缺少此前下载的报价原件") }
            return try await vault.onlineEvidence(key, snapshot: phone)
        }
        let earlier = try await replica.rebuildPublicMarket(through: "2026-11-16", fetch: captured, progress: { _ in })
        var refused = false
        do {
            _ = try await replica.rebuildPublicMarket(through: date, fetch: { url in
                if url.host == "proxy.finance.qq.com" { return Data("{}".utf8) }
                return try await captured(url)
            }, progress: { _ in })
        } catch { refused = true }
        guard refused, try await replica.phoneMarket()?.hash == earlier.hash else { throw ResearchError("更新失败后原行情未保留") }
        let updated = try await replica.rebuildPublicMarket(through: date, fetch: captured, progress: { _ in })
        let passing = try Parity.run(phone: updated)
        guard passing.allSatisfy({ $0.differences.isEmpty }) else { throw ResearchError("逐日增量更新与 Python 原版不一致") }
        guard let one = updated.market.sources.keys.sorted().first else { throw ResearchError("缺少校验原件") }
        try Data("损坏的测试副本".utf8).write(to: temp.appendingPathComponent("public-market/\(one)"), options: .atomic)
        var rejected = false
        do { _ = try await replica.phoneMarket() } catch { rejected = true }
        guard rejected else { throw ResearchError("打开资料库时未发现损坏原件") }
        return passing.count
    }
}
