import Foundation

public struct Bar: Codable { public let open, close, high, low, volume: Double }
public struct MarketEvent: Codable {
    public let date: String
    public let cash_per_share, share_factor: Double?
    public let record_date, source, payment_date: String?
}
public struct MarketSecurity: Codable {
    public let name, group: String
    public var bars: [String: Bar]
    public var signal_close: [String: Double]
    public var events: [MarketEvent]
    public var provider_events: [ProviderEvent]?
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

public struct Decision: Codable {
    public let strategy, route, marketState, date: String
    public let selected: [String]
    public let weights, scores, breadth: [String: Double]
}

public struct StrategyEngine {
    public let market: MarketSnapshot
    public let sessions: Sessions
    public init(market: MarketSnapshot, sessions: Sessions) {
        self.market = market
        self.sessions = sessions
    }

    public func decision(_ strategy: String, on date: String, previousState: String = "UNKNOWN") throws -> Decision {
        guard date <= market.as_of else { throw ResearchError("行情滞后，停止生成当前份额") }
        guard ["MOM20", "GB"].contains(strategy) else { throw ResearchError("该策略尚未完成等价移植") }
        let pos = try sessions.index(date)
        var scores = [String: Double](), groups = [String: [String]]()
        var votes = ["up60": 0, "down60": 0, "up200": 0, "down200": 0]
        var voters = 0
        for symbol in market.securities.keys.sorted() {
            let sec = market.securities[symbol]!
            guard pos >= 251 else { continue }
            let window = sessions.days[(pos - 251)...pos].compactMap { sec.signal_close[$0] }
            guard window.count == 252 else { continue }
            guard window.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw ResearchError("\(symbol) 信号价无效") }
            let group = sec.group.hasPrefix("domestic") ? "domestic_equity" : sec.group
            groups[group, default: []].append(symbol)
            let price = window[251]
            if pos >= 252, let old = sec.signal_close[sessions.days[pos - 252]], old.isFinite, old > 0,
               price > window[251 - 126] { scores[symbol] = price / old - 1 }
            if group == "domestic_equity" {
                voters += 1
                for n in [60, 200] {
                    let ma = mean(window[(252 - n)..<252])
                    let previous = mean(window[(232 - n)..<232])
                    let slope = ma / previous - 1
                    if price > ma && slope > 0 { votes["up\(n)", default: 0] += 1 }
                    if price < ma && slope < 0 { votes["down\(n)", default: 0] += 1 }
                }
            }
        }
        var breadth = ["count": Double(voters), "threshold": 0.6]
        var state = previousState
        if voters > 0 {
            for (k, v) in votes { breadth[k] = Double(v) / Double(voters) }
            if breadth["down60"]! >= 0.6 || breadth["down200"]! >= 0.6 { state = "BEAR" }
            else if breadth["up60"]! >= 0.6 && breadth["up200"]! >= 0.6 { state = "BULL" }
            else { state = "TRANSITION" }
        }
        if strategy == "GB" {
            var weights = [String: Double]()
            for group in ["domestic_equity", "overseas_equity", "commodity", "bond"] {
                let members = groups[group] ?? []
                for s in members { weights[s] = 0.25 / Double(members.count) }
            }
            return Decision(strategy: strategy, route: "GB", marketState: state, date: date,
                            selected: [], weights: weights, scores: [:], breadth: breadth)
        }
        let selected = Array(scores.keys.sorted {
            scores[$0] == scores[$1] ? $0 < $1 : scores[$0]! > scores[$1]!
        }.prefix(3))
        return Decision(strategy: strategy, route: "MOM", marketState: state, date: date, selected: selected,
                        weights: Dictionary(uniqueKeysWithValues: selected.map { ($0, 1.0 / 3) }),
                        scores: scores, breadth: breadth)
    }

    private func mean(_ values: ArraySlice<Double>) -> Double {
        var sum = 0.0, correction = 0.0
        for x in values {
            let y = x - correction, next = sum + y
            correction = (next - sum) - y
            sum = next
        }
        return sum / Double(values.count)
    }
}
