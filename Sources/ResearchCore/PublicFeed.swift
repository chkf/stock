import CArchive
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ProviderEvent: Codable, Hashable {
    let date: String
    let record_date: String?
    let cash_per_share, share_factor: Double
    let supported: Bool
    let date_needs_reconciliation: Bool?
    var payment_date:String?
    var needsReview: Bool { date_needs_reconciliation ?? false }
    public static func == (a: Self, b: Self) -> Bool {
        a.date == b.date && a.record_date == b.record_date && a.cash_per_share == b.cash_per_share &&
        a.share_factor == b.share_factor && a.supported == b.supported && a.needsReview == b.needsReview
    }
    public func hash(into h: inout Hasher) {
        h.combine(date); h.combine(record_date); h.combine(cash_per_share); h.combine(share_factor)
        h.combine(supported); h.combine(needsReview)
    }
}

struct PublicRules: Decodable {
    struct Member: Decodable {
        let name, group: String
        let band, anchorClose, anchorSignal, reviewedClose: Double
        let bandFrom: String?
        let events: [MarketEvent]
        let provider: [ProviderEvent]
        let halts: [String: String]
    }
    let anchor, reviewedThrough: String
    let members: [String: Member]
    let review159936: [Double]
    static func load() throws -> Self {
        let rules = try JSONDecoder().decode(Self.self,from:FrozenInputs.data("PublicRules.json"))
        guard Set(rules.members.keys) == MarketSnapshot.pool else { throw ResearchError("公开证券规则池不完整") }
        return rules
    }
}

enum PublicFeed {
    static func checkedHTTP(status:Int?,responseURL:URL?,requested:URL,bytes:Data) throws -> Data {
        guard status==200,responseURL?.scheme=="https",responseURL?.host==requested.host,responseURL?.path==requested.path,
              !bytes.isEmpty,bytes.count<=8*1024*1024 else {
            throw HistoryHTTPFailure(status:status,responseURL:responseURL,bytes:bytes,errorDescription:"HTTP \(status.map(String.init) ?? "未知")，行情响应地址、长度或状态无效")
        }
        return bytes
    }
    static func ticker(_ symbol: String) -> String { String(symbol.suffix(2)).lowercased() + String(symbol.prefix(6)) }
    static func quoteURL(_ symbol: String, _ from: String, _ through: String) -> URL {
        var u = URLComponents(string: "https://proxy.finance.qq.com/ifzqgtimg/appstock/app/newfqkline/get")!
        u.queryItems = [URLQueryItem(name: "param", value: "\(ticker(symbol)),day,\(from),\(through),640,")]
        return u.url!
    }
    static func actionsURL(_ s: String) -> URL { URL(string: "https://fundf10.eastmoney.com/fhsp_\(s.prefix(6)).html")! }

    static func quotes(_ bytes: Data, symbol: String, from: String, through: String) throws -> [String: Bar] {
        let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        if let code=root?["code"],String(describing:code) != "0" { throw ResearchError("\(symbol) 行情接口返回错误 \(code)") }
        guard let data = root?["data"] as? [String: Any], let quote = data[ticker(symbol)] as? [String: Any],
              let rows = quote["day"] as? [[Any]] else { throw ResearchError("\(symbol) 原始行情字段缺失") }
        if let qt=quote["qt"] {
            guard let table=qt as? [String:Any],let identity=table[ticker(symbol)] as? [Any],identity.count>=3,
                  String(describing:identity[2])==String(symbol.prefix(6)) else { throw ResearchError("\(symbol) 响应内证券身份冲突") }
        }
        var bars = [String: Bar](), advancedBeyondEnd=false
        for row in rows {
            guard row.count>=6, let d=row[0] as? String, AccountInput.validDate(d) else { throw ResearchError("\(symbol) 日线缺字段或日期无效") }
            if d>through { advancedBeyondEnd=true; continue }
            if d<from { continue }
            let v = row[1...5].compactMap { Double(String(describing: $0)) }
            guard v.count == 5, v.allSatisfy(\.isFinite), v.prefix(4).allSatisfy({ $0 > 0 }), v[4] >= 0,
                  bars[d] == nil, v[2] + 1e-8 >= max(v[0], v[1], v[3]), v[3] - 1e-8 <= min(v[0], v[1], v[2]) else {
                throw ResearchError("\(symbol) \(d) 行情重复或 OHLC 无效")
            }
            bars[d] = .init(open: v[0], close: v[1], high: v[2], low: v[3], volume: v[4])
        }
        if bars.isEmpty && advancedBeyondEnd { throw ResearchError("\(symbol) \(from) 至 \(through) 分页未前进，源忽略了日期边界") }
        return bars
    }

