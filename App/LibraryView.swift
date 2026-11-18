import PDFKit
import Charts
import ResearchCore
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var code = ""
    @State private var scanning = false
    var body: some View {
        Form {
            if let live = model.handset {
                Section("手机行情库") {
                    LabeledContent("行情截止", value: live.market.as_of)
                    LabeledContent("完整策略可用起日", value: live.usableFrom)
                    LabeledContent("固定池", value: "\(live.market.securities.count) 只 ETF")
                    NavigationLink("查看公开行情和行动原件") { QuoteEvidenceBrowser(live: live) }
                    Button("用手机行情重跑 Python 对照用例") { model.reconcile(phone: true) }.disabled(model.busy)
                    Text(live.hash).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Section {
                DisclosureGroup("从旧电脑导入（可选）") {
                    Button { scanning = true } label: { Label("扫描一次性配对码", systemImage: "qrcode.viewfinder") }
                    TextField("或输入 SR1 配对码", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button("连接并校验导入") { model.receive(code); code = "" }
                        .disabled(code.isEmpty || model.busy)
                    if model.busy {
                        ProgressView(value: model.fraction) { Text(model.progress) }
                        Button("暂停", role: .cancel) { model.cancel() }
                    } else if !model.progress.isEmpty { Text(model.progress).font(.caption) }
                }
            }
            if let archive = model.archive {
                Section("已导入旧资料") {
                    LabeledContent("范围", value: archive.manifest.profile == "snapshot" ? "快照及来源证据" : "完整原项目归档")
                    LabeledContent("文件", value: "\(archive.manifest.fileCount) 件")
                    LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: Int64(archive.manifest.totalBytes), countStyle: .file))
                    NavigationLink("查找原件") { ArchiveBrowser(archive: archive) }
                    NavigationLink("行情来源证据") {
                        List(model.sources, id: \.self) { path in
                            if let entry = archive.resolve(path) {
                                NavigationLink { OriginalView(archive: archive, entry: entry) } label: {
                                    VStack(alignment: .leading) { Text(entry.path); Text(path).font(.caption).foregroundStyle(.secondary) }
                                }
                            } else { Text("来源未匹配　\(path)") }
                        }.navigationTitle("来源映射")
                    }
                }
                Section("旧快照对照") {
                    Button("用冻结快照重跑 Python 对照用例") { model.reconcile(phone: false) }.disabled(model.busy)
                }
            }
            if !model.parity.isEmpty {
                Section("对账结果 · \(model.paritySource)") {
                    ForEach(model.parity, id: \.name) { item in
                        VStack(alignment: .leading) {
                            Label(item.name, systemImage: item.differences.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                            if item.onlyOrderDiffers == true { Text("两只 ETF 同在 35% 上限附近，数值库的末位差异改变了行序。逐只核对的方向、份额和费用均一致。").font(.caption) }
                            if !item.differences.isEmpty { Text(item.differences.joined(separator: "\n")).font(.caption) }
                        }
                    }
                }
            }
        }
        .navigationTitle("资料库")
        .sheet(isPresented: $scanning) {
            NavigationStack {
                Scanner { result in
                    scanning = false
                    switch result {
                    case .success(let text): code = text
                    case .failure(let error): model.error = error.localizedDescription
                    }
                }.ignoresSafeArea(edges: .bottom)
                    .navigationTitle("扫描电脑配对码")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { scanning = false } } }
            }
        }
    }
}

