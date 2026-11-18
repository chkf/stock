import ResearchCore
import SwiftUI

@main @MainActor struct ResearchApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack { StrategyView() }
                    .tabItem { Label("策略", systemImage: "chart.line.uptrend.xyaxis") }
                NavigationStack { AccountView() }
                    .tabItem { Label("账户", systemImage: "person.crop.circle") }
                NavigationStack { LibraryView() }
                    .tabItem { Label("资料库", systemImage: "archivebox") }
                NavigationStack { HistoryView() }
                    .tabItem { Label("历史报告", systemImage: "clock") }
            }
            .environmentObject(model)
            .tint(Color(red: 0.04, green: 0.40, blue: 0.38))
            .task { await model.open() }
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
    @Published private(set) var vault: PrivateLibrary?
    private var job: Task<Void, Never>?

    func open() async {
        do {
            let library = try PrivateLibrary.applicationLibrary()
            vault = library
            var issues = [String]()
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
            names = market.securities.mapValues(\.name)
            sources = market.sources.keys.sorted()
        }
        archive = active
    }
    private func start(_ title: String, _ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; progress = title; fraction = 0
        job = Task {
            defer { busy = false; job = nil }
            do { try await work() }
            catch is CancellationError { progress = "本次任务已取消" }
            catch { self.error = error.localizedDescription; progress = "未完成" }
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
    func saveAccount(_ account: Account) async throws {
        guard let vault else { throw ResearchError("本机资料库未打开") }
        try await vault.savePersonal(account)
        personal = try await vault.personalAccount()
    }
    func refresh() {
        guard let vault else { return }
        start("连接公开行情源") {
            self.handset = try await vault.refreshPublicMarket { p in
                Task { @MainActor in self.progress = p.phase; self.fraction = p.fraction }
            }
            self.progress = "本机行情已保存"
        }
    }
    func calculate(strategy: String, date: String?, capital: Double, phone: Bool, actual: Bool) {
        guard let vault else { return }
        let archive = self.archive
        start("正在本机重算") {
            let report = try await Task.detached(priority: .userInitiated) {
                let sessions = try Sessions(), market: MarketSnapshot, hash: String
                let requested = try sessions.completed(asOf: date)
                if phone, let live = try await vault.phoneMarket() {
                    guard requested >= live.usableFrom else { throw ResearchError("本机新建行情库的完整暖机截至 \(live.usableFrom)") }
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
                let advice = try StrategyEngine(market: market, sessions: sessions).advice(strategy, requested: requested, account: account)
                return SavedAdvice(snapshot: hash, requested: requested, capital: account.cash, result: advice, actualAccount: actual,
                                   accountID: actual ? try AccountInput.identity(account) : nil)
            }.value
            try Task.checkCancellation()
            try await vault.saveReport(report)
            self.saved = try await vault.reports()
            self.latest = report
            self.progress = "复算结果已保存"
        }
    }
    func reconcile(phone: Bool) {
        guard let vault else { return }
        let archive = self.archive
        start("正在核对 Python 对照样例") {
            self.parity = []
            self.paritySource = phone ? "手机行情库" : "旧版冻结快照"
            let task = Task.detached(priority: .userInitiated) { () async throws -> [ParityResult] in
                func progress(_ n: Int, _ total: Int) throws {
                    try Task.checkCancellation()
                    Task { @MainActor in self.progress = "逐项对账 \(n) / \(total)"; self.fraction = Double(n) / Double(total) }
                }
                if phone, let current = try await vault.phoneMarket() { return try Parity.run(phone: current, progress: progress) }
                if !phone, let archive { return try Parity.run(archive: archive, progress: progress) }
                throw ResearchError("当前未找到所选行情")
            }
            self.parity = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        }
    }
}

struct StrategyView: View {
    @EnvironmentObject var model: AppModel
    @State private var strategy = "MOM20"
    @State private var date = ""
    @State private var capital = "50000"
    @State private var current = true
    @State private var preferPhone = true
    @State private var useActual = true
    var body: some View {
        let phone = model.handset != nil && (preferPhone || model.archive == nil)
        let snapshotDay = phone ? model.handset?.market.as_of : model.archive?.manifest.snapshot.as_of
        let actual = current && useActual && model.personal != nil
        Form {
            Section("本机行情") {
                Button { model.refresh() } label: { Label(model.handset == nil ? "联网建立 28 只 ETF 行情库" : "更新 28 只 ETF 行情", systemImage: "arrow.clockwise") }
                    .disabled(model.busy)
                if let live = model.handset { LabeledContent("公开行情已核至", value: live.market.as_of) }
                if model.handset == nil { Text("首次使用可直接联网取数，在「账户」录入实际持仓。").font(.caption) }
            }
            if let snapshotDay {
                Section("行情") {
                    if model.archive != nil && model.handset != nil {
                        Picker("来源", selection: $preferPhone) {
                            Text("手机联网取得").tag(true); Text("旧资料快照").tag(false)
                        }
                    }
                    LabeledContent("当前计算来源", value: phone ? "手机行情库" : "已导入快照")
                    LabeledContent("已校验收盘", value: snapshotDay)
                }
                Section("独立方案") {
                    Picker("策略", selection: $strategy) {
                        Text("跨资产动量轮动 · MOM20").tag("MOM20")
                        Text("四类固定配置 · GB").tag("GB")
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
                Section("移植进度") {
                    Text("BANK_ELSE_GB、MV 和 SECTOR_M 尚未开放计算。")
                }
            }
            if model.busy { Section { ProgressView(value: model.fraction) { Text(model.progress) }; Button("取消", role: .cancel) { model.cancel() } } }
        }
        .navigationTitle("策略研究台")
        .onAppear { if date.isEmpty { date = snapshotDay ?? "" } }
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
