import Foundation

struct HistoryFetchPause:LocalizedError {
    let errorDescription:String?
}
struct HistoryHTTPFailure:LocalizedError {
    let status:Int?, responseURL:URL?, bytes:Data
    let errorDescription:String?
}
final class HistoryWriters:@unchecked Sendable {
    static let shared=HistoryWriters()
    private let lock=NSLock()
    private var roots=Set<String>()
    func claim(_ root:URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard roots.insert(root.standardizedFileURL.resolvingSymlinksInPath().path).inserted else { throw ResearchError("另一个任务正在更改本机行情") }
    }
    func release(_ root:URL) {
        lock.lock(); defer { lock.unlock() }
        roots.remove(root.standardizedFileURL.resolvingSymlinksInPath().path)
    }
}
/// Journaled candidates are separate from the single published current pointer.
struct HistoryCandidate {
    static let parser="raw-etf-pages-2"
    struct Capture:Codable {
        let url,path,sha256,fetched,parser,rules:String
        let bytes:Int
        let error:String?
        var httpStatus:Int?, responseURL:String?
    }
    struct Journal:Codable {
        let id:String, parent:String?, from,through,rules:String
        var requests=[String:Capture](), attempts=[Capture](), status="collecting", reason=""
        var blockers:[String:String]?
    }
    let root,folder,journalURL:URL
    var journal:Journal
    var sources:[String:String] { Dictionary(uniqueKeysWithValues:journal.requests.values.map { ($0.path,$0.sha256) }) }
    init(root:URL,parent:String?,from:String,through:String,rules:String) throws {
        self.root=root
        let key=Integrity.sha(Data([Self.parser,parent ?? "",from,through,rules].joined(separator:"|").utf8))
        let refs=root.appendingPathComponent("candidates")
        try FileManager.default.createDirectory(at:refs,withIntermediateDirectories:true)
        journalURL=refs.appendingPathComponent(key+".json")
        if FileManager.default.fileExists(atPath:journalURL.path) {
            journal=try JSONDecoder().decode(Journal.self,from:Data(contentsOf:journalURL))
            guard UUID(uuidString:journal.id) != nil, journal.parent==parent,journal.from==from,journal.through==through,journal.rules==rules else { throw ResearchError("候选断点与请求不一致") }
            if ["refused","accepted"].contains(journal.status) {
                journal = .init(id:UUID().uuidString,parent:parent,from:from,through:through,rules:rules)
            }
        } else { journal = .init(id:UUID().uuidString,parent:parent,from:from,through:through,rules:rules) }
        folder=root.appendingPathComponent("captures/"+journal.id)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try save()
    }
    func save() throws { let e=JSONEncoder(); e.outputFormatting=[.sortedKeys]; try e.encode(journal).write(to:journalURL,options:.atomic) }
    mutating func capture(_ url:URL,name:String,fetch:(URL) async throws->Data,validate:(Data)throws->Void) async throws -> Data {
        let key=url.absoluteString
        if let c=journal.requests[key] {
            guard c.path=="captures/"+journal.id+"/"+name, c.parser==Self.parser, c.rules==journal.rules else { throw ResearchError("候选原件路径或版本不符") }
            let bytes=try Data(contentsOf:folder.appendingPathComponent(name))
            guard bytes.count==c.bytes, Integrity.sha(bytes)==c.sha256 else { throw ResearchError("候选原件损坏 "+name) }
            try validate(bytes); return bytes
        }
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let raw=try await fetch(url)
                try Task.checkCancellation()
                guard !raw.isEmpty,raw.count<=8*1024*1024 else { throw ResearchError("行情原响应为空或过大") }
                let hash=Integrity.sha(raw), time=ISO8601DateFormatter().string(from:Date())
                let reason:String?
                do { try validate(raw); reason=nil } catch { reason=error.localizedDescription }
                let file=reason==nil ? name : "rejected-"+hash+"-"+name
                try raw.write(to:folder.appendingPathComponent(file),options:.atomic)
                let c=Capture(url:key,path:"captures/"+journal.id+"/"+file,sha256:hash,fetched:time,parser:Self.parser,rules:journal.rules,bytes:raw.count,error:reason,httpStatus:200,responseURL:key)
                journal.attempts.append(c)
                if reason==nil { journal.requests[key]=c }
                try save()
                if let reason { throw ResearchError(reason) }
                return raw
            } catch {
                if error is CancellationError { throw CancellationError() }
                try Task.checkCancellation()
                if let http=error as? HistoryHTTPFailure {
                    let hash=Integrity.sha(http.bytes), filename="http-"+hash+"-"+name
                    try http.bytes.write(to:folder.appendingPathComponent(filename),options:.atomic)
                    journal.attempts.append(.init(url:key,path:"captures/"+journal.id+"/"+filename,sha256:hash,fetched:ISO8601DateFormatter().string(from:Date()),parser:Self.parser,rules:journal.rules,bytes:http.bytes.count,error:http.localizedDescription,httpStatus:http.status,responseURL:http.responseURL?.absoluteString))
                    try save()
                }
                if attempt==2 {
                    let message="\(name) \(url.host ?? "") · \(error.localizedDescription)"
                    if error is URLError || (error as? HistoryHTTPFailure)?.status.map({ $0==429 || $0>=500 })==true {
                        throw HistoryFetchPause(errorDescription:message)
                    }
                    throw ResearchError(message)
                }
                try await Task.sleep(nanoseconds:UInt64(attempt+1)*200_000_000)
            }
        }
        throw ResearchError("候选请求未完成")
    }
    mutating func record(_ status:String, reason:String="") throws -> (String,String) {
        journal.status=status; journal.reason=reason; try save()
        let enc=JSONEncoder();enc.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let bytes=try enc.encode(journal), name="capture.json"
        try bytes.write(to:folder.appendingPathComponent(name),options:.atomic)
        return ("captures/"+journal.id+"/"+name,Integrity.sha(bytes))
    }
}

