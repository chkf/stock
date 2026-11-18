import Foundation

public struct PairCode {
    public let host: String
    public let port: Int
    public let pin: Data
    private let secret: Data
    var proof: Data { Data(secret.map { String(format: "%02x", $0) }.joined().utf8) }

    public init(_ text: String) throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard clean.hasPrefix("SR1-") else { throw ResearchError("请输入电脑显示的完整 SR1 配对码") }
        let digits = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        let encoded = clean.dropFirst(4).filter { $0 != "-" && !$0.isWhitespace }
        var result = [UInt8](), value = 0, bits = 0
        guard encoded.count == 61 else { throw ResearchError("配对码长度错误") }
        for byte in encoded.utf8 {
            guard let d = digits.firstIndex(of: byte) else { throw ResearchError("配对码字符无效") }
            value = (value << 5) | d
            bits += 5
            if bits >= 8 {
                bits -= 8
                result.append(UInt8(value >> bits))
                value &= (1 << bits) - 1
            }
        }
        guard result.count == 38, value == 0 else { throw ResearchError("配对码末位错误") }
        let a = result[0], b = result[1]
        guard a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) ||
              (a == 169 && b == 254) || a == 127 else { throw ResearchError("配对码中的地址不属于局域网") }
        host = result[0..<4].map(String.init).joined(separator: ".")
        port = Int(result[4]) * 256 + Int(result[5])
        guard port > 0 else { throw ResearchError("配对码端口无效") }
        pin = Data(result[6..<22])
        secret = Data(result[22..<38])
    }
}

public enum PeerSession {
    private struct Ticket: Decodable { let token, id: String }
    public typealias Request = (String, String?, Data?) async throws -> Data

    // The caller's HTTPS transport must verify the leaf pin before sending any request.
    public static func receive(code: PairCode, into vault: PrivateLibrary, request: @escaping Request,
                               progress: @escaping (TransferProgress) -> Void) async throws -> Archive {
        let result = try await request("pair", nil, code.proof)
        let ticket = try JSONDecoder().decode(Ticket.self, from: result)
        guard Integrity.digestID(ticket.token), Integrity.digestID(ticket.id) else { throw ResearchError("电脑配对响应异常") }
        let manifest = try await request("manifest", ticket.token, nil)
        return try await vault.receive(manifest: manifest, id: ticket.id, fetch: { index in
            try await request("chunk/\(index)", ticket.token, nil)
        }, progress: progress)
    }
}
