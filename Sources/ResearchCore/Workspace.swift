import Foundation
import CWorkspaceJS

public struct StrategyFile: Codable, Identifiable, Hashable {
    public let id, title, short, file: String
    public let history: Int
    public let rebalance: String?
    public var requirements:UniverseRequirements?
}
public struct UniverseRequirements: Codable, Hashable {
    public let contract, screenHistory:Int
    public let insufficient:String
    public var config:String?
}
public struct StudySettings: Codable {
    public let capital, commissionRate, minimumCommission, slippageRate, rebalanceBand: Double
    static let original = Self(capital:50_000,commissionRate:0.0003,minimumCommission:5,slippageRate:0.0005,rebalanceBand:0.03)
    var valid:Bool { (1...100_000_000).contains(capital) && (0...0.01).contains(commissionRate) &&
        (0...100).contains(minimumCommission) && (0...0.02).contains(slippageRate) && (0..<1).contains(rebalanceBand) }
}
public struct ScreenBlock: Codable {
    public let type: String
    public let text, target, key: String?
    public let blocks: [ScreenBlock]?
}
public struct FilePage: Codable {
    public let title, icon: String
    public let tab: String?
    public let blocks: [ScreenBlock]
}
public struct WorkspaceDesign: Codable {
    public let schema: Int
    public let title, library: String
    public let tabs: [String], pages: [String: String], strategies: [StrategyFile], actions: [String: String]
    public let study: StudySettings?
}
public struct WorkspaceVersion {
    public let hash: String, design: WorkspaceDesign, pages: [String: FilePage]
    private let files: [String: Data]
    private let library: String
    static let widgets = Set(["strategyPicker","decision","strength","outlook","marketUpdate","quotes","account","replay",
                              "archiveLink","title","text","link","field","dateField","button","result","reload","row","stack","group","divider",
                              "command","accountBalance","holdings","watchRows","etfRows","studyChart","job","nativeLink"])
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 80 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,95].contains($0) }
    }
    private static func path(_ name: String, ext: String) throws -> String {
        let parts = name.components(separatedBy: "/")
        guard !name.contains("\\"), !name.contains(":"), !name.contains("\0"), name.utf8.count < 350,
              parts.count <= 4, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }), name.hasSuffix("."+ext)
        else { throw ResearchError("工作区路径无效 \(name)") }
        return name
    }
    static func read(_ url: URL, under root: URL, limit: Int) throws -> Data {
        let p = url.resolvingSymlinksInPath()
        guard p.path.hasPrefix(root.resolvingSymlinksInPath().path+"/"), try p.resourceValues(forKeys: [.isRegularFileKey,.fileSizeKey]).isRegularFile == true,
              try (p.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= limit else { throw ResearchError("工作区文件位置或大小异常 \(url.lastPathComponent)") }
        return try Data(contentsOf: p)
    }
    public static func bundled() throws -> Self {
        guard let root = Bundle.module.url(forResource:"WorkspaceSeed",withExtension:nil) else { throw ResearchError("缺少初始工作区") }
        return try load(from: root)
    }
    public static func load(from root: URL) throws -> Self {
        let m = try read(root.appendingPathComponent("workspace.json"),under: root,limit: 256*1024)
        let design = try JSONDecoder().decode(WorkspaceDesign.self,from: m)
        guard design.schema == 1, design.study?.valid ?? true, (1...5).contains(design.tabs.count), Set(design.tabs).count == design.tabs.count,
              design.pages.count <= 100, !design.strategies.isEmpty, design.strategies.count <= 64, design.actions.count <= 100,
              Set(design.strategies.map(\.id)).count == design.strategies.count, design.tabs.allSatisfy({ design.pages[$0] != nil }),
              (Array(design.pages.keys)+Array(design.actions.keys)+design.strategies.map(\.id)).allSatisfy(validID)
        else { throw ResearchError("workspace.json 中的版本、页面或策略编号无效") }
        var files = ["workspace.json":m], pages = [String:FilePage]()
        func file(_ name: String, _ ext: String) throws -> Data {
            let key = try path(name,ext:ext)
            if let known = files[key] { return known }
            do { let d = try read(root.appendingPathComponent(key),under: root,limit: 512*1024); files[key]=d; return d }
            catch { throw ResearchError("\(key) · \(error.localizedDescription)") }
        }
        func script(_ name: String) throws -> String {
            guard let s = String(data:try file(name,"js"),encoding:.utf8), !s.contains("\0") else { throw ResearchError("\(name) 需要 UTF-8 文本") }
            return s
        }
        for (id,name) in design.pages {
            let page: FilePage
            do { page = try JSONDecoder().decode(FilePage.self,from:file(name,"json")) } catch { throw ResearchError("\(name) · \(error.localizedDescription)") }
            var count = 0
            func valid(_ block: ScreenBlock, _ depth: Int) -> Bool {
                count += 1
                guard widgets.contains(block.type), depth < 12, count <= 200 else { return false }
                if ["row","stack","group"].contains(block.type) {
                    guard let children=block.blocks, !children.isEmpty else { return false }
                    return children.allSatisfy { valid($0,depth+1) }
                }
                if block.blocks != nil { return false }
                switch block.type {
                case "link": return design.pages[block.target ?? ""] != nil
                case "button","result": return design.actions[block.target ?? ""] != nil
                case "field": return validID(block.key ?? "")
                case "dateField": return ["replayStart","replayEnd"].contains(block.key ?? "")
                case "command": return ["watch.add","market.refresh","study.run","job.cancel"].contains(block.target ?? "")
                case "nativeLink": return ["account.edit","account.history","account.plan","reports","archive"].contains(block.target ?? "")
                default: return true
                }
            }
            guard !page.blocks.isEmpty, page.blocks.allSatisfy({ valid($0,0) }) else { throw ResearchError("\(name) 有未登记的组件、页面或功能") }
            pages[id] = page
        }
        let library = try script(design.library)
        for s in design.strategies {
            if let req=s.requirements {
                guard req.contract==2,req.screenHistory>=1,req.screenHistory<=s.history,["cash","error"].contains(req.insufficient) else { throw ResearchError("\(s.id) 目录契约或筛选窗口无效") }
                if let config=req.config { _=try Self.strategyConfig(file(config,"json"),on:"9999-12-31") }
                _=try execute(library+"\n"+script(s.file)+"\n;globalThis.run=screen;",file:s.file,input:Data(),check:true)
            }
            guard (1...6000).contains(s.history), !s.title.isEmpty, ["daily","weekly","monthly"].contains(s.rebalance ?? "monthly") else { throw ResearchError("\(s.id) 历史窗口、名称或换仓频率无效") }
            _ = try execute(library+"\n"+script(s.file),file:s.file,input:Data(),check:true)
        }
        for name in design.actions.values { _ = try execute(script(name),file:name,input:Data(),check:true) }
        guard files.values.reduce(0,{ $0+$1.count }) <= 12*1024*1024 else { throw ResearchError("工作区设计超过 12 MB") }
        let fingerprint = files.keys.sorted().map { "\($0.utf8.count) \($0) \(Integrity.sha(files[$0]!))\n" }.joined()
        return Self(hash:Integrity.sha(Data(fingerprint.utf8)),design:design,pages:pages,files:files,library:library)
    }
    static func execute(_ code: String,file: String,input: Data,check: Bool = false) throws -> Data {
        guard let arg = String(data:input,encoding:.utf8), !arg.contains("\0") else { throw ResearchError("功能输入格式无效") }
        var raw: UnsafeMutablePointer<CChar>?
        let status = sws_run(code,file,arg,check ? 1 : 0,&raw)
        defer { if let raw { sws_free(raw) } }
        if status != 0 { throw ResearchError("\(file) · "+(raw.map { String(cString:$0) } ?? "运行失败")) }
        if check { return Data() }
        guard let raw else { throw ResearchError("\(file) 没有返回可用结果") }
        return Data(String(cString:raw).utf8)
    }
    public func action(_ id: String,input: Data) throws -> Data {
        guard let file = design.actions[id], let data = files[file] else { throw ResearchError("未知工作区功能") }
        return try Self.execute(String(decoding:data,as:UTF8.self),file:file,input:input)
    }
    func evaluate(_ id: String, date: String, market: MarketSnapshot,sessions: Sessions,previous: String,sectors: [String:String]) throws -> Decision {
        guard date <= market.as_of, let s = design.strategies.first(where: { $0.id == id }), let program = files[s.file] else { throw ResearchError("策略或行情日期无效") }
        if let req=s.requirements {
            return try universeDecision(s,req:req,market:market,calendar:sessions,date:date,previous:previous,sectors:sectors,
                code:library+"\n"+String(decoding:program,as:UTF8.self),config:req.config.flatMap { files[$0] })
        }
        guard !market.isUniverse,market.schema != UniverseManifest.format else { throw ResearchError("旧策略需要固定池行情，请选择契约 2 策略") }
        let last = try sessions.index(date), days = Array(sessions.days[max(0,last-s.history+1)...last])
        struct Security: Encodable { let name,group: String; let close: [Double?] }
        struct Input: Encodable {
            let strategy,date,previousState: String; let previousSectors: [String:String], dates: [String], securities: [String:Security]
        }
        let inputs = market.securities.mapValues { sec in Security(name:sec.name,group:sec.group,close:days.map { sec.signal_close[$0] }) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Input(strategy:id,date:date,previousState:previous,previousSectors:sectors,dates:days,securities:inputs))
        let raw = try Self.execute(library+"\n"+String(decoding:program,as:UTF8.self),file:s.file,input:data)
        let d = try JSONDecoder().decode(Decision.self,from:raw)
        guard d.date == date, d.strategy == id, d.weights.keys.allSatisfy({ inputs[$0] != nil }),
              d.weights.values.allSatisfy({ $0.isFinite && $0 >= 0 }), d.weights.values.reduce(0,+) <= 1.0000000001,
              Set(d.selected).count == d.selected.count, d.selected.allSatisfy({ inputs[$0] != nil }),
              (d.protection ?? []).allSatisfy({ inputs[$0] != nil }),
              (d.exitDrawdown ?? 0.2) > 0, (d.exitDrawdown ?? 0.2) <= 1
        else { throw ResearchError("\(s.file) 返回的日期、标的、止损或权重无效") }
        return d
    }
    func save(at dir: URL) throws {
        let fm = FileManager.default
        for (path,bytes) in files {
            let dest = dir.appendingPathComponent(path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(),withIntermediateDirectories:true)
            try bytes.write(to:dest,options:.atomic)
        }
    }
}

