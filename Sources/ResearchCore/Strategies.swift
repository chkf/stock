import Foundation

public struct StrengthDistance {
    public let eligible, required, shortVotes, longVotes, shortDown, longDown: Int
    public let threshold: Double
    public var shortGap: Int { max(0, required - shortVotes) }
    public var longGap: Int { max(0, required - longVotes) }

    init?(_ evidence: [String: Double]) {
        guard let n = evidence["count"], n >= 1, n.rounded() == n, n <= Double(MarketSnapshot.pool.count),
              let threshold = evidence["threshold"], threshold > 0, threshold <= 1,
              let a = evidence["up60"], let b = evidence["up200"],
              let c = evidence["down60"], let d = evidence["down200"],
              [a,b,c,d].allSatisfy({ (0...1).contains($0) }) else { return nil }
        self.threshold = threshold
        eligible = Int(n)
        required = (1...Int(n)).first { Double($0)/n >= threshold } ?? Int(n)
        shortVotes = Int((a*n).rounded())
        longVotes = Int((b*n).rounded())
        shortDown = Int((c*n).rounded())
        longDown = Int((d*n).rounded())
    }
}

public struct Decision: Codable {
    public let strategy, route, marketState, date: String
    public let selected: [String]
    public let weights, scores, breadth: [String: Double]
    public var sectorStates: [String: String]?
    public var bankStatus: String?
    public var protection: [String]?
    public var exitDrawdown: Double?
    public var headline, rationale: String?
    public var resetHighOnEntry: Bool?
    public var strength: StrengthDistance? { StrengthDistance(breadth) }
}

public struct StrategyEngine {
    public let market: MarketSnapshot, sessions: Sessions
    public let workspace: WorkspaceVersion?
    static let seed = Result { try WorkspaceVersion.bundled() }
    public init(market: MarketSnapshot, sessions: Sessions, workspace: WorkspaceVersion? = nil) {
        self.market=market; self.sessions=sessions; self.workspace=workspace
    }
    public func decision(_ strategy: String,on date: String,previousState: String="UNKNOWN",previousSectors: [String:String]=[:]) throws -> Decision {
        let version = try workspace ?? Self.seed.get()
        return try version.evaluate(strategy,date:date,market:market,sessions:sessions,previous:previousState,sectors:previousSectors)
    }
    func protected(_ d: Decision,_ symbol: String) -> Bool {
        if let allowed = d.protection { return allowed.contains(symbol) }
        guard ["MOM","BANK","GROUP"].contains(d.route), let group = market.securities[symbol]?.group else { return false }
        return d.strategy != "SECTOR_M" || group.hasPrefix("domestic") || group == "overseas_equity"
    }
    func review(_ strategy:String,on date:String) throws -> Bool {
        let v=try workspace ?? Self.seed.get()
        switch v.design.strategies.first(where:{ $0.id == strategy })?.rebalance ?? "monthly" {
        case "daily": return true
        case "weekly":
            let cal=Calendar(identifier:.iso8601), f=ISO8601DateFormatter()
            f.formatOptions=[.withFullDate]
            guard let now=f.date(from:date), let next=f.date(from:try sessions.next(date)) else { throw ResearchError("缺少周末会话") }
            return cal.component(.weekOfYear,from:now) != cal.component(.weekOfYear,from:next)
        default: return try sessions.monthEnd(date)
        }
    }
}

