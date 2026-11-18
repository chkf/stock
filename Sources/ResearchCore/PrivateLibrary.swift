import Foundation

public enum MarketOrigin:String,Codable { case phone, archive
    public var title:String { self == .phone ? "本机行情" : "导入快照" }
}

public struct TransferProgress {
    public let phase: String
    public let completed, total: Int
    public var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

/// One writer per library. No downloaded path is used as a filesystem pathname.
public actor PrivateLibrary {
    public nonisolated let root: URL
    private let fm = FileManager.default
    private var importing = false
    var updatingQuotes = false
    private struct Pointer: Codable { let generation: UUID; let id: String; var previousGeneration:UUID?, previousID:String? }

    public init(root: URL) { self.root = root }
    public func selectedMarket() throws -> MarketOrigin? {
        let file=root.appendingPathComponent("market-source.json")
        guard fm.fileExists(atPath:file.path) else { return nil }
        return try JSONDecoder().decode(MarketOrigin.self,from:Data(contentsOf:file))
    }
    public func selectMarket(_ origin:MarketOrigin) throws {
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONEncoder().encode(origin).write(to:root.appendingPathComponent("market-source.json"),options:.atomic)
    }

    public static func applicationLibrary() throws -> PrivateLibrary {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let documents = try FileManager.default.url(for: .documentDirectory,in: .userDomainMask,appropriateFor: nil,create: true)
        return try openWorkspace(documents: documents, previous: support.appendingPathComponent("StockResearch",isDirectory: true))
    }
    public static func openWorkspace(documents: URL, previous: URL) throws -> PrivateLibrary {
        let fm = FileManager.default
        let target = documents.appendingPathComponent("研究工作区",isDirectory: true)
        let data = target.appendingPathComponent("数据",isDirectory: true)
        try fm.createDirectory(at: target,withIntermediateDirectories: true)
        // Both directories are on the application's data volume. Rename preserves every generation and receipt.
        if fm.fileExists(atPath: previous.path) {
            guard !fm.fileExists(atPath: data.path) else { throw ResearchError("旧资料和工作区数据同时存在。已保留两份，请在文件中给现有「数据」改名后重新打开。") }
            try fm.moveItem(at: previous,to: data)
        } else { try fm.createDirectory(at: data,withIntermediateDirectories: true) }
        try FrozenInputs.install(in:data)
        return PrivateLibrary(root: data)
    }

    private func mkdir(_ url: URL) throws {
        #if os(iOS)
        try fm.createDirectory(at: url, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        #else
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        #endif
    }

    public func active() throws -> Archive? {
        let pointer = root.appendingPathComponent("active.json")
        guard fm.fileExists(atPath: pointer.path) else { return nil }
        let p = try JSONDecoder().decode(Pointer.self, from: Data(contentsOf: pointer))
        return try Archive(directory: root.appendingPathComponent("generations/\(p.generation.uuidString)"), id: p.id)
    }
    public func restorePreviousArchive() throws -> Archive {
        let dir=root.appendingPathComponent("generations")
        try HistoryWriters.shared.claim(dir); defer { HistoryWriters.shared.release(dir) }
        let active=root.appendingPathComponent("active.json")
        let current=try JSONDecoder().decode(Pointer.self,from:Data(contentsOf:active))
        guard let generation=current.previousGeneration,let id=current.previousID else { throw ResearchError("尚无上一代导入记录") }
        let previous=try Archive(directory:dir.appendingPathComponent(generation.uuidString),id:id)
        try previous.verify { _,_ in try Task.checkCancellation() }
        let restored=Pointer(generation:generation,id:id,previousGeneration:current.generation,previousID:current.id)
        try JSONEncoder().encode(restored).write(to:active,options:.atomic)
        return previous
    }

    @discardableResult
    public func receive(manifest data: Data, id: String,
                        fetch: (Int) async throws -> Data,
                        progress: (TransferProgress) -> Void) async throws -> Archive {
        guard !importing else { throw ResearchError("已有迁移正在进行") }
        importing = true
        defer { importing = false }
        let m = try Manifest.checked(data, id: id)
        let stage = root.appendingPathComponent("incoming/\(id)")
        let journal = root.appendingPathComponent("incoming/\(id).activation.json")
        let dir = root.appendingPathComponent("generations")
        try HistoryWriters.shared.claim(dir); defer { HistoryWriters.shared.release(dir) }
        let pointerURL=root.appendingPathComponent("active.json")
        let oldPointer=try fm.fileExists(atPath:pointerURL.path) ? JSONDecoder().decode(Pointer.self,from:Data(contentsOf:pointerURL)) : nil
        func verify(_ archive: Archive) throws {
            try archive.verify { done, total in
                try Task.checkCancellation()
                progress(.init(phase: "核对文件和原快照", completed: done, total: total))
            }
        }
        func activate(_ pointer: Pointer) throws -> Archive {
            let installed = try Archive(directory: dir.appendingPathComponent(pointer.generation.uuidString), id: id)
            try JSONEncoder().encode(pointer).write(to: root.appendingPathComponent("active.json"), options: .atomic)
            try? fm.removeItem(at: journal)
            return installed
        }
        // The process may have stopped between the directory rename and the active-pointer write.
        // Reuse those already received bytes after validating the whole generation.
        if fm.fileExists(atPath: journal.path) {
            let p = try JSONDecoder().decode(Pointer.self, from: Data(contentsOf: journal))
            guard p.id == id else { throw ResearchError("迁移提交记录与清单不符") }
            let finished = dir.appendingPathComponent(p.generation.uuidString)
            if fm.fileExists(atPath: finished.path) {
                try verify(Archive(directory: finished, id: id))
                return try activate(p)
            }
        }
        if let current = try? active(), current.id == id {
            do { try verify(current); return current }
            catch is CancellationError { throw CancellationError() }
            catch { /* A newly checked copy may replace the damaged generation. */ }
        }
        try mkdir(stage)
        try data.write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
        let file = stage.appendingPathComponent("payload.bin")
        if !fm.fileExists(atPath: file.path) { try Data().write(to: file, options: .withoutOverwriting) }
        let writer = try FileHandle(forUpdating: file)
        defer { try? writer.close() }
        let existing = try writer.seekToEnd()
        var complete = 0
        for (i, hash) in m.chunks.enumerated() {
            try Task.checkCancellation()
            let length = min(m.chunkSize, m.totalBytes - complete)
            if UInt64(complete + length) > existing ||
                (try? Integrity.sha(file: file, offset: complete, length: length)) != hash { break }
            complete += length
            progress(.init(phase: "核对断点", completed: i + 1, total: m.chunks.count))
        }
        try writer.truncate(atOffset: UInt64(complete))
        try writer.seek(toOffset: UInt64(complete))
        while complete < m.totalBytes {
            try Task.checkCancellation()
            let i = complete / m.chunkSize
            let part = try await fetch(i)
            guard part.count == min(m.chunkSize, m.totalBytes - complete), Integrity.sha(part) == m.chunks[i] else {
                throw ResearchError("第 \(i + 1) 块校验失败，可重新配对续传")
            }
            try writer.write(contentsOf: part)
            try writer.synchronize()
            complete += part.count
            progress(.init(phase: "接收资料", completed: complete, total: m.totalBytes))
        }
        let archive = try Archive(directory: stage, id: id)
        try verify(archive)
        try Task.checkCancellation()
        let generation = UUID()
        try mkdir(dir)
        let final = dir.appendingPathComponent(generation.uuidString)
        let pointer = Pointer(generation: generation, id: id, previousGeneration:oldPointer?.generation, previousID:oldPointer?.id)
        try JSONEncoder().encode(pointer).write(to: journal, options: .atomic)
        try fm.moveItem(at: stage, to: final)
        return try activate(pointer)
    }
}