public struct WorkspaceRequest: Decodable {
    public let id, operation: String
    public let target: String?
    public let fields: [String:String]?
}

public struct WorkspaceTicket {
    public let request: WorkspaceRequest
    public let digest: String
}

public struct WorkspaceStore {
    public let root: URL
    public init(root: URL) { self.root=root }
    public var working: URL { root.appendingPathComponent("设计",isDirectory:true) }
    private var versions: URL { root.appendingPathComponent("版本",isDirectory:true) }
    private var pointer: URL { versions.appendingPathComponent("current.json") }
    private var replyFile: URL { root.appendingPathComponent("输出/请求状态.json") }
    private struct Reply: Codable { let digest,id,status,message,time:String; var process:String?, fraction:Double?, resultPath:String? }
    private static let process=UUID().uuidString
    public func performReplay(_ ticket:WorkspaceTicket,workspace:WorkspaceVersion,library:PrivateLibrary,phone:PhoneSnapshot?,catalog:PhoneSnapshot?,archive:MarketSnapshot?,archiveID:String?,progress:(ReplayReport,Double)->Void = { _,_ in }) throws {
        let request=ticket.request,fields=request.fields ?? [:]
        guard request.operation=="replay",let target=request.target,let definition=workspace.design.strategies.first(where:{ $0.id==target }),
              let from=fields["start"],let end=fields["end"],let source=fields["marketOrigin"],Set(fields.keys)==Set(["start","end","marketOrigin"]) else { throw ResearchError("replay 需要有效策略、start、end、marketOrigin") }
        let market:MarketSnapshot?,id:String?
        switch source {
        case "phone": let snapshot=definition.requirements==nil ? phone:catalog; market=snapshot?.market; id=snapshot?.hash
        case "archive": market=archive; id=archiveID
        default: throw ResearchError("未知回测来源")
        }
        guard let market,let id else { throw ResearchError("正式回测行情尚未载入") }
        try replayStatus(ticket,status:"running",message:"核验区间",fraction:0)
        let result=try library.formalReplay(market:market,id:id,workspace:workspace,strategy:target,start:from,end:end) { state,value in
            try replayStatus(ticket,status:"running",message:state.outcomeDate,fraction:value);progress(state,value)
        }
        guard result.finished else { throw ResearchError("回测未完成") }
        let path=try library.replayURL(snapshot:result.snapshot,strategy:target,start:from,end:end)
        guard path.path.hasPrefix(root.path+"/") else { throw ResearchError("结果不在当前工作区") }
        try replayStatus(ticket,status:"done",message:"正式结果已保存",fraction:1,resultPath:String(path.path.dropFirst(root.path.count+1)))
    }
    private func jobPath(_ id:String) -> URL { root.appendingPathComponent("输出/回测请求/"+id+".json") }
    public func replayStatus(_ ticket:WorkspaceTicket,status:String,message:String,fraction:Double?=nil,resultPath:String?=nil) throws {
        let record=Reply(digest:ticket.digest,id:ticket.request.id,status:status,message:message,time:ISO8601DateFormatter().string(from:Date()),process:Self.process,fraction:fraction,resultPath:resultPath)
        let bytes=try JSONEncoder().encode(record)
        let path=jobPath(record.id)
        if status=="accepted" {
            try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
            try bytes.write(to:path,options:.withoutOverwriting)
        } else { try bytes.write(to:path,options:.atomic) }
        try bytes.write(to:replyFile,options:.atomic)
    }
    private func reply(digest:String,id:String,ok:Bool,message:String) throws {
        let reply = Reply(digest:digest,id:id,status:ok ? "done" : "error",message:message,time:ISO8601DateFormatter().string(from:Date()))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(reply).write(to:replyFile,options:.atomic)
    }
    public func finish(_ ticket:WorkspaceTicket,ok:Bool,message:String) throws {
        if ticket.request.operation=="replay" { if !ok { try replayStatus(ticket,status:"failed",message:message) }; return }
        try reply(digest:ticket.digest,id:ticket.request.id,ok:ok,message:message)
    }
    public func nextRequest() throws -> WorkspaceTicket? {
        let url = root.appendingPathComponent("请求.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        let data = try WorkspaceVersion.read(url,under:root,limit:64*1024)
        let digest = Integrity.sha(data)
        if let bytes = try? Data(contentsOf:replyFile), let previous = try? JSONDecoder().decode(Reply.self,from:bytes), previous.digest == digest, !["accepted","running"].contains(previous.status) { return nil }
        var id = ""
        do {
            let request = try JSONDecoder().decode(WorkspaceRequest.self,from:data)
            id = request.id
            guard WorkspaceVersion.validID(id), ["reload","run","strategy","catalog","quotes","replay"].contains(request.operation),
                  request.operation == "reload" || WorkspaceVersion.validID(request.target ?? ""),
                  request.fields?.count ?? 0 <= 64, request.fields?.allSatisfy({ WorkspaceVersion.validID($0.key) && $0.value.utf8.count <= 4096 }) ?? true
            else { throw ResearchError("请求需要有效的 id、operation 和 target") }
            let ticket=WorkspaceTicket(request:request,digest:digest)
            if request.operation=="replay" {
                if FileManager.default.fileExists(atPath:jobPath(id).path) {
                    let old=try JSONDecoder().decode(Reply.self,from:Data(contentsOf:jobPath(id)))
                    guard old.digest==digest else { throw ResearchError("回测请求 ID 已使用，请使用新 ID") }
                    if old.process != Self.process && ["accepted","running"].contains(old.status) { try replayStatus(ticket,status:"interrupted",message:"上次进程中断；用新 ID 继续匹配的检查点") }
                    return nil
                }
                try replayStatus(ticket,status:"accepted",message:"已受理，尚未完成")
            }
            return ticket
        } catch {
            try reply(digest:digest,id:id,ok:false,message:error.localizedDescription)
            return nil
        }
    }
    public func logActivation(active:String,message:String,successful:Bool) throws {
        let record:[String:Any]=["active":active,"message":message,"ok":successful,"time":ISO8601DateFormatter().string(from:Date())]
        try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("输出/工作区状态.json"),options:.atomic)
    }
    public func writeDecision(_ d:Decision,market:MarketSnapshot,snapshotID:String,version:String,next:String,current:String) throws {
        guard WorkspaceVersion.validID(d.strategy) else { throw ResearchError("策略标识无效") }
        struct Rank: Encodable { let symbol,name:String; let target:Double; let score:Double? }
        struct Result: Encodable {
            let snapshot,workspace,nextSession,latestCompleted:String
            let stale:Bool; let decision:Decision; let ranking:[Rank]
        }
        let symbols=market.securities.keys.filter { market.universe?.listings[$0]?.active(d.date) ?? true }
        let rows=symbols.sorted { a,b in
            let x=d.weights[a] ?? 0,y=d.weights[b] ?? 0
            if x != y { return x>y }
            let sx=d.scores[a] ?? -.infinity,sy=d.scores[b] ?? -.infinity
            return sx == sy ? a<b : sx>sy
        }.map { Rank(symbol:$0,name:market.universe?.listings[$0]?.metadata(on:d.date)?.name ?? market.securities[$0]!.name,target:d.weights[$0] ?? 0,score:d.scores[$0]) }
        let file=root.appendingPathComponent("输出/市场判断",isDirectory:true)
        try FileManager.default.createDirectory(at:file,withIntermediateDirectories:true)
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys,.prettyPrinted,.withoutEscapingSlashes]
        try encoder.encode(Result(snapshot:snapshotID,workspace:version,nextSession:next,latestCompleted:current,stale:d.date<current,decision:d,ranking:rows))
            .write(to:file.appendingPathComponent(d.strategy+".json"),options:.atomic)
    }
    private struct Receipt: Codable { let active: String; let previous: String? }
    private func receipt() throws -> Receipt? {
        if !FileManager.default.fileExists(atPath:pointer.path) { return nil }
        return try JSONDecoder().decode(Receipt.self,from:Data(contentsOf:pointer))
    }
    public func installIfNeeded() throws {
        let fm = FileManager.default
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        try fm.createDirectory(at:root.appendingPathComponent("输入"),withIntermediateDirectories:true)
        try fm.createDirectory(at:root.appendingPathComponent("输出"),withIntermediateDirectories:true)
        guard let seed = Bundle.module.url(forResource:"WorkspaceSeed",withExtension:nil) else { throw ResearchError("工作区模板缺失") }
        let guide = root.appendingPathComponent("AGENTS.md")
        if !fm.fileExists(atPath:guide.path) {
            try Data(contentsOf:seed.appendingPathComponent("AGENTS.md")).write(to:guide,options:.atomic)
        }
        guard !fm.fileExists(atPath:working.path), try receipt() == nil else { return }
        let stage = root.appendingPathComponent(".install-"+UUID().uuidString)
        try fm.copyItem(at:seed,to:stage)
        try fm.moveItem(at:stage,to:working)
    }
    public func activate(validate: (WorkspaceVersion) throws -> Void = { _ in }) throws -> WorkspaceVersion {
        let version = try WorkspaceVersion.load(from:working)
        try validate(version)
        let old = try receipt(), fm=FileManager.default
        let dest = versions.appendingPathComponent(version.hash)
        if !fm.fileExists(atPath:dest.path) {
            let stage = versions.appendingPathComponent(".stage-"+UUID().uuidString)
            try version.save(at:stage)
            defer { try? fm.removeItem(at:stage) }
            try fm.moveItem(at:stage,to:dest)
        }
        guard try WorkspaceVersion.load(from:dest).hash == version.hash else { throw ResearchError("工作区版本校验失败") }
        if old?.active != version.hash {
            try JSONEncoder().encode(Receipt(active:version.hash,previous:old?.active)).write(to:pointer,options:.atomic)
        }
        return version
    }
    public func active() throws -> WorkspaceVersion? {
        guard let p = try receipt(), Integrity.digestID(p.active) else { return nil }
        let v = try WorkspaceVersion.load(from:versions.appendingPathComponent(p.active))
        guard v.hash == p.active else { throw ResearchError("已启用工作区版本损坏") }
        return v
    }
    public func rollback() throws -> WorkspaceVersion {
        guard let p = try receipt(), let old = p.previous, Integrity.digestID(old) else { throw ResearchError("没有可恢复的上一个工作区版本") }
        let v = try WorkspaceVersion.load(from:versions.appendingPathComponent(old))
        guard v.hash == old else { throw ResearchError("上一个工作区版本校验失败") }
        try JSONEncoder().encode(Receipt(active:old,previous:p.active)).write(to:pointer,options:.atomic)
        return v
    }
    public func inputs() throws -> [String: Any] {
        let dir = root.appendingPathComponent("输入")
        let urls = try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:[.fileSizeKey,.isSymbolicLinkKey],options:.skipsHiddenFiles)
        var records = [String:Any](), size = 0
        for file in urls where file.pathExtension.lowercased()=="json" {
            let meta = try file.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey])
            size += meta.fileSize ?? 0
            guard meta.isSymbolicLink != true, size <= 8*1024*1024 else { throw ResearchError("工作区输入含链接或超过 8 MB") }
            records[file.deletingPathExtension().lastPathComponent] = try JSONSerialization.jsonObject(with:Data(contentsOf:file),options:.fragmentsAllowed)
        }
        return records
    }
}
