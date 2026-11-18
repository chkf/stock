import Foundation
import ResearchCore

enum HistoryImportCheck {
    static func stageSimulator(package:URL,root:URL) async throws {
        let vault=PrivateLibrary(root:root)
        guard try await vault.active()==nil else { throw ResearchError("模拟器试验需要空导入库") }
        let data=try Data(contentsOf:package.appendingPathComponent("manifest.json")),id=package.lastPathComponent
        let m=try Manifest.checked(data,id:id)
        let file=try FileHandle(forReadingFrom:package.appendingPathComponent("payload.bin"))
        defer { try? file.close() }
        _=try await vault.receive(manifest:data,id:id,fetch:{ i in
            try file.seek(toOffset:UInt64(i*m.chunkSize))
            return try file.read(upToCount:m.chunkSize) ?? Data()
        },progress:{ _ in })
    }
    static func run(package:URL,output:URL,invalid:URL?) async throws {
        let fm=FileManager.default
        let dir=fm.temporaryDirectory.appendingPathComponent("stock-import-test-"+UUID().uuidString)
        defer { try? fm.removeItem(at:dir) }
        let vault=PrivateLibrary(root:dir)
        let manifest=try Data(contentsOf:package.appendingPathComponent("manifest.json"))
        let id=package.lastPathComponent, meta=try Manifest.checked(manifest,id:id)
        func receive(_ bytes:Data,id:String,source:URL,damageChunk:Bool=false) async throws -> Archive {
            let file=try FileHandle(forReadingFrom:source.appendingPathComponent("payload.bin"))
            defer { try? file.close() }
            return try await vault.receive(manifest:bytes,id:id,fetch:{ i in
                try file.seek(toOffset:UInt64(i*meta.chunkSize))
                var block=try file.read(upToCount:meta.chunkSize) ?? Data()
                if damageChunk && !block.isEmpty { block[0] ^= 1 }
                return block
            },progress:{ _ in })
        }
        let initial=try await receive(manifest,id:id,source:package)
        let cal=try Sessions(), strategies=try WorkspaceVersion.bundled().design.strategies
        let market=try initial.loadMarket(),coverage=try HistoryCoverage(market:market,sessions:cal,strategies:strategies)
        var refused=[String]()
        func expect(_ label:String,reason:String,bytes:Data,identity:String,source:URL,damage:Bool=false) async throws {
            do { _=try await receive(bytes,id:identity,source:source,damageChunk:damage) }
            catch {
                guard error.localizedDescription.contains(reason),try await PrivateLibrary(root:dir).active()?.id==id else { throw ResearchError(label+" 未按预期拒绝或原代改变："+error.localizedDescription) }
                refused.append(label); return
            }
            throw ResearchError(label+" 被错误启用")
        }
        try await expect("坏清单",reason:"清单编号",bytes:manifest,identity:String(repeating:"0",count:64),source:package)
        func modified(_ edit:(inout [String:Any])->Void) throws ->Data {
            var value=try JSONSerialization.jsonObject(with:manifest) as! [String:Any]; edit(&value)
            return try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
        }
        let other=try modified { $0["testVariant"]="chunk" }
        try await expect("坏分块",reason:"块校验",bytes:other,identity:Integrity.sha(other),source:package,damage:true)
        let snap=try modified { v in
            var rows=v["files"] as! [[String:Any]]
            let i=rows.firstIndex { ($0["path"] as! String).hasSuffix(meta.snapshot.hash+".json.gz") }!
            rows[i]["path"]="data/advice/market/snapshots/"+String(repeating:"a",count:64)+".json.gz"
            v["files"]=rows
        }
        try await expect("坏快照编号",reason:"行情快照编号",bytes:snap,identity:Integrity.sha(snap),source:package)
        let evidence=try modified { v in
            let key=market.sources.keys.sorted().first!
            var aliases=v["aliases"] as! [String:String]
            let rel=aliases[key] ?? key; aliases=aliases.filter { $0.value != rel }
            var rows=v["files"] as! [[String:Any]]
            let i=rows.firstIndex { ($0["path"] as? String)==rel }!
            rows[i]["path"]="unreferenced/raw"; v["files"]=rows; v["aliases"]=aliases
        }
        try await expect("来源断链",reason:"来源",bytes:evidence,identity:Integrity.sha(evidence),source:package)
        if let invalid {
            let bad=try Data(contentsOf:invalid.appendingPathComponent("manifest.json"))
            try await expect("哈希全部正确但目标缺预热",reason:"预热",bytes:bad,identity:invalid.lastPathComponent,source:invalid)
        }
        // A second valid envelope over exactly the same public originals exercises generation rollback.
        let second=try await receive(other,id:Integrity.sha(other),source:package)
        guard second.id != id,try await vault.restorePreviousArchive().id==id else { throw ResearchError("导入资料未能回到上一代") }
        let reopened=PrivateLibrary(root:dir)
        try await reopened.selectMarket(.archive)
        guard try await PrivateLibrary(root:dir).selectedMarket()==MarketOrigin.archive else { throw ResearchError("所选导入源未保存") }
        let proof:[String:Any]=["snapshot":meta.snapshot.hash,"package":id,"entries":meta.fileCount,"chunks":meta.chunks.count,
            "retainedOnRefusal":refused,"rollbackChecked":true,"verifiedIntervals":coverage.windows.map{[$0.start,$0.end]}]
        try JSONSerialization.data(withJSONObject:proof,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
        print("stock-transfer-1 原生导入、来源选择与重开通过；\(refused.count) 种损坏或不适用输入均保留旧代")
    }
}
