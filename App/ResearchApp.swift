import ResearchCore
import SwiftUI

@main @MainActor struct ResearchApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            WorkspaceRoot()
            .environmentObject(model)
            .tint(Color(red: 0.04, green: 0.40, blue: 0.38))
            .task { await model.open() }
            .task(id: model.studyKey) { await model.restoreStudies() }
            .onOpenURL { model.queueWorkspaceLink($0) }
            .onChange(of:model.busy) { value in if !value { model.dispatchWorkspaceLink() } }
            .alert("股票研究台", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("知道了") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var archive: Archive?
    @Published var handset: PhoneSnapshot?
    @Published var personal: Account?
    @Published var saved = [SavedAdvice]()
    @Published var latest: SavedAdvice?
    @Published var parity = [ParityResult]()
    @Published var paritySource = ""
    @Published var progress = ""
    @Published var fraction = 0.0
    @Published var busy = false
    @Published var error: String?
    @Published var names = [String: String]()
    @Published var sources = [String]()
    @Published var archivedMarket: MarketSnapshot?
    @Published var watch = [WatchedSecurity]()
    @Published var origin:MarketOrigin = .phone
    @Published var coverage:HistoryCoverage?
    @Published var coverageError=""
    @Published var studyStrategy=""
    var rangeProblem:String? {
        guard let coverage else { return coverageError.isEmpty ? "正在等候已核行情区间" : coverageError }
        return coverage.problem(start:replayStart,end:replayEnd,completed:today.isEmpty ? nil : today)
    }
    func selectOrigin(_ choice:MarketOrigin) {
        guard let vault else { return }
        start("切换行情来源") {
            try await vault.selectMarket(choice); self.origin=choice
        }
    }
    @Published var selectedStrategy = ""
    @Published var workspace: WorkspaceVersion?
    @Published var decision: Decision?
    @Published var signalReason = ""
    @Published var next = ""
    @Published var today = ""
    @Published var replayStart = ""
    @Published var replayEnd = ""
    @Published var fields = [String:String]()
    @Published var widgetResults = [String:FunctionOutput]()
    private var pendingLinks = [URL]()
    private var opened = false
    var store: WorkspaceStore? { vault.map { WorkspaceStore(root:$0.root.deletingLastPathComponent()) } }
    var selectedFile: StrategyFile? { workspace?.design.strategies.first { $0.id == selectedStrategy } }
    var studyKey: String { "\(origin.rawValue)|\(marketID ?? "")|\(workspace?.hash ?? "")|\(studyStrategy)" }
    var signalKey: String { studyKey+"|"+selectedStrategy }
    @Published var studies: [String: ReplayReport] = [:]
    var useArchive: Bool {
        origin == .archive
    }
    var market: MarketSnapshot? { useArchive ? archivedMarket : handset?.market }
    var marketID: String? { useArchive ? archive?.manifest.snapshot.hash : handset?.hash }
    @Published private(set) var vault: PrivateLibrary?
    private var job: Task<Void, Never>?

    func open() async {
        defer { opened = true; dispatchWorkspaceLink() }
        do {
            let library = try PrivateLibrary.applicationLibrary()
            vault = library
            var issues = [String]()
            do {
                if let saved=try await library.selectedMarket() { origin=saved }
                else if !FileManager.default.fileExists(atPath:library.root.appendingPathComponent("public-market/current.json").path),
                    FileManager.default.fileExists(atPath:library.root.appendingPathComponent("active.json").path) {
                    origin = .archive; try await library.selectMarket(.archive)
                }
            } catch { issues.append(error.localizedDescription) }
            if let store {
                do {
                    self.workspace = try await Task.detached {
                        try store.installIfNeeded()
                        return try store.active() ?? store.activate()
                    }.value
                    normalizeSelection()
                } catch { issues.append(error.localizedDescription) }
            }
            do { watch = try await library.watchlist() } catch { issues.append(error.localizedDescription) }
            do { personal = try await library.personalAccount() } catch { issues.append(error.localizedDescription) }
            do { handset = try await library.phoneMarket() } catch { issues.append(error.localizedDescription) }
            do {
                let active = try await library.active()
                try await display(active)
            } catch { issues.append(error.localizedDescription) }
            do { saved = try await library.reports() } catch { issues.append(error.localizedDescription) }
            if !issues.isEmpty { self.error = issues.joined(separator: "\n") }
        } catch { self.error = error.localizedDescription }
    }
    private func display(_ active: Archive?) async throws {
        if let active {
            let market = try await Task.detached(priority: .userInitiated) { try active.loadMarket() }.value
            archivedMarket = market
            names = market.securities.mapValues(\.name)
            sources = market.sources.keys.sorted()
        }
        archive = active
    }
    func start(_ title: String, request:WorkspaceTicket? = nil, _ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; progress = title; fraction = 0
        job = Task {
            defer { busy = false; job = nil }
            do {
                try await work()
                if let request { try store?.finish(request,ok:true,message:progress) }
            } catch {
                let reason = error is CancellationError ? "本次任务已取消" : error.localizedDescription
                if let request { try? store?.finish(request,ok:false,message:reason) }
                else if !(error is CancellationError) { self.error = reason }
                progress = reason
            }
        }
    }
    func receive(_ code: String) {
        guard let vault else { return }
        start("正在与电脑配对") {
            let archive = try await LANTransfer.receive(code: code, vault: vault) { p in
                Task { @MainActor in self.progress = "\(p.phase)　\(p.completed) / \(p.total)"; self.fraction = p.fraction }
            }
            try await self.display(archive)
            self.parity = []; self.latest = nil; self.progress = "资料已校验并启用"
        }
    }
    func cancel() { job?.cancel() }
    func restorePreviousArchive() {
        guard let vault else { return }
        start("核验上一代导入资料") {
            let archived=try await vault.restorePreviousArchive()
            try await self.display(archived)
            self.progress="已恢复上一代导入资料"
        }
    }
    func normalizeSelection() {
        guard let config = workspace?.design else { return }
        if !config.strategies.contains(where: { $0.id == selectedStrategy }) { selectedStrategy = config.strategies[0].id }
    }
    func queueWorkspaceLink(_ url: URL) {
        guard url.scheme == "stockresearch", url.host == "workspace", url.query == nil, url.fragment == nil else { return }
        pendingLinks.append(url)
        dispatchWorkspaceLink()
    }
    func dispatchWorkspaceLink() {
        guard opened, !busy, vault != nil, !pendingLinks.isEmpty else { return }
        let url = pendingLinks.removeFirst()
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts == ["reload"] { reloadWorkspace() }
        else if parts.count == 2, parts[0] == "run", workspace?.design.actions[parts[1]] != nil { runAction(parts[1]) }
        else if parts.count == 2, parts[0] == "strategy", workspace?.design.strategies.contains(where:{ $0.id == parts[1] }) == true {
            selectedStrategy = parts[1]
            start("正在本机重算策略") { await self.updateDecision() }
        } else if !pendingLinks.isEmpty {
            Task { dispatchWorkspaceLink() }
        }
    }
    func processFileRequest() {
        guard opened, !busy, let store else { return }
        do {
            guard let ticket = try store.nextRequest() else { return }
            let request = ticket.request
            if request.operation == "reload" { reloadWorkspace(request:ticket); return }
            guard let w=workspace, let target=request.target else {
                try store.finish(ticket,ok:false,message:"请先启用工作区"); return
            }
            if request.operation == "run", w.design.actions[target] != nil {
                runAction(target,request:ticket); return
            }
            if request.operation == "strategy", w.design.strategies.contains(where:{ $0.id == target }) {
                selectedStrategy=target
                start("正在本机重算策略",request:ticket) {
                    try await self.calculateDecision()
                    self.progress = "已保存市场判断 "+target
                }
                return
            }
            try store.finish(ticket,ok:false,message:"当前设计中找不到 "+target)
        } catch { progress = error.localizedDescription }
    }
    func reloadWorkspace(rollback: Bool = false, request: WorkspaceTicket? = nil) {
        guard let store, let vault else { return }
        start("检查工作区文件",request:request) {
            do {
            let live = try await vault.phoneMarket()
            let personal = try await vault.personalAccount(), saved = try await vault.reports()
            let watch = try await vault.watchlist(), archive = try await vault.active()
            let oldMarket = try await Task.detached { try archive?.loadMarket() }.value
            let m = self.useArchive ? oldMarket : live?.market
            let new = try await Task.detached {
                if rollback { return try store.rollback() }
                return try store.activate { candidate in
                    if let m {
                        let engine = try StrategyEngine(market:m,sessions:Sessions(),workspace:candidate)
                        for s in candidate.design.strategies { _ = try engine.decision(s.id,on:m.as_of) }
                    }
                }
            }.value
            self.handset=live; self.personal=personal; self.saved=saved; self.watch=watch
            self.archive=archive; self.archivedMarket=oldMarket
            self.names=oldMarket?.securities.mapValues(\.name) ?? [:]; self.sources=oldMarket?.sources.keys.sorted() ?? []
            self.workspace = new; self.widgetResults = [:]; self.normalizeSelection()
            self.progress = "已启用 "+String(new.hash.prefix(12))
            try store.logActivation(active:new.hash,message:self.progress,successful:true)
            } catch {
                try? store.logActivation(active:self.workspace?.hash ?? "",message:error.localizedDescription,successful:false)
                throw error
            }
        }
    }
    func updateDecision() async {
        decision = nil; signalReason = ""
        guard market != nil else { return }
        do { try await calculateDecision() }
        catch is CancellationError {} catch { if !Task.isCancelled { signalReason = error.localizedDescription } }
    }
    private func calculateDecision() async throws {
        guard let m = market, let w = workspace, let store, let raw=marketID else { throw ResearchError("请先获取行情并启用工作区") }
        let id = selectedStrategy
        let cal = try Sessions()
        today = try cal.completed()
        let d = try await Task.detached { try StrategyEngine(market:m,sessions:cal,workspace:w).decision(id,on:m.as_of) }.value
        try Task.checkCancellation()
        guard workspace?.hash == w.hash, marketID == raw, selectedStrategy == id else { throw CancellationError() }
        next = try cal.next(m.as_of)
        try store.writeDecision(d,market:m,snapshotID:raw,version:w.hash,next:next,current:today)
        decision = d; signalReason = ""
    }
    func editWatch(_ symbol: String, remove: Bool = false) {
        guard let vault else { return }
        start(remove ? "移出自选" : "获取自选日线") {
            if remove { try await vault.removeWatch(symbol) } else { try await vault.updateWatch(symbol) }
            self.watch = try await vault.watchlist()
        }
    }
    func saveAccount(_ account: Account) async throws {
        guard let vault else { throw ResearchError("本机资料库未打开") }
        try await vault.savePersonal(account)
        personal = try await vault.personalAccount()
    }
    func refresh(from:String?=nil,through:String?=nil) {
        guard let vault else { return }
        start("连接公开行情源") {
            self.handset = try await vault.refreshPublicMarket(from:from,asOf:through) { p in
                Task { @MainActor in self.progress = p.phase; self.fraction = p.fraction }
            }
            self.progress = "本机行情已保存"
        }
    }
    func calculate(strategy: String, date: String?, capital: Double, phone: Bool, actual: Bool) {
        guard let vault, let workspace else { return }
        let archive = self.archive
        start("正在本机重算") {
            let report = try await Task.detached(priority: .userInitiated) {
                let sessions = try Sessions(), market: MarketSnapshot, hash: String
                let requested = try sessions.completed(asOf: date)
                if phone, let live = try await vault.phoneMarket() {
                    guard let first=live.usableFrom,requested>=first else { throw ResearchError("本机行情在请求日期缺足够的已核暖机数据") }
                    market = live.market; hash = live.hash
                } else if !phone, let archive {
                    market = try archive.loadMarket(); hash = archive.manifest.snapshot.hash
                } else { throw ResearchError("请先联网获取公开行情") }
                let account: Account
                if actual {
                    guard date == nil, let personal = try await vault.personalAccount() else {
                        throw ResearchError("真实账户方案需要当前收盘及已确认的账户")
                    }
                    account = personal
                } else { account = Account(date: min(market.as_of, requested), cash: capital) }
                let advice = try StrategyEngine(market: market, sessions: sessions, workspace: workspace).advice(strategy, requested: requested, account: account)
                return SavedAdvice(snapshot: hash, requested: requested, capital: account.cash, result: advice, actualAccount: actual,
                                   accountID: actual ? try AccountInput.identity(account) : nil, workspaceID: workspace.hash)
            }.value
            try Task.checkCancellation()
            try await vault.saveReport(report)
            self.saved = try await vault.reports()
            self.latest = report
            self.progress = "复算结果已保存"
        }
    }
    func reconcile(phone: Bool) {
        guard let vault, let workspace else { return }
        let archive = self.archive
        start("正在核对 Python 对照样例") {
            self.parity = []
            self.paritySource = (phone ? "手机行情库" : "旧版冻结快照")+" · "+String(workspace.hash.prefix(10))
            let task = Task.detached(priority: .userInitiated) { () async throws -> [ParityResult] in
                func progress(_ n: Int, _ total: Int) throws {
                    try Task.checkCancellation()
                    Task { @MainActor in self.progress = "逐项对账 \(n) / \(total)"; self.fraction = Double(n) / Double(total) }
                }
                if phone, let current = try await vault.phoneMarket() { return try Parity.run(phone: current, workspace:workspace, progress: progress) }
                if !phone, let archive { return try Parity.run(archive: archive, workspace:workspace, progress: progress) }
                throw ResearchError("当前未找到所选行情")
            }
            self.parity = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        }
    }
}

