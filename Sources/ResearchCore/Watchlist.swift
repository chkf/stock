import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct WatchedSecurity: Codable, Identifiable {
    public var id: String { symbol }
    public let symbol, name, through, evidenceHash: String
    public let bars: [String: Bar]
}

extension PrivateLibrary {
    private var watchDir: URL { root.appendingPathComponent("watchlist") }
    private func watchIndex() throws -> [String: String] {
        let url = watchDir.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }
    public func watchlist() throws -> [WatchedSecurity] {
        try watchIndex().sorted(by: { $0.key < $1.key }).map { symbol, hash in
            guard Integrity.digestID(hash) else { throw ResearchError("自选记录标识损坏") }
            let bytes = try Data(contentsOf: watchDir.appendingPathComponent(hash + ".json"))
            guard Integrity.sha(bytes) == hash else { throw ResearchError("自选行情校验失败") }
            let quote = try JSONDecoder().decode(WatchedSecurity.self, from: bytes)
            guard quote.symbol == symbol, Integrity.digestID(quote.evidenceHash),
                  try Integrity.sha(Data(contentsOf: watchDir.appendingPathComponent(quote.evidenceHash + ".source"))) == quote.evidenceHash
            else { throw ResearchError("自选行情来源校验失败") }
            return quote
        }
    }
    public func removeWatch(_ symbol: String) throws {
        var list = try watchIndex()
        list.removeValue(forKey: symbol)
        try JSONEncoder().encode(list).write(to: watchDir.appendingPathComponent("index.json"), options: .atomic)
    }
    public func updateWatch(_ input: String) async throws {
        let s = try AccountInput.symbol(input)
        let calendar = try Sessions(), end = try calendar.completed()
        let endIndex = try calendar.index(end), start = calendar.days[max(0, endIndex - 629)]
        let address = PublicFeed.quoteURL(s, start, end)
        var request = URLRequest(url: address)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://gu.qq.com/", forHTTPHeaderField: "Referer")
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 22
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == address.host,
              http.url?.scheme == "https", data.count < 8*1024*1024 else { throw ResearchError("\(s) 公开日线获取失败") }
        let bars = try PublicFeed.quotes(data, symbol: s, from: start, through: end)
        guard let through = bars.keys.max() else { throw ResearchError("\(s) 没有可用的已完成交易日行情") }
        let ticker = PublicFeed.ticker(s)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let quote = (parsed?["data"] as? [String: Any])?[ticker] as? [String: Any]
        let details = (quote?["qt"] as? [String: Any])?[ticker] as? [Any]
        let name = details.flatMap { $0.count > 2 && $0[2] as? String == String(s.prefix(6)) ? $0[1] as? String : nil }
        let sourceHash = Integrity.sha(data)
        let quoteRecord = WatchedSecurity(symbol: s, name: name ?? s, through: through, evidenceHash: sourceHash, bars: bars)
        let bytes = try JSONEncoder().encode(quoteRecord), hash = Integrity.sha(bytes)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: watchDir, withIntermediateDirectories: true)
        try data.write(to: watchDir.appendingPathComponent(sourceHash + ".source"), options: .atomic)
        try bytes.write(to: watchDir.appendingPathComponent(hash + ".json"), options: .atomic)
        var list = try watchIndex()
        list[s] = hash
        try JSONEncoder().encode(list).write(to: watchDir.appendingPathComponent("index.json"), options: .atomic)
    }
}
