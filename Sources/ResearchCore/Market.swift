import Foundation

public struct Bar: Codable { public let open, close, high, low, volume: Double }
public struct MarketEvent: Codable {
    public let date: String
    public let cash_per_share, share_factor: Double?
    public let record_date, source, payment_date: String?
    public var available_date, rounding: String?
}
public struct MarketSecurity: Codable {
    public let name, group: String
    public var bars: [String: Bar]
    public var signal_close: [String: Double]
    public var events: [MarketEvent]
    public var provider_events: [ProviderEvent]?
    public var statuses: [String: MarketStatus]?
}
public struct MarketStatus: Codable {
    public let state: String?
    public let upper_limit, lower_limit: Double?
}
public struct ExtraQuote: Codable { public let date: String; public let close: Double }
public struct MarketSnapshot: Codable {
    public let schema: String
    public var as_of: String
    public var securities: [String: MarketSecurity]
    public var sources: [String: String]
    public let extras: [String: ExtraQuote]
    public let limitations: [String]
    public static let pool: Set<String> = [
        "159611.SZ","159919.SZ","159920.SZ","159928.SZ","159936.SZ","159939.SZ","159944.SZ",
        "159945.SZ","159952.SZ","159980.SZ","159981.SZ","159985.SZ","510880.SH","511010.SH",
        "511260.SH","512010.SH","512070.SH","512200.SH","512480.SH","512660.SH","512800.SH",
        "513030.SH","513100.SH","513500.SH","515790.SH","515880.SH","518880.SH","588000.SH"
    ]
}

public struct Sessions {
    public let days: [String]
    private let indices: [String: Int]

    public init() throws {
        guard let url = Bundle.module.url(forResource: "XSHG", withExtension: "txt") else {
            throw ResearchError("交易日历缺失")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        days = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !days.isEmpty, days == days.sorted(), Set(days).count == days.count else {
            throw ResearchError("交易日历损坏")
        }
        indices = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($1, $0) })
    }

    public func index(_ date: String) throws -> Int {
        guard let i = indices[date] else { throw ResearchError("缺少该交易日的 XSHG 日历 \(date)") }
        return i
    }

    public func next(_ date: String) throws -> String {
        let i = try index(date)
        guard days.indices.contains(i + 1) else { throw ResearchError("下一交易日超出原版日历覆盖") }
        return days[i + 1]
    }

    public func monthEnd(_ date: String) throws -> Bool { try next(date).prefix(7) != date.prefix(7) }

    public func completed(asOf requested: String? = nil, now: Date = Date()) throws -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = cal
        formatter.timeZone = cal.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let today = formatter.string(from: now)
        let beforeClose = cal.component(.hour, from: now) < 16
        let cutoff = formatter.string(from: beforeClose ? cal.date(byAdding: .day, value: -1, to: now)! : now)
        if let requested {
            guard let parsed = formatter.date(from: requested), formatter.string(from: parsed) == requested,
                  requested <= today else { throw ResearchError("日期无效或晚于今天") }
        }
        let through = min(requested ?? cutoff, cutoff)
        guard through.prefix(4) <= days.last!.prefix(4), let day = days.last(where: { $0 <= through }) else {
            throw ResearchError("日期超出已封存的交易日历")
        }
        return day
    }
}

