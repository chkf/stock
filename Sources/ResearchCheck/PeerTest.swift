import Foundation
import ResearchCore

// Desktop test adapter only. The iPhone uses its URLSession/Security delegate.
// The fixture supplies the public leaf certificate through a temporary file.
enum PeerTest {
    static func receive(certificate: URL, directory: URL) async throws {
        guard let line = readLine() else { throw ResearchError("缺少一次性配对码") }
        let code = try PairCode(line)
        let text = try String(contentsOf: certificate, encoding: .ascii)
        let body = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body, options: .ignoreUnknownCharacters),
              Integrity.sha(der).hasPrefix(code.pin.map { String(format: "%02x", $0) }.joined()) else {
            throw ResearchError("电脑证书与配对码不符")
        }
        let vault = PrivateLibrary(root: directory)
        let archive = try await PeerSession.receive(code: code, into: vault, request: { path, token, proof in
            let task = Process(), input = Pipe(), output = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            task.arguments = ["--silent", "--show-error", "--fail", "--noproxy", "*", "--proto", "=https",
                              "--max-time", "40", "--cacert", certificate.path, "--config", "-",
                              "https://\(code.host):\(code.port)/\(path)"]
            task.standardInput = input
            task.standardOutput = output
            try task.run()
            var options = ""
            if let token { options += "header = \"Authorization: Bearer \(token)\"\n" }
            if let proof { options += "data-binary = \"\(String(decoding: proof, as: UTF8.self))\"\n" }
            try input.fileHandleForWriting.write(contentsOf: Data(options.utf8))
            try input.fileHandleForWriting.close()
            let response = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { throw ResearchError("桌面测试的 HTTPS 请求失败") }
            return response
        }, progress: { _ in })
        print("已接收并启用 \(archive.manifest.fileCount) 个原件")
    }

    static func offline(directory: URL, output: URL) async throws {
        let vault = PrivateLibrary(root: directory)
        guard let archive = try await vault.active() else { throw ResearchError("缺少已校验的本机资料") }
        let market = try archive.loadMarket(), engine = try StrategyEngine(market: market, sessions: Sessions())
        let account = Account(date: market.as_of, cash: 50000)
        let advice = try engine.advice("MOM20", requested: market.as_of, account: account)
        let report = SavedAdvice(snapshot: archive.manifest.snapshot.hash, requested: market.as_of, capital: 50000, result: advice)
        try await vault.saveReport(report)
        let reopened = try await PrivateLibrary(root: directory).reports()
        guard reopened.contains(where: { $0.id == report.id }) else { throw ResearchError("生成的报告未能重开") }
        let results = try Parity.run(archive: archive)
        guard results.allSatisfy({ $0.differences.isEmpty }) else { throw ResearchError("离线对账不一致") }
        struct Evidence: Encodable {
            let environment, snapshot: String
            let report: SavedAdvice
            let reopenedReport: Bool
            let results: [ParityResult]
        }
        let evidence = Evidence(environment: "桌面 Swift；电脑传输进程已停止，独立离线进程读取私有测试库",
                                snapshot: archive.manifest.snapshot.hash, report: report, reopenedReport: true, results: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: output, options: .atomic)
        print("传输结束后重新启动，原生重算、私有报告回读及 \(results.count) 份对账通过")
    }
}
