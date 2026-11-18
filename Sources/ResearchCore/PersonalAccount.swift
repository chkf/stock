import Foundation

public enum AccountInput {
    static func encoded(_ account: Account) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(account)
    }
    public static func identity(_ account: Account) throws -> String { try Integrity.sha(encoded(account)) }
    public static func symbol(_ input: String) throws -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var prefix = "", suffix = ""
        if let exchange = ["SH", "SZ", "BJ"].first(where: { s.hasPrefix($0) }) {
            prefix = exchange
            s.removeFirst(2)
        }
        let parts = s.components(separatedBy: ".")
        if parts.count == 2 { suffix = parts[1] }
        guard parts.count <= 2, (parts.count == 1 || !suffix.isEmpty), let code = parts.first,
              code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw ResearchError("请输入六位代码或代码.市场")
        }
        let markets = [("SH", ["60", "68", "51", "52", "56", "58"]), ("SZ", ["00", "30", "159"]), ("BJ", ["43", "83", "87", "88", "92"])]
        guard let exchange = markets.first(where: { $0.1.contains(where: { code.hasPrefix($0) }) })?.0,
              (prefix.isEmpty || prefix == exchange), (suffix.isEmpty || suffix == exchange) else {
            throw ResearchError("代码或交易所后缀不符合原版证券范围")
        }
        return "\(code).\(exchange)"
    }
    static func validDate(_ date: String) -> Bool {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f.date(from: date).map { f.string(from: $0) == date } ?? false
    }
}

extension PrivateLibrary {
    private struct AccountPointer: Codable { let schema, sha256: String }
    public struct PersonalRecord: Identifiable {
        public let id: String
        public let account: Account
    }
    public func personalRecord(id: String) throws -> Account {
        guard Integrity.digestID(id) else { throw ResearchError("账户版本编号无效") }
        let bytes = try Data(contentsOf: root.appendingPathComponent("personal/accounts/\(id).json"))
        guard Integrity.sha(bytes) == id else { throw ResearchError("本机账户校验失败，原记录已保留") }
        let account = try JSONDecoder().decode(Account.self, from: bytes)
        try account.validate()
        guard account.confirmed else { throw ResearchError("账户记录缺少确认") }
        return account
    }
    public func personalHistory() throws -> [PersonalRecord] {
        let folder = root.appendingPathComponent("personal/accounts")
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return try urls.filter { $0.pathExtension == "json" && $0.lastPathComponent != "current.json" }.map {
            let id = $0.deletingPathExtension().lastPathComponent
            return PersonalRecord(id: id, account: try personalRecord(id: id))
        }.sorted { a, b in a.account.as_of == b.account.as_of ? a.id < b.id : a.account.as_of > b.account.as_of }
    }
    public func personalAccount() throws -> Account? {
        let folder = root.appendingPathComponent("personal/accounts")
        let pointer = folder.appendingPathComponent("current.json")
        guard FileManager.default.fileExists(atPath: pointer.path) else { return nil }
        let ref = try JSONDecoder().decode(AccountPointer.self, from: Data(contentsOf: pointer))
        guard ref.schema == "iphone-account-1", Integrity.digestID(ref.sha256) else { throw ResearchError("本机账户指针无效") }
        return try personalRecord(id: ref.sha256)
    }
    public func savePersonal(_ account: Account, now: Date = Date()) throws {
        try account.validate()
        guard account.confirmed, account.as_of <= (try Sessions().completed(now: now)) else {
            throw ResearchError("请确认账户，日期不能晚于最近已完成收盘")
        }
        let folder = root.appendingPathComponent("personal/accounts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let normalized = Account(date: account.as_of, cash: account.cash, positions: account.positions.filter { $0.quantity > 0 },
                                 confirmed: true, fees: account.fees)
        let bytes = try AccountInput.encoded(normalized), id = Integrity.sha(bytes)
        try bytes.write(to: folder.appendingPathComponent(id + ".json"), options: .atomic)
        let ref = AccountPointer(schema: "iphone-account-1", sha256: id)
        try encoder.encode(ref).write(to: folder.appendingPathComponent("current.json"), options: .atomic)
    }
}
