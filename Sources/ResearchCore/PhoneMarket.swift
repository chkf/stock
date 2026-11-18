import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PhoneSnapshot {
    public let market: MarketSnapshot
    public let hash: String
    public let usableFrom: String
}

extension PrivateLibrary {
    private var quoteDirectory: URL { root.appendingPathComponent("public-market") }
    private struct QuotePointer: Codable { let id, through: String }

    public func phoneMarket() throws -> PhoneSnapshot? {
        let pointer = quoteDirectory.appendingPathComponent("current.json")
        guard FileManager.default.fileExists(atPath: pointer.path) else { return nil }
        let p = try JSONDecoder().decode(QuotePointer.self, from: Data(contentsOf: pointer))
        guard Integrity.digestID(p.id) else { throw ResearchError("本机行情指针损坏") }
        let bytes = try Data(contentsOf: quoteDirectory.appendingPathComponent("snapshots/\(p.id).json"))
        guard Integrity.sha(bytes) == p.id else { throw ResearchError("本机行情快照校验失败") }
        let market = try JSONDecoder().decode(MarketSnapshot.self, from: bytes)
        guard market.schema == "iphone-public-market-1", market.as_of == p.through,
              Set(market.securities.keys) == MarketSnapshot.pool else { throw ResearchError("本机行情固定池或日期异常") }
        let rules = try PublicRules.load(), cal = try Sessions()
        let first = try cal.index(rules.anchor) + 252
        let restored = PhoneSnapshot(market: market, hash: p.id, usableFrom: cal.days[first])
        for key in market.sources.keys { _ = try onlineEvidence(key, snapshot: restored) }
        return restored
    }

