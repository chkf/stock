import CryptoKit
import Foundation
import ResearchCore
import Security

private final class PinDelegate: NSObject, URLSessionTaskDelegate {
    let code: PairCode
    init(_ code: PairCode) { self.code = code }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, space.host == code.host,
              space.port == code.port, let trust = space.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let bytes = SecCertificateCopyData(leaf) as Data
        guard Data(SHA256.hash(data: bytes).prefix(16)) == code.pin else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum LANTransfer {
    static func receive(code text: String, vault: PrivateLibrary,
                        progress: @escaping (TransferProgress) -> Void) async throws -> Archive {
        let code = try PairCode(text)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 35
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        let session = URLSession(configuration: config, delegate: PinDelegate(code), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let base = URL(string: "https://\(code.host):\(code.port)")!
        func request(_ path: String, _ token: String?, _ body: Data?) async throws -> Data {
            var req = URLRequest(url: base.appendingPathComponent(path))
            req.cachePolicy = .reloadIgnoringLocalCacheData
            if let token { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            if let body { req.httpMethod = "POST"; req.httpBody = body }
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ResearchError("配对码已使用、已过期或电脑端资料不可用。重新启动直传可续传。")
            }
            return data
        }
        return try await PeerSession.receive(code: code, into: vault, request: request, progress: progress)
    }
}