struct StrategyView: View {
    @EnvironmentObject var model: AppModel
    @State private var strategy = ""
    @State private var date = ""
    @State private var capital = "50000"
    @State private var current = true
    @State private var useActual = true
    var body: some View {
        let phone = model.origin == .phone
        let snapshotDay = model.market?.as_of
        let actual = current && useActual && model.personal != nil
        Form {
            Section("本机行情") {
                MarketSourceControl()
                Button { model.refresh() } label: { Label(model.handset == nil ? "联网建立 28 只 ETF 行情库" : "更新 28 只 ETF 行情", systemImage: "arrow.clockwise") }
                    .disabled(model.busy)
                if let live = model.handset { LabeledContent("公开行情已核至", value: live.market.as_of) }
                if model.handset == nil { Text("首次使用可直接联网取数，在「账户」录入实际持仓。").font(.caption) }
            }
            if let snapshotDay {
                Section("行情") {
                    LabeledContent("已校验收盘", value: snapshotDay)
                }
                Section("独立方案") {
                    Picker("策略", selection: $strategy) {
                        ForEach(model.workspace?.design.strategies ?? []) { item in Text(item.title).tag(item.id) }
                    }
                    Toggle("使用最近完整交易日", isOn: $current)
                    if !current {
                        TextField("历史日期 YYYY-MM-DD", text: $date).keyboardType(.numbersAndPunctuation)
                    }
                    if current && model.personal != nil { Toggle("使用已确认真实账户", isOn: $useActual) }
                    if actual, let account = model.personal {
                        LabeledContent("真实账户收盘日", value: account.as_of)
                    } else {
                        HStack { Text("空仓演示本金"); Spacer(); TextField("元", text: $capital).keyboardType(.decimalPad).multilineTextAlignment(.trailing); Text("元") }
                    }
                    Button("离线重算") {
                        let amount = Double(capital) ?? 0
                        guard actual || (amount.isFinite && (1000...100_000_000).contains(amount)) else {
                            model.error = "演示本金需在 1,000 至 1 亿元之间"; return
                        }
                        model.calculate(strategy: strategy, date: current ? nil : date, capital: amount, phone: phone, actual: actual)
                    }.disabled(model.busy)
                }
                if let r = model.latest {
                    Section("最近一次复算") { NavigationLink { ReportView(report: r) } label: { ReportRow(report: r) } }
                }
            }
            if model.busy { Section { ProgressView(value: model.fraction) { Text(model.progress) }; Button("取消", role: .cancel) { model.cancel() } } }
        }
        .navigationTitle("账户份额测算")
        .onAppear {
            if date.isEmpty { date = snapshotDay ?? "" }
            if model.workspace?.design.strategies.contains(where:{ $0.id == strategy }) != true { strategy=model.selectedStrategy }
        }
        .onChange(of: snapshotDay) { day in date = day ?? "" }
    }
}

