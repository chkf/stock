import Foundation
import ResearchCore

// Exercises the same import/verification/activation code and the same offline core as the app.
@main struct ResearchCheck {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 2 && args[0] == "--fresh-download" {
            try await FreshCheck.download(URL(fileURLWithPath: args[1]))
            return
        }
        if args.count == 3 && args[0] == "--fresh-offline" {
            try await FreshCheck.offline(root: URL(fileURLWithPath: args[1]), output: URL(fileURLWithPath: args[2]))
            return
        }
        if args.count == 3 && args[0] == "--receive-test" {
            try await PeerTest.receive(certificate: URL(fileURLWithPath: args[1]), directory: URL(fileURLWithPath: args[2]))
            return
        }
        if args.count == 3 && args[0] == "--offline-test" {
            try await PeerTest.offline(directory: URL(fileURLWithPath: args[1]), output: URL(fileURLWithPath: args[2]))
            return
        }
        guard (1...2).contains(args.count) else { throw ResearchError("用法 research-check 电脑包目录 [结果.json]") }
        let source = URL(fileURLWithPath: args[0], isDirectory: true)
        let id = source.lastPathComponent
        let raw = try Data(contentsOf: source.appendingPathComponent("manifest.json"))
        let m = try Manifest.checked(raw, id: id)
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("research-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        let vault = PrivateLibrary(root: temp)
        let stream = try FileHandle(forReadingFrom: source.appendingPathComponent("payload.bin"))
        defer { try? stream.close() }
        func chunk(_ i: Int) throws -> Data {
            try stream.seek(toOffset: UInt64(i * m.chunkSize))
            return try stream.read(upToCount: m.chunkSize) ?? Data()
        }
        enum Stop: Error { case connection }
        var corruptBlockRejected = false
        if m.chunks.count > 1 {
            do {
                try await vault.receive(manifest: raw, id: id, fetch: { i in
                    if i == 1 { throw Stop.connection }
                    return try chunk(i)
                }, progress: { _ in })
                throw ResearchError("中断未生效")
            } catch Stop.connection {}
            guard try await vault.active() == nil else { throw ResearchError("部分导入被提前启用") }
            do {
                try await vault.receive(manifest: raw, id: id, fetch: { i in
                    var data = try chunk(i)
                    data[0] ^= 1
                    return data
                }, progress: { _ in })
            } catch { corruptBlockRejected = true }
            guard corruptBlockRejected, try await vault.active() == nil else { throw ResearchError("错误分块未被隔离") }
        }
        var reads = [Int]()
        let installed = try await vault.receive(manifest: raw, id: id, fetch: { i in
            reads.append(i)
            return try chunk(i)
        }, progress: { _ in })
        guard reads.first == (m.chunks.count > 1 ? 1 : 0) else { throw ResearchError("未从有效断点继续") }
        // Recreate a stop after the generation rename but before publishing the active pointer.
        // Only this disposable library is touched; the generation and its data remain in place.
        let pointerURL = temp.appendingPathComponent("active.json")
        let journal = temp.appendingPathComponent("incoming/\(id).activation.json")
        try Data(contentsOf: pointerURL).write(to: journal, options: .atomic)
        try fm.removeItem(at: pointerURL)
        let recovered = try await vault.receive(manifest: raw, id: id, fetch: { _ in throw Stop.connection }, progress: { _ in })
        guard recovered.directory == installed.directory else { throw ResearchError("提交中断的已校验资料未能原位恢复") }
        // A valid new manifest with one deliberately incorrect file hash fails after transfer.
        var broken = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        var files = broken["files"] as! [[String: Any]]
        files[0]["sha256"] = String(repeating: "0", count: 64)
        broken["files"] = files
        let bad = try JSONSerialization.data(withJSONObject: broken, options: [.sortedKeys])
        var rejected = false
        do {
            try await vault.receive(manifest: bad, id: Integrity.sha(bad), fetch: { try chunk($0) }, progress: { _ in })
        } catch { rejected = true }
        guard rejected, try await vault.active()?.id == id else { throw ResearchError("失败未保留原启用代") }
        try stream.close()
        let reopened = PrivateLibrary(root: temp)
        guard let archive = try await reopened.active(), archive.id == installed.id else { throw ResearchError("重开失败") }
        let results = try Parity.run(archive: archive)
        let chartFiles = archive.manifest.files.filter { $0.path.hasPrefix("external-charts/") }
        var charts = 0
        for f in chartFiles { charts += try ArchiveChart.load(from: archive.read(f.path)).count }
        let failures = results.filter { !$0.differences.isEmpty }
        for item in failures {
            print(item.name)
            for diff in item.differences.prefix(12) { print("  \(diff)") }
        }
        struct Evidence: Encodable {
            let packageID, snapshot: String
            let files, bytes, chunks, resumedAtChunk, publishedChartFiles, decodedCharts: Int
            let retainedOnFailure, reopenedWithoutSource, corruptBlockRejected, interruptedCommitRecovered: Bool
            let results: [ParityResult]
        }
        if args.count == 2 {
            let evidence = Evidence(packageID: id, snapshot: m.snapshot.hash, files: m.fileCount, bytes: m.totalBytes,
                                    chunks: m.chunks.count, resumedAtChunk: reads.first ?? 0,
                                    publishedChartFiles: chartFiles.count, decodedCharts: charts,
                                    retainedOnFailure: rejected, reopenedWithoutSource: true, corruptBlockRejected: corruptBlockRejected,
                                    interruptedCommitRecovered: true, results: results)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(evidence).write(to: URL(fileURLWithPath: args[1]), options: .atomic)
        }
        guard failures.isEmpty else { throw ResearchError("\(failures.count)/\(results.count) 份对账有差异") }
        print("通过 \(results.count) 份 Python / Swift 对账；\(m.fileCount) 个原件，\(m.totalBytes) 字节；断点续传、错误回滚和离线重开通过")
    }
}
