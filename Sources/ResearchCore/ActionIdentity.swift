import Foundation

// The Python store hashes json.dumps(events, sort_keys=True, ensure_ascii=False),
// including its spaces and its distinction between 1 and 1.0. Original files were
// emitted by the same Python encoder. Preserve their scalar tokens byte-for-byte.
enum ActionIdentity {
    private indirect enum Value {
        case scalar(String), array([Value]), object([String: Value])
        func sortedPythonJSON() -> String {
            switch self {
            case .scalar(let text): return text
            case .array(let items): return "[" + items.map { $0.sortedPythonJSON() }.joined(separator: ", ") + "]"
            case .object(let fields):
                return "{" + fields.keys.sorted().map { $0 + ": " + fields[$0]!.sortedPythonJSON() }.joined(separator: ", ") + "}"
            }
        }
    }
    private struct Reader {
        let bytes: [UInt8]
        var i = 0
        private mutating func skip() {
            while i < bytes.count, [9, 10, 13, 32].contains(bytes[i]) { i += 1 }
        }
        private mutating func take(_ c: UInt8) -> Bool {
            skip()
            guard i < bytes.count, bytes[i] == c else { return false }
            i += 1
            return true
        }
        mutating func value(depth: Int = 0) throws -> Value {
            skip()
            guard depth < 64, i < bytes.count else { throw ResearchError("公司行动 JSON 结构异常") }
            if take(123) {
                var fields = [String: Value]()
                if take(125) { return .object(fields) }
                repeat {
                    guard case .scalar(let key) = try value(depth: depth + 1), key.first == "\"",
                          fields[key] == nil, take(58) else { throw ResearchError("公司行动 JSON 字段无效") }
                    fields[key] = try value(depth: depth + 1)
                } while take(44)
                guard take(125) else { throw ResearchError("公司行动 JSON 对象被截断") }
                return .object(fields)
            }
            if take(91) {
                var items = [Value]()
                if take(93) { return .array(items) }
                repeat { items.append(try value(depth: depth + 1)) } while take(44)
                guard take(93) else { throw ResearchError("公司行动 JSON 数组被截断") }
                return .array(items)
            }
            let start = i
            if take(34) {
                while i < bytes.count {
                    let c = bytes[i]; i += 1
                    if c == 34 { return .scalar(String(decoding: bytes[start..<i], as: UTF8.self)) }
                    if c == 92 { i += 1 }
                }
                throw ResearchError("公司行动 JSON 字符串被截断")
            }
            while i < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[i]) { i += 1 }
            guard i > start else { throw ResearchError("公司行动数值缺失") }
            return .scalar(String(decoding: bytes[start..<i], as: UTF8.self))
        }
    }
    static func verify(_ data: Data, filenameID: String?) throws {
        struct Header: Decodable { let source, snapshot: String }
        let header = try JSONDecoder().decode(Header.self, from: data)
        var r = Reader(bytes: Array(data))
        guard case .object(let root) = try r.value(), let events = root["\"events\""], !header.source.isEmpty,
              filenameID == nil || filenameID == header.snapshot,
              Integrity.sha(Data(events.sortedPythonJSON().utf8)) == header.snapshot else {
            throw ResearchError("公司行动内容与原版快照编号不符")
        }
    }
}
