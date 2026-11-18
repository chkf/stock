import Foundation

/// Historical calendars and Python fixtures retain their identity when an agent reads them in Files.
enum FrozenInputs {
    private struct Item {
        let data: Data
        let hash: String
    }
    private static let original = Result { () throws -> [String:Item] in
        var result = [String:Item]()
        for name in ["XSHG.txt","PublicRules.json","Reference.json"] {
            let path = name as NSString
            guard let url = Bundle.module.url(forResource:path.deletingPathExtension,withExtension:path.pathExtension)
            else { throw ResearchError("缺少随附基准 "+name) }
            let data = try Data(contentsOf:url)
            result[name] = Item(data:data,hash:Integrity.sha(data))
        }
        return result
    }

    static func install(in dataRoot:URL) throws {
        let fm = FileManager.default
        let root = dataRoot.appendingPathComponent("原版依据")
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let items = try original.get()
        for (name,item) in items {
            let dir = root.appendingPathComponent(item.hash)
            try fm.createDirectory(at:dir,withIntermediateDirectories:true)
            let url = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath:url.path) { try item.data.write(to:url,options:.atomic) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        let index = try encoder.encode(items.mapValues(\.hash))
        let pointer = root.appendingPathComponent("当前.json")
        if (try? Data(contentsOf:pointer)) != index { try index.write(to:pointer,options:.atomic) }
    }

    static func data(_ name:String,in dataRoot:URL? = nil) throws -> Data {
        guard let item = try original.get()[name] else { throw ResearchError("未知的原版依据 "+name) }
        var root = dataRoot
        #if os(iOS)
        if root == nil {
            root = try FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:false)
                .appendingPathComponent("研究工作区/数据")
        }
        #endif
        guard let root else { return item.data }
        let url = root.appendingPathComponent("原版依据/\(item.hash)/\(name)")
        let data = try Data(contentsOf:url)
        guard Integrity.sha(data) == item.hash else { throw ResearchError("原版依据已改变，请恢复 "+name) }
        return data
    }
}