private struct QuoteEvidenceBrowser: View {
    let live: PhoneSnapshot
    @State private var query = ""
    var body: some View {
        List(live.market.sources.keys.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.sorted(), id: \.self) { key in
            NavigationLink {
                QuoteEvidenceView(live: live, path: key)
            } label: {
                VStack(alignment: .leading) {
                    Text((key as NSString).lastPathComponent)
                    Text(live.market.sources[key] ?? "").lineLimit(1).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("公开资料原件").searchable(text: $query, prompt: "代码或原件名")
    }
}

private struct QuoteEvidenceView: View {
    let live: PhoneSnapshot
    let path: String
    @EnvironmentObject var model: AppModel
    @State private var pages = [String]()
    @State private var page = 0
    var body: some View {
        List {
            Section("校验编号") { Text(live.market.sources[path] ?? "").font(.caption.monospaced()).textSelection(.enabled) }
            if pages.indices.contains(page) {
                Section("原文") {
                    if pages.count > 1 {
                        LabeledContent("分段", value: "\(page + 1) / \(pages.count)")
                        if page > 0 { Button("上一段") { page -= 1 } }
                        if page + 1 < pages.count { Button("下一段") { page += 1 } }
                    }
                    Text(pages[page]).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }.navigationTitle((path as NSString).lastPathComponent).navigationBarTitleDisplayMode(.inline)
            .task {
                do {
                    guard let vault = model.vault else { return }
                    let source = try await vault.onlineText(path, snapshot: live)
                    var rest = source[...], parts = [String]()
                    while !rest.isEmpty {
                        let block = rest.prefix(8192)
                        parts.append(String(block)); rest = rest[block.endIndex...]
                    }
                    pages = parts
                } catch { model.error = error.localizedDescription }
            }
    }
}

struct ArchiveBrowser: View {
    let archive: Archive
    @State private var query = ""
    @State private var limit = 120
    var body: some View {
        let matches = query.isEmpty ? archive.manifest.files : archive.resolve(query).map { [$0] }
            ?? archive.manifest.files.filter { $0.path.localizedCaseInsensitiveContains(query) }
        List {
            ForEach(matches.prefix(limit)) { entry in
                NavigationLink { OriginalView(archive: archive, entry: entry) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text((entry.path as NSString).lastPathComponent)
                        Text(entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            if matches.count > limit { Button("继续显示，共 \(matches.count) 项") { limit += 120 } }
        }.navigationTitle("项目原件")
            .searchable(text: $query, prompt: "文件名、目录或报告编号")
            .onChange(of: query) { _ in limit = 120 }
    }
}

private struct EmbeddedPDF: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {}
}

struct OriginalView: View {
    let archive: Archive
    let entry: ArchiveEntry
    @State private var text = ""
    @State private var page = 0
    @State private var pages = 1
    @State private var loading = true
    @State private var pdf: Data?
    @State private var picture: UIImage?
    @State private var charts = [ArchiveChart]()
    private let blockSize = 32 * 1024
    var body: some View {
        List {
            Section("原件") {
                Text(entry.path).textSelection(.enabled)
                Text("\(entry.size) 字节").font(.caption)
                Text(entry.sha256).font(.caption.monospaced()).textSelection(.enabled)
            }
            Section("内容") {
                if loading { ProgressView() }
                if let picture { Image(uiImage: picture).resizable().scaledToFit() }
                if let pdf { EmbeddedPDF(data: pdf).frame(minHeight: 420) }
                if !charts.isEmpty { PublishedChartView(charts: charts) }
                if !text.isEmpty { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                if pages > 1 {
                    LabeledContent("分段", value: "\(page + 1) / \(pages)")
                    if page > 0 { Button("上一段") { page -= 1 } }
                    if page + 1 < pages { Button("下一段") { page += 1 } }
                }
            }
        }
        .navigationTitle((entry.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: page) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let pageNumber = page, width = blockSize
            let ext = (entry.path as NSString).pathExtension.lowercased()
            if entry.path.hasPrefix("external-charts/"), ext == "html" {
                charts = try await Task.detached { try ArchiveChart.load(from: archive.read(entry.path)) }.value
                return
            }
            let (bytes, pageCount) = try await Task.detached { () -> (Data, Int) in
                if ["pdf", "png", "jpg", "jpeg"].contains(ext) && entry.size <= 32 * 1024 * 1024 {
                    return try (archive.read(entry.path), 1)
                }
                if ext == "gz", entry.size <= 32 * 1024 * 1024 {
                    let raw = try Integrity.gunzip(archive.read(entry.path))
                    let start = min(raw.count, pageNumber * width)
                    return (raw.subdata(in: start..<min(raw.count, start + width)), max(1, (raw.count + width - 1) / width))
                }
                let handle = try FileHandle(forReadingFrom: archive.payload)
                defer { try? handle.close() }
                let offset = min(entry.size, pageNumber * width)
                try handle.seek(toOffset: UInt64(entry.offset + offset))
                return try (handle.read(upToCount: min(width, entry.size - offset)) ?? Data(), max(1, (entry.size + width - 1) / width))
            }.value
            try Task.checkCancellation()
            pages = pageCount
            if ext == "pdf" && pageCount == 1 { pdf = bytes; return }
            if ["jpg", "png", "jpeg"].contains(ext), let image = UIImage(data: bytes) { picture = image; return }
            if bytes.prefix(256).contains(0) {
                text = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            } else { text = String(decoding: bytes, as: UTF8.self) }
        } catch { text = error.localizedDescription }
    }
}

private struct PublishedChartView: View {
    let charts: [ArchiveChart]
    @State private var index = 0
    @State private var selected = ""
    var body: some View {
        let chart = charts[index]
        let name = chart.names.contains(selected) ? selected : chart.names[0]
        VStack(alignment: .leading, spacing: 12) {
            if charts.count > 1 {
                Picker("图表", selection: $index) {
                    ForEach(charts.indices, id: \.self) { i in Text(charts[i].title).tag(i) }
                }
            }
            Text(chart.title).font(.headline)
            Picker("曲线", selection: Binding(get: { name }, set: { selected = $0 })) {
                ForEach(chart.names, id: \.self) { item in Text(item).tag(item) }
            }
            Chart(chart.series[name] ?? []) { point in
                LineMark(x: .value("日期", point.date), y: .value(chart.yLabel, point.value))
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(chart.percent ? v.formatted(.percent.precision(.fractionLength(0))) : v.formatted())
                        }
                    }
                }
            }
            .frame(height: 240)
            Text(chart.yLabel).font(.caption)
            if !chart.detail.isEmpty { Text(chart.detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
