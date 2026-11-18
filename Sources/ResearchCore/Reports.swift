import Foundation

public struct SavedAdvice: Codable, Identifiable {
    public let id: UUID
    public let created: Date
    public let snapshot, requested: String
    public let capital: Double
    public let actualAccount: Bool?
    public let accountID: String?
    public let workspaceID: String?
    public let result: Advice
    public init(snapshot: String, requested: String, capital: Double, result: Advice, actualAccount: Bool = false, accountID: String? = nil, workspaceID: String? = nil) {
        self.id = UUID(); self.created = Date(); self.snapshot = snapshot
        self.requested = requested; self.capital = capital; self.result = result; self.actualAccount = actualAccount; self.accountID = accountID
        self.workspaceID = workspaceID
    }
}

extension PrivateLibrary {
    public func saveReport(_ report: SavedAdvice) throws {
        let dir = root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(report).write(to: dir.appendingPathComponent(report.id.uuidString + ".json"), options: .atomic)
    }
    public func reports() throws -> [SavedAdvice] {
        let dir = root.appendingPathComponent("reports")
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(SavedAdvice.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created > $1.created }
    }
}
