import CoreFoundation
import Foundation

public struct ParityResult: Codable {
    public let name: String
    public let differences: [String]
    public var onlyOrderDiffers: Bool? = nil
}
public enum Parity {
    static func object(_ value: some Encodable) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }

    private static func differences(_ a: Any?, _ b: Any?, path: [String] = []) -> [String] {
        let field = path.joined(separator: ".")
        if let x = a as? [String: Any], let y = b as? [String: Any] {
            return Set(x.keys).union(y.keys).sorted().flatMap { differences(x[$0], y[$0], path: path + [$0]) }
        }
        if let x = a as? [Any], let y = b as? [Any], x.count == y.count {
            return x.indices.flatMap { differences(x[$0], y[$0], path: path + [String($0)]) }
        }
        if let x = a as? String, let y = b as? String, x == y { return [] }
        if let x = a as? NSNumber, let y = b as? NSNumber {
            if CFGetTypeID(x) == CFBooleanGetTypeID() || CFGetTypeID(y) == CFBooleanGetTypeID() {
                if CFGetTypeID(x) == CFGetTypeID(y) && x.boolValue == y.boolValue { return [] }
            } else {
                let floating = ["scores", "weights", "breadth", "highs", "locks"].contains { path.contains($0) }
                if floating ? abs(x.doubleValue - y.doubleValue) <= 1e-12 : x == y { return [] }
            }
        }
        return ["\(field) · Python \(a.map(String.init(describing:)) ?? "缺失") · Swift \(b.map(String.init(describing:)) ?? "缺失")"]
    }

    public static func run(archive: Archive, workspace:WorkspaceVersion? = nil, progress: (Int, Int) throws -> Void = { _, _ in }) throws -> [ParityResult] {
        try run(market: archive.loadMarket(), originalHash: archive.manifest.snapshot.hash, from: nil, workspace:workspace, progress: progress)
    }

    public static func run(phone: PhoneSnapshot, workspace:WorkspaceVersion? = nil, progress: (Int, Int) throws -> Void = { _, _ in }) throws -> [ParityResult] {
        guard let first=phone.usableFrom else { throw ResearchError("本机行情没有满足预热的可核对区间") }
        return try run(market: phone.market, originalHash: nil, from:first, workspace:workspace, progress: progress)
    }

    private static func run(market: MarketSnapshot, originalHash: String?, from: String?,workspace: WorkspaceVersion?,
                            progress: (Int, Int) throws -> Void) throws -> [ParityResult] {
        guard let references = try JSONSerialization.jsonObject(with:FrozenInputs.data("Reference.json")) as? [String: Any],
              let allCases = references["cases"] as? [[String: Any]], let allTracking = references["tracking"] as? [[String: Any]],
              originalHash == nil || references["snapshot"] as? String == originalHash else {
            throw ResearchError("此快照没有配套的固定 Python 对照样例")
        }
        guard try Integrity.sha(FrozenInputs.data("XSHG.txt")) == references["calendarSHA256"] as? String else {
            throw ResearchError("交易日历与 Python 对照输入不同")
        }
        // The frozen stale-market case requires that the snapshot ends on precisely its original day.
        let cases = allCases.filter { c in
            guard let from, let signal = c["date"] as? String, let requested = c["requested"] as? String else { return true }
            return signal >= from && signal <= market.as_of && (requested == signal || signal == market.as_of)
        }
        let tracking = allTracking.filter { c in
            guard let from, let start = c["start"] as? String, let finish = c["finish"] as? String else { return true }
            return start >= from && finish <= market.as_of
        }
        guard !cases.isEmpty else { throw ResearchError("本机行情日期与冻结的对照用例没有交集") }
        let engine = try StrategyEngine(market: market, sessions: Sessions(), workspace:workspace)
        func account(_ raw: Any) throws -> Account {
            try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: raw))
        }
        var results = [ParityResult]()
        let total = cases.count + tracking.count
        for c in cases {
            try progress(results.count, total)
            let strategy = c["strategy"] as! String, expected = c["expected"] as! [String: Any]
            if let workspace, !workspace.design.strategies.contains(where:{ $0.id == strategy }) {
                results.append(.init(name:"\(c["name"]!) · \(strategy)",differences:["当前工作区未包含此原版策略"]))
                continue
            }
            let r = try engine.advice(strategy, requested: c["requested"] as! String, account: account(c["account"]!))
            let d = r.decision
            var actual: [String: Any] = ["status": r.status, "action": r.action, "next": r.next, "selected": d.selected,
                                         "route": d.route, "state": d.marketState, "breadth": d.breadth,
                                         "weights": d.weights, "scores": d.scores]
            if let p = r.plan { actual["plan"] = try object(p) }
            if let reason = r.reason { actual["reason"] = reason }
            var diffs = differences(expected, actual)
            if d.date != c["date"] as? String { diffs.append("信号日期不一致") }
            if d.strategy != strategy { diffs.append("策略编号不一致") }
            var result=ParityResult(name: "\(c["name"]!) · \(strategy)", differences: diffs)
            if !diffs.isEmpty, d.route == "MV" {
                // Retain the strict order check. Separately identify cases where every security's
                // direction, quantity and cash amount matches, including funded and deferred shares.
                func sortedOrders(_ dict:[String:Any]) -> [String:Any] {
                    var copy=dict
                    if var plan=copy["plan"] as? [String:Any], let rows=plan["orders"] as? [[String:Any]] {
                        plan["orders"]=rows.sorted { ($0["symbol"] as? String ?? "") < ($1["symbol"] as? String ?? "") }
                        copy["plan"]=plan
                    }
                    return copy
                }
                result.onlyOrderDiffers=differences(sortedOrders(expected),sortedOrders(actual)).isEmpty
            }
            results.append(result)
        }
        for c in tracking {
            try progress(results.count, total)
            if let workspace, !workspace.design.strategies.contains(where:{ $0.id == "MOM20" }) {
                results.append(.init(name:c["name"] as! String,differences:["当前工作区未包含用于该跟踪样例的 MOM20"]))
                continue
            }
            let prior = try engine.begin("MOM20", account: account(c["startAccount"]!))
            let final = try engine.advance(prior, account: account(c["endAccount"]!))
            let actual: [String: Any] = ["highs": final.highs, "locks": try object(final.locks),
                                         "quantities": final.quantities, "selection": final.selection]
            let expected = c.filter { actual.keys.contains($0.key) }
            results.append(.init(name: c["name"] as! String, differences: differences(expected, actual)))
        }
        try progress(total, total)
        return results
    }
}
