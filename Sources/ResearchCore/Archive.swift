import Foundation
import CArchive

public struct ResearchError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

public enum Integrity {
    private static func hex(_ digest: [UInt8]) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { sr_digest($0.bindMemory(to: UInt8.self).baseAddress, data.count, &digest) }
        return hex(digest)
    }

    static func sha(file: URL, offset: Int, length: Int) throws -> String {
        var digest = [UInt8](repeating: 0, count: 32)
        guard sr_range_digest(file.path, Int64(offset), Int64(length), &digest) == 0 else {
            throw ResearchError("归档读取不完整")
        }
        return hex(digest)
    }

    public static func gunzip(_ data: Data, limit: Int = 128 * 1024 * 1024) throws -> Data {
        var pointer: UnsafeMutablePointer<UInt8>?
        var count = 0
        let status = data.withUnsafeBytes {
            sr_gunzip($0.bindMemory(to: UInt8.self).baseAddress, data.count, limit, &pointer, &count)
        }
        guard status == 0, let pointer else { throw ResearchError("压缩原件损坏或超出解码内存预算") }
        return Data(bytesNoCopy: pointer, count: count, deallocator: .custom { p, _ in sr_release(p) })
    }

    static func digestID(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct MarketID: Codable, Equatable {
    public let hash: String
    public let as_of: String
}

public struct ArchiveEntry: Codable, Identifiable {
    public var id: String { path }
    public let path: String
    public let offset, size: Int
    public let sha256: String
}

public struct Manifest: Codable {
    public let schema, profile, sourceRoot: String
    public let aliases: [String: String]
    public let snapshot: MarketID
    public let files: [ArchiveEntry]
    public let fileCount, totalBytes, chunkSize: Int
    public let chunks: [String]

    public static func checked(_ data: Data, id: String) throws -> Manifest {
        guard Integrity.sha(data) == id else { throw ResearchError("迁移清单编号不符") }
        let m = try JSONDecoder().decode(Self.self, from: data)
        guard m.schema == "stock-transfer-1", ["project", "snapshot"].contains(m.profile),
              m.chunkSize == 2 * 1024 * 1024, m.fileCount == m.files.count,
              m.totalBytes > 0, m.chunks.count == (m.totalBytes - 1) / m.chunkSize + 1,
              m.chunks.allSatisfy(Integrity.digestID), Integrity.digestID(m.snapshot.hash) else {
            throw ResearchError("清单版本、文件数、分块或大小异常")
        }
        var seen = Set<String>(), cursor = 0
        for f in m.files {
            let parts = f.path.components(separatedBy: "/")
            guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  f.path.rangeOfCharacter(from: CharacterSet(charactersIn: "\\:\0")) == nil,
                  seen.insert(f.path.lowercased()).inserted, f.offset == cursor,
                  f.size >= 0, f.size <= m.totalBytes - cursor, Integrity.digestID(f.sha256) else {
                throw ResearchError("文件索引不连续、重复或包含非法路径")
            }
            cursor += f.size
        }
        guard cursor == m.totalBytes else { throw ResearchError("清单文件字节数不符") }
        return m
    }
}

public struct Archive {
    public let directory: URL
    public let id: String
    public let manifest: Manifest
    private let entries: [String: ArchiveEntry]
    private let aliases: [String: ArchiveEntry]
    public var payload: URL { directory.appendingPathComponent("payload.bin") }

    public init(directory: URL, id: String) throws {
        self.directory = directory
        self.id = id
        manifest = try Manifest.checked(Data(contentsOf: directory.appendingPathComponent("manifest.json")), id: id)
        entries = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path.lowercased(), $0) })
        var mapped = [String: ArchiveEntry]()
        for (original, relative) in manifest.aliases {
            let key = original.replacingOccurrences(of: "\\", with: "/").lowercased()
            guard let entry = entries[relative.lowercased()], mapped[key] == nil || mapped[key]?.path == entry.path else {
                throw ResearchError("旧路径映射缺少原件或存在歧义")
            }
            mapped[key] = entry
        }
        aliases = mapped
    }

    public func resolve(_ original: String) -> ArchiveEntry? {
        let path = original.replacingOccurrences(of: "\\", with: "/").lowercased()
        if let match = aliases[path] { return match }
        if let match = entries[path] { return match }
        let prefix = manifest.sourceRoot.replacingOccurrences(of: "\\", with: "/").lowercased() + "/"
        if path.hasPrefix(prefix) { return entries[String(path.dropFirst(prefix.count))] }
        // Relocated full projects retain their original absolute strings. A unique anchored
        // suffix is usable. Ambiguity is surfaced by returning nil.
        let parts = path.components(separatedBy: "/")
        guard path.hasPrefix("/") || (parts.first?.hasSuffix(":") == true) else { return nil }
        let roots = ["data", "work", "research", "stock_research", "docs"]
        let matches = parts.indices.filter { roots.contains(parts[$0]) }
            .compactMap { entries[parts[$0...].joined(separator: "/")] }
        return matches.count == 1 ? matches[0] : nil
    }

    public func read(_ path: String, maximum: Int = 128 * 1024 * 1024) throws -> Data {
        guard let f = resolve(path) else { throw ResearchError("未找到原件或来源路径有歧义 \(path)") }
        guard f.size <= maximum else { throw ResearchError("原件已保存，完整解码超出内存预算") }
        let handle = try FileHandle(forReadingFrom: payload)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(f.offset))
        let data = try handle.read(upToCount: f.size) ?? Data()
        guard data.count == f.size, Integrity.sha(data) == f.sha256 else { throw ResearchError("原件校验失败 \(f.path)") }
        return data
    }

    public func loadMarket() throws -> MarketSnapshot {
        let info = try JSONDecoder().decode(MarketID.self, from: read("data/advice/market/latest.json"))
        guard info == manifest.snapshot else { throw ResearchError("行情指针与迁移清单不符") }
        let path = "data/advice/market/snapshots/\(info.hash).json.gz"
        let raw = try Integrity.gunzip(read(path))
        guard Integrity.sha(raw) == info.hash else { throw ResearchError("原行情快照编号不符") }
        let market = try JSONDecoder().decode(MarketSnapshot.self, from: raw)
        guard market.schema == "advice-market-v1", market.as_of == info.as_of,
              Set(market.securities.keys) == MarketSnapshot.pool else { throw ResearchError("行情版本、日期或28只固定池异常") }
        for (original, sha) in market.sources {
            guard let f = resolve(original), f.sha256 == sha,
                  try Integrity.sha(file: payload, offset: f.offset, length: f.size) == sha else {
                throw ResearchError("来源证据无法核对 \(original)")
            }
        }
        return market
    }

    public func verify(progress: (Int, Int) throws -> Void = { _, _ in }) throws {
        let size = try payload.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == manifest.totalBytes else { throw ResearchError("总大小不符") }
        for (i, f) in manifest.files.enumerated() {
            if i % 64 == 0 { try progress(i, manifest.fileCount) }
            guard try Integrity.sha(file: payload, offset: f.offset, length: f.size) == f.sha256 else {
                throw ResearchError("逐文件校验失败 \(f.path)")
            }
            if f.path.hasPrefix("data/advice/market/snapshots/"), f.path.hasSuffix(".json.gz") {
                let basename = String(f.path.split(separator: "/").last!.dropLast(8))
                if !Integrity.digestID(basename) || (try? Integrity.sha(Integrity.gunzip(read(f.path)))) != basename {
                    throw ResearchError("历史行情快照编号不符 \(f.path)")
                }
            }
            if f.path.hasPrefix("data/snapshots/"), f.path.hasSuffix(".csv") {
                let key = String(f.path.split(separator: "/").last!.dropLast(4))
                guard Integrity.digestID(key) else { throw ResearchError("CSV 快照编号格式错误") }
                if f.sha256 != key {
                    // Exact newline variants accepted by stock_research.integrity.read_snapshot.
                    let bytes = try read(f.path)
                    guard let text = String(data: bytes, encoding: .utf8),
                          ["\r\r\n", "\r\n"].contains(where: { variant in
                              let replacement = variant == "\r\r\n" ? "\r\n" : "\n"
                              return Integrity.sha(Data(text.replacingOccurrences(of: variant, with: replacement).utf8)) == key
                          }) else { throw ResearchError("原 CSV 行情编号不符 \(f.path)") }
                }
            }
            if f.path.hasPrefix("data/actions/"), f.path.hasSuffix(".json") {
                let id = f.path.hasPrefix("data/actions/snapshots/") ? String(f.path.split(separator: "/").last!.dropLast(5)) : nil
                try ActionIdentity.verify(read(f.path), filenameID: id)
            }
        }
        _ = try loadMarket()
        try progress(manifest.fileCount, manifest.fileCount)
    }
}
