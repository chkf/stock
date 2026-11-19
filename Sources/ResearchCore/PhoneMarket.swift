import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PhoneSnapshot {
    public let market: MarketSnapshot
    public let hash: String
    public let usableFrom: String?
}

extension PrivateLibrary {
    private var universeRoot:URL { root.appendingPathComponent("universe-v1") }
    public func catalogMarket() throws -> PhoneSnapshot? {
        let pointer=universeRoot.appendingPathComponent("current.json")
        guard FileManager.default.fileExists(atPath:pointer.path) else { return nil }
        let id=try JSONDecoder().decode(String.self,from:Data(contentsOf:pointer))
        return try readUniverse(id,staged:false)
    }
    public func activateCatalog(_ id:String) throws -> PhoneSnapshot {
        try HistoryWriters.shared.claim(root); defer { HistoryWriters.shared.release(root) }
        let snapshot=try readUniverse(id,staged:true)
        try Task.checkCancellation()
        try JSONEncoder().encode(id).write(to:universeRoot.appendingPathComponent("current.json"),options:.atomic)
        return snapshot
    }
    private func readUniverse(_ id:String,staged:Bool) throws -> PhoneSnapshot {
        let cache=universeRoot.appendingPathComponent("blobs"), inbox=root.deletingLastPathComponent().appendingPathComponent("目录行情/blobs")
        if staged { try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true) }
        func read(_ hash:String) throws -> Data {
            guard Integrity.digestID(hash) else { throw ResearchError("无效目录文件编号") }
            let dest=cache.appendingPathComponent(hash), cached=FileManager.default.fileExists(atPath:dest.path), folder=cached || !staged ? cache : inbox
            let bytes=try WorkspaceVersion.read(folder.appendingPathComponent(hash),under:folder,limit:16*1024*1024)
            guard Integrity.sha(bytes)==hash else { throw ResearchError("目录原件损坏 "+hash) }
            if !cached && staged { try bytes.write(to:dest,options:.atomic) }; return bytes
        }
        let market=try UniverseMarket.load(read(id),calendar:Sessions(),read:read)
        return PhoneSnapshot(market:market,hash:id,usableFrom:market.universe?.from)
    }
    private var quoteDirectory: URL { root.appendingPathComponent("public-market") }
    private struct QuotePointer: Codable { let id, through: String; var previous:String? }

    public func phoneMarket() throws -> PhoneSnapshot? {
        let pointer = quoteDirectory.appendingPathComponent("current.json")
        guard FileManager.default.fileExists(atPath: pointer.path) else { return nil }
        let p = try JSONDecoder().decode(QuotePointer.self, from: Data(contentsOf: pointer))
        let snapshot=try checkedPhone(p.id)
        guard snapshot.market.as_of==p.through else { throw ResearchError("本机行情指针截止日不符") }
        return snapshot
    }
    private func checkedPhone(_ id:String) throws -> PhoneSnapshot {
        guard Integrity.digestID(id) else { throw ResearchError("本机行情指针损坏") }
        let bytes = try Data(contentsOf: quoteDirectory.appendingPathComponent("snapshots/\(id).json"))
        guard Integrity.sha(bytes) == id else { throw ResearchError("本机行情快照校验失败") }
        let market = try JSONDecoder().decode(MarketSnapshot.self, from: bytes)
        guard ["iphone-public-market-1","iphone-public-market-2"].contains(market.schema),
              Set(market.securities.keys) == MarketSnapshot.pool else { throw ResearchError("本机行情固定池或日期异常") }
        let cal=try Sessions()
        let coverage=try HistoryCoverage(market:market,sessions:cal,strategies:WorkspaceVersion.bundled().design.strategies)
        let first=try coverage.windows.first.map { cal.days[try cal.index($0.start)-1] }
        let restored=PhoneSnapshot(market:market,hash:id,usableFrom:first)
        for key in market.sources.keys { _ = try onlineEvidence(key, snapshot: restored) }
        try market.history?.verifyEvidence(sources:market.sources) { try onlineEvidence($0,snapshot:restored) }
        try market.history?.verifyPrices(in:market) { try onlineEvidence($0,snapshot:restored) }
        return restored
    }
    public func restorePreviousPhoneMarket() throws -> PhoneSnapshot {
        try HistoryWriters.shared.claim(root); defer { HistoryWriters.shared.release(root) }
        let current=quoteDirectory.appendingPathComponent("current.json")
        let pointer=try JSONDecoder().decode(QuotePointer.self,from:Data(contentsOf:current))
        guard let previous=pointer.previous else { throw ResearchError("本次升级尚无可切回的上一代本机行情") }
        let restored=try checkedPhone(previous)
        try Task.checkCancellation()
        try JSONEncoder().encode(QuotePointer(id:previous,through:restored.market.as_of,previous:pointer.id)).write(to:current,options:.atomic)
        return restored
    }

    public func onlineEvidence(_ key: String, snapshot: PhoneSnapshot) throws -> Data {
        let parts = key.components(separatedBy: "/")
        guard parts.count == 3, (parts[0] == "captures" && UUID(uuidString: parts[1]) != nil) || (parts[0]=="review" && parts[1]==snapshot.market.sources[key] && Integrity.digestID(parts[1])),
              !parts[2].isEmpty, !parts[2].contains("\\"), !parts[2].contains(":"), ![".", ".."].contains(parts[2]),
              let hash = snapshot.market.sources[key] else { throw ResearchError("行情证据路径无效") }
        let bytes = try Data(contentsOf: quoteDirectory.appendingPathComponent(key))
        guard Integrity.sha(bytes) == hash else { throw ResearchError("行情来源证据损坏") }
        return bytes
    }

    public func onlineText(_ key: String, snapshot: PhoneSnapshot) throws -> String {
        let data = try onlineEvidence(key, snapshot: snapshot)
        if key.hasSuffix(".html") { return try PublicFeed.page(data) }
        guard let text = String(data: data, encoding: .utf8) else { throw ResearchError("原始资料文本编码无效") }
        return text
    }

    // This interface has no account parameter. Only public ticker, interval and user agent leave the device.
    public func refreshPublicMarket(from:String?=nil, asOf: String? = nil, progress: @escaping (TransferProgress) -> Void) async throws -> PhoneSnapshot {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.urlCredentialStorage = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 22
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let cal=try Sessions(),latest=try cal.completed()
        if let date=asOf { guard (try? cal.index(date)) != nil,date<=latest else { throw ResearchError("\(date) 不是已收盘交易日") } }
        return try await rebuildPublicMarket(from:from,through:asOf ?? latest, fetch: { url in
            try await Task.sleep(nanoseconds:180_000_000)
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            if url.host == "proxy.finance.qq.com" { req.setValue("https://gu.qq.com/", forHTTPHeaderField: "Referer") }
            let (bytes, response) = try await session.data(for: req)
            return try PublicFeed.checkedHTTP(status:(response as? HTTPURLResponse)?.statusCode,responseURL:response.url,requested:url,bytes:bytes)
        }, progress: progress)
    }

    public func rebuildPublicMarket(from:String?=nil,through:String,fetch:@escaping (URL) async throws->Data,
                                    progress:@escaping (TransferProgress)->Void) async throws -> PhoneSnapshot {
        try await collectHistory(from:from,through:through,fetch:fetch,progress:progress)
    }
    func readQuoteID() throws -> String? {
        let file=quoteDirectory.appendingPathComponent("current.json")
        guard FileManager.default.fileExists(atPath:file.path) else { return nil }
        return try JSONDecoder().decode(QuotePointer.self,from:Data(contentsOf:file)).id
    }
    private static let publicationLock=NSLock()
    func publishQuote(_ bytes:Data,id:String,through:String,parent:String?) throws {
        Self.publicationLock.lock(); defer { Self.publicationLock.unlock() }
        guard try readQuoteID()==parent else { throw ResearchError("行情父版本已经改变") }
        let snapshots=quoteDirectory.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at:snapshots,withIntermediateDirectories:true)
        try bytes.write(to:snapshots.appendingPathComponent(id+".json"),options:.atomic)
        try Task.checkCancellation()
        try JSONEncoder().encode(QuotePointer(id:id,through:through,previous:parent)).write(to:quoteDirectory.appendingPathComponent("current.json"),options:.atomic)
    }
}