struct ReviewInput:Decodable {
    let review:HistoryReview
    let sources:[String:String]
    /// Explicitly supplied review. Users keep raw notices with it under their own Files workspace.
    static func read(_ input:URL, into marketRoot:URL) throws -> Self? {
        let manifest=input.appendingPathComponent("审核.json"), fm=FileManager.default
        guard fm.fileExists(atPath:manifest.path) else { return nil }
        let v=try JSONDecoder().decode(Self.self,from:Data(contentsOf:manifest))
        for (path,hash) in v.sources {
            let parts=path.components(separatedBy:"/")
            guard parts.count==3,parts[0]=="review",parts[1]==hash,Integrity.digestID(hash),
                  !parts[2].isEmpty,!parts[2].hasPrefix("."),!parts[2].contains("\\"),!parts[2].contains(":") else { throw ResearchError("审核原件的相对路径不符 "+path) }
            let file=input.appendingPathComponent(path).resolvingSymlinksInPath()
            guard file.path.hasPrefix(input.resolvingSymlinksInPath().path+"/") else { throw ResearchError("审核原件路径越界") }
            let bytes=try Data(contentsOf:file)
            guard Integrity.sha(bytes)==hash else { throw ResearchError("审核原件摘要不符 "+path) }
            let dest=marketRoot.appendingPathComponent(path)
            try fm.createDirectory(at:dest.deletingLastPathComponent(),withIntermediateDirectories:true)
            if fm.fileExists(atPath:dest.path) { guard try Data(contentsOf:dest)==bytes else { throw ResearchError("现有审核原件损坏 "+path) } }
            else { try bytes.write(to:dest,options:.atomic) }
        }
        try v.review.validate(sources:v.sources,calendar:Sessions())
        try v.review.verifyEvidence(sources:v.sources) { try Data(contentsOf:marketRoot.appendingPathComponent($0)) }
        return v
    }
}