    public func onlineEvidence(_ key: String, snapshot: PhoneSnapshot) throws -> Data {
        let parts = key.components(separatedBy: "/")
        guard parts.count == 3, parts[0] == "captures", UUID(uuidString: parts[1]) != nil,
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
    public func refreshPublicMarket(asOf: String? = nil, progress: @escaping (TransferProgress) -> Void) async throws -> PhoneSnapshot {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.urlCredentialStorage = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 22
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        return try await rebuildPublicMarket(through: Sessions().completed(asOf: asOf), fetch: { url in
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            if url.host == "proxy.finance.qq.com" { req.setValue("https://gu.qq.com/", forHTTPHeaderField: "Referer") }
            let (bytes, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https",
                  !bytes.isEmpty, bytes.count <= 8 * 1024 * 1024 else { throw ResearchError("行情源未返回有效资料") }
            return bytes
        }, progress: progress)
    }

    public func rebuildPublicMarket(through: String, fetch: @escaping (URL) async throws -> Data,
                                    progress: @escaping (TransferProgress) -> Void) async throws -> PhoneSnapshot {
        guard !updatingQuotes else { throw ResearchError("行情更新正在进行") }
        updatingQuotes = true
        defer { updatingQuotes = false }
        let prior = try phoneMarket(), rules = try PublicRules.load(), cal = try Sessions()
        if let prior, prior.market.as_of == through { return prior }
        let first = prior?.market.as_of ?? rules.anchor
        let firstIndex = try cal.index(first), end = try cal.index(through)
        guard end > firstIndex, end - firstIndex < 640, end >= (try cal.index(rules.anchor)) + 252 else {
            throw ResearchError("行情窗口超出原始接口覆盖，或不足 253 个交易日")
        }
        let days = cal.days[(firstIndex + 1)...end]
        var market = prior?.market ?? MarketSnapshot(schema: "iphone-public-market-1", as_of: first, securities: [:], sources: [:],
            extras: [:], limitations: ["来自本机请求的公开 ETF 行情；按原版普通交易状态假设，收盘价估份额。", "历史始于 2025-01-02。"])
        let run = "captures/" + UUID().uuidString
        let folder = quoteDirectory.appendingPathComponent(run)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var requests = [[String: String]]()
        func capture(_ url: URL, as name: String) async throws -> Data {
            try Task.checkCancellation()
            let bytes = try await fetch(url)
            try bytes.write(to: folder.appendingPathComponent(name), options: .atomic)
            let key = "\(run)/\(name)", hash = Integrity.sha(bytes)
            market.sources[key] = hash
            requests.append(["url": url.absoluteString, "path": key, "sha256": hash])
            return bytes
        }
        func saveCapture(_ status: String, _ reason: String = "") throws -> String {
            let record: [String: Any] = ["status": status, "through": through, "from": first,
                                         "parent": prior?.hash ?? "", "requests": requests, "reason": reason]
            let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try bytes.write(to: folder.appendingPathComponent("capture.json"), options: .atomic)
            return Integrity.sha(bytes)
        }
        do {
            for (i, s) in rules.members.keys.sorted().enumerated() {
                let member = rules.members[s]!
                progress(.init(phase: "\(s) 读取原始行情", completed: 2 * i, total: 56))
                let raw = try await capture(PublicFeed.quoteURL(s, first, through), as: "\(s).quotes.json")
                let bars = try PublicFeed.quotes(raw, symbol: s, from: first, through: through)
                let priorSec = market.securities[s]
                let previousClose = priorSec?.bars[first]?.close ?? member.anchorClose
                guard let anchor = bars[first], abs(anchor.close - previousClose) <= 1e-8 else { throw ResearchError("\(s) 衔接收盘价不同或缺日") }
                if first <= rules.reviewedThrough, through >= rules.reviewedThrough {
                    guard let px = bars[rules.reviewedThrough]?.close, abs(px - member.reviewedClose) <= 1e-8 else {
                        throw ResearchError("\(s) 已复核日期的收盘价发生修订")
                    }
                }
                progress(.init(phase: "\(s) 核对分红拆合", completed: 2 * i + 1, total: 56))
                var provider = [ProviderEvent]()
                for attempt in 0..<2 {
                    do {
                        let html = try await capture(PublicFeed.actionsURL(s), as: "\(s).actions-\(attempt).html")
                        provider = try PublicFeed.actions(html, symbol: s, rules: rules)
                        try PublicFeed.validateHistory(provider, old: member.provider, through: min(through, rules.reviewedThrough), symbol: s)
                        if let earlier = priorSec?.provider_events {
                            try PublicFeed.validateHistory(provider, old: earlier, through: first, symbol: s)
                        }
                        break
                    } catch {
                        try Task.checkCancellation()
                        if attempt == 1 { throw error }
                        try await Task.sleep(nanoseconds: 600_000_000)
                    }
                }
                var security = priorSec ?? MarketSecurity(name: member.name, group: member.group, bars: [first: anchor],
                    signal_close: [first: member.anchorSignal], events: [], provider_events: nil)
                let reviewedEvents = member.events.filter { first < $0.date && $0.date <= min(through, rules.reviewedThrough) }
                var events = reviewedEvents
                for e in provider where e.date > max(first, rules.reviewedThrough) && e.date <= through {
                    guard e.share_factor == 1, !e.needsReview else { throw ResearchError("\(s) 新拆合需核实生效日、可卖日及舍入") }
                    guard e.supported, let record = e.record_date, record <= e.date, AccountInput.validDate(record) else {
                        throw ResearchError("\(s) 新公司行动证据不完整")
                    }
                    events.append(.init(date: e.date, cash_per_share: e.cash_per_share, share_factor: 1, record_date: record,
                                        source: PublicFeed.actionsURL(s).absoluteString, payment_date: nil))
                }
                var last = anchor.close, factor = security.signal_close[first]! / last
                for d in days {
                    var reference = last
                    for event in events where event.date == d {
                        let cash = event.cash_per_share ?? 0, split = event.share_factor ?? 1
                        guard cash >= 0, cash < reference, split > 0 else { throw ResearchError("\(s) \(d) 公司行动数值异常") }
                        factor *= split * reference / (reference - cash)
                        reference = (reference - cash) / split
                    }
                    if let bar = bars[d] {
                        try PublicFeed.validateBand(bar, reference: reference, band: member.band, symbol: s, date: d)
                        if member.halts[d] != nil && bar.volume > 0 { throw ResearchError("\(s) \(d) 已核停牌与成交量冲突") }
                        last = bar.close
                        security.bars[d] = bar
                    } else if member.halts[d] != nil && d <= rules.reviewedThrough {
                        last = reference
                    } else { throw ResearchError("\(s) \(d) 缺行情或停牌证据，固定池停止更新") }
                    security.signal_close[d] = last * factor
                }
                security.events += events
                security.provider_events = provider.filter { $0.date <= through }
                market.securities[s] = security
            }
            try Task.checkCancellation()
            market.as_of = through
            market.sources[run + "/capture.json"] = try saveCapture("accepted")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let payload = try encoder.encode(market), id = Integrity.sha(payload)
            let snapshots = quoteDirectory.appendingPathComponent("snapshots")
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            try payload.write(to: snapshots.appendingPathComponent(id + ".json"), options: .atomic)
            try encoder.encode(QuotePointer(id: id, through: through)).write(to: quoteDirectory.appendingPathComponent("current.json"), options: .atomic)
            progress(.init(phase: "已校验 28 只 ETF", completed: 56, total: 56))
            return PhoneSnapshot(market: market, hash: id, usableFrom: cal.days[try cal.index(rules.anchor) + 252])
        } catch {
            _ = try? saveCapture("refused", error.localizedDescription)
            throw error
        }
    }
}