struct ReportRow: View {
    let report: SavedAdvice
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(report.result.decision.strategy) · \(report.result.decision.date)")
            Text(report.result.reason ?? "\(report.actualAccount == true ? "已确认真实账户" : "空仓演示") · \(report.result.plan?.orders.count ?? 0) 条调整意向")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ReportView: View {
    let report: SavedAdvice
    @EnvironmentObject var model: AppModel
    private func yuan(_ x: Double) -> String { String(format: "%.2f 元", x) }
    var body: some View {
        List {
            Section(report.actualAccount == true ? "已确认真实账户" : "空仓演示") {
                LabeledContent("策略", value: report.result.decision.strategy)
                LabeledContent("请求截止", value: report.requested)
                LabeledContent("信号收盘", value: report.result.decision.date)
                LabeledContent("信号对应下一交易日", value: report.result.next)
                LabeledContent(report.actualAccount == true ? "已确认可用现金" : "参考本金", value: yuan(report.capital))
                if let id = report.accountID { NavigationLink("查看当次账户记录") { AccountRecordView(id: id) } }
            }
            if let reason = report.result.reason { Section("停止生成操作数量") { Text(reason) } }
            Section("目标权重") {
                ForEach(report.result.decision.weights.keys.sorted(), id: \.self) { s in
                    LabeledContent(model.handset?.market.securities[s]?.name ?? model.names[s] ?? s, value: String(format: "%.4f%%", 100 * report.result.decision.weights[s]!))
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("预留现金", value: String(format: "%.4f%%", 100 * max(0, 1 - report.result.decision.weights.values.reduce(0, +))))
            }
            if let plan = report.result.plan {
                Section("参考份额") {
                    ForEach(Array(plan.orders.enumerated()), id: \.offset) { _, order in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(order.side == "BUY" ? "买入" : "卖出") \(order.symbol)　\(order.quantity) 份")
                            Text("收盘参考 \(order.reference_price.formatted()) 元 · 费用 \(yuan(order.costs.total))")
                            if let funded = order.funded_quantity { Text("现款可买 \(funded) 份 · 依赖到账 \(order.conditional_quantity ?? 0) 份") }
                            if order.deferred_quantity > 0 { Text("延后 \(order.deferred_quantity) 份") }
                        }.font(.subheadline)
                    }
                    LabeledContent("预计费用合计", value: yuan(plan.estimated_costs))
                    LabeledContent("按参考价调整后现金", value: yuan(plan.projected_cash))
                }
            }
            Section("来源") {
                Text(report.snapshot).font(.caption.monospaced()).textSelection(.enabled)
                if let v = report.workspaceID { Text("策略版本 "+v).font(.caption.monospaced()).textSelection(.enabled) }
                Text("按已完成收盘价估算。未记入实际成交。")
            }
        }.navigationTitle("复算结果")
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            if model.saved.isEmpty { Text("本机复算后，报告会保存在这里。") }
            ForEach(model.saved) { report in NavigationLink { ReportView(report: report) } label: { ReportRow(report: report) } }
        }.navigationTitle("历史报告")
    }
}