    private static func matches(_ pattern: String, _ text: String, capture: Int = 0) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: capture), in: text).map { String(text[$0]) }
        }
    }
    static func page(_ data: Data) throws -> String {
        let head = String(decoding: data.prefix(5000), as: UTF8.self)
        let charset = try matches(#"charset\s*=\s*([\w-]+)"#, head, capture: 1).first?.lowercased()
        if charset == "utf-8" || charset == "utf8" {
            guard let text = String(data: data, encoding: .utf8) else { throw ResearchError("公司行动页面 UTF-8 编码无效") }
            return text
        }
        guard charset == nil || ["gb2312", "gbk", "gb18030"].contains(charset!) else { throw ResearchError("未知公司行动页面编码") }
        var ptr: UnsafeMutablePointer<UInt8>?, count = 0
        let status = data.withUnsafeBytes { sr_gb18030_utf8($0.bindMemory(to: UInt8.self).baseAddress, data.count, &ptr, &count) }
        guard status == 0, let ptr else { throw ResearchError("公司行动页面编码无效") }
        defer { sr_release(ptr) }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: count), as: UTF8.self)
    }
    static func actions(_ data: Data, symbol: String, rules: PublicRules) throws -> [ProviderEvent] {
        let html = try page(data)
        guard let title = try matches(#"<title>(.*?)</title>"#, html, capture: 1).first,
              try matches(#"\d{6}"#, title) == [String(symbol.prefix(6))] else { throw ResearchError("\(symbol) 行动页面身份不匹配") }
        let tables = try matches(#"<table\b[^>]*>.*?</table>"#, html)
        guard let dividends = tables.first(where: { $0.contains("每10份分红") && $0.contains("权益登记日") }),
              let splits = tables.first(where: { $0.contains("拆分折算比例") }) else { throw ResearchError("基金分红拆分表格式变化") }
        var events = [ProviderEvent]()
        for (table, split) in [(dividends, false), (splits, true)] {
            for row in try matches(#"<tr\b[^>]*>(.*?)</tr>"#, table, capture: 1) {
                let cells = try matches(#"<td\b[^>]*>(.*?)</td>"#, row, capture: 1).map {
                    $0.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "&nbsp;", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if cells.isEmpty || cells.contains(where: { $0.contains("暂无") }) { continue }
                guard cells.count == (split ? 4 : 5) else { throw ResearchError("\(symbol) 行动资料不完整") }
                let d = cells[split ? 1 : 2]
                let pattern = split ? #"^1[:：]([\d.]+)$"# : #"每10份派现金([\d.]+)元"#
                guard AccountInput.validDate(d), let match = try matches(pattern, cells[3], capture: 1).first,
                      let n = Double(match), n.isFinite, split ? n > 0 : n >= 0 else { throw ResearchError("\(symbol) 行动日期或金额无效") }
                events.append(.init(date: d, record_date: split ? nil : cells[1], cash_per_share: split ? 0 : n / 10,
                                    share_factor: split ? n : 1, supported: !split || n.rounded() == n,
                                    date_needs_reconciliation: split ? true : nil,
                                    payment_date: !split && AccountInput.validDate(cells[4]) ? cells[4] : nil))
            }
        }
        guard Set(events).count == events.count else { throw ResearchError("\(symbol) 公司行动出现重复条目") }
        let erroneous = ProviderEvent(date: "2023-02-15", record_date: nil, cash_per_share: 0, share_factor: 2,
                                      supported: true, date_needs_reconciliation: true)
        if symbol == "159936.SZ", events.contains(erroneous) {
            let prices = rules.review159936
            guard prices.count == 2, 0.9 < prices[1] / prices[0], prices[1] / prices[0] < 1.1 else {
                throw ResearchError("159936 原专项复核证据不完整")
            }
            events.removeAll { $0 == erroneous }
        }
        return events.sorted { $0.date < $1.date }
    }
    static func validateHistory(_ events: [ProviderEvent], old: [ProviderEvent], through date: String, symbol: String) throws {
        let a=events.filter { $0.date<=date }, b=old.filter { $0.date<=date }
        let official:Set<String>=["2025-09-23","2025-12-26","2026-06-25","2026-09-18"]
        guard a.count==b.count, zip(a,b).allSatisfy({ x,y in
            if x==y { return x.payment_date==nil || y.payment_date==nil || x.payment_date==y.payment_date || (symbol=="511260.SH" && official.contains(x.date)) }
            return symbol=="511260.SH" && official.contains(x.date) && x.date==y.date && x.cash_per_share==y.cash_per_share &&
                x.share_factor==1 && y.share_factor==1 && x.supported==y.supported && x.needsReview==y.needsReview
        }) else {
            throw ResearchError("\(symbol) 历史公司行动有修订或页面缺行，旧资料保留")
        }
    }
    static func validateBand(_ bar: Bar, reference: Double, band: Double, symbol: String, date: String) throws {
        func tick(_ x: Double) throws -> Double {
            guard x.isFinite,var d=Decimal(string:String(x),locale:Locale(identifier:"en_US_POSIX")) else { throw ResearchError("\(symbol) \(date) 参考价无法表示") }
            var rounded=Decimal()
            NSDecimalRound(&rounded, &d, 3, .plain)
            guard let value=Double(NSDecimalNumber(decimal:rounded).stringValue),value.isFinite else { throw ResearchError("\(symbol) \(date) 涨跌停价格无法表示") }
            return value
        }
        let upper=try tick(reference*(1+band)),lower=try tick(reference*(1-band))
        guard upper > lower, lower > 0, bar.high <= upper + 0.001, bar.low >= lower - 0.001 else {
            throw ResearchError("\(symbol) \(date) OHLC 超出原版历史交易范围，需要核对事件")
        }
    }
}
