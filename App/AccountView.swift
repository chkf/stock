import ResearchCore
import SwiftUI

struct AccountView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing = false
    var body: some View {
        List {
            if let account = model.personal {
                Section("已确认账户") {
                    LabeledContent("收盘日", value: account.as_of)
                    LabeledContent("可用现金", value: String(format: "%.2f 元", account.cash))
                }
                Section("实际持仓") {
                    if account.positions.isEmpty { Text("已确认空仓") }
                    ForEach(account.positions, id: \.symbol) { p in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.handset?.market.securities[p.symbol]?.name ?? model.names[p.symbol] ?? p.symbol)
                            Text("\(p.symbol)　持有 \(p.quantity)　可卖 \(p.available)").font(.subheadline)
                            if let day = p.entry_date { Text("连续持有自 \(day)").font(.caption) }
                            if let close = p.close { Text("该日补录收盘价 \(close.formatted()) 元").font(.caption) }
                        }
                    }
                }
            } else {
                Section { Text("首次使用，照着券商账户填一次即可。没有持仓时可只填现金。") }
            }
            Button(model.personal == nil ? "录入我的账户" : "更新并确认账户") { editing = true }
                .disabled(model.vault == nil)
            NavigationLink("按账户计算参考份额") { StrategyView() }
            NavigationLink("历史报告") { HistoryView() }
            if model.personal != nil { NavigationLink("查看已确认的账户记录") { AccountHistoryView() } }
        }
        .navigationTitle("我的账户")
        .sheet(isPresented: $editing) {
            NavigationStack { AccountEditor(account: model.personal) }
        }
    }
}

struct AccountHistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var versions = [PrivateLibrary.PersonalRecord]()
    var body: some View {
        List(versions) { version in
            NavigationLink {
                AccountRecordView(id: version.id)
            } label: {
                VStack(alignment: .leading) {
                    Text(version.account.as_of)
                    Text(String(format: "现金 %.2f 元　%ld 只持仓", version.account.cash, version.account.positions.count))
                        .font(.caption)
                }
            }
        }.navigationTitle("已确认记录")
            .task {
                do { versions = try await model.vault?.personalHistory() ?? [] }
                catch { model.error = error.localizedDescription }
            }
    }
}

struct AccountRecordView: View {
    let id: String
    @EnvironmentObject var model: AppModel
    @State private var account: Account?
    var body: some View {
        List {
            if let account {
                LabeledContent("收盘日", value: account.as_of)
                LabeledContent("可用现金", value: String(format: "%.2f 元", account.cash))
                if account.positions.isEmpty { Text("已确认空仓") }
                ForEach(account.positions, id: \.symbol) { p in
                    VStack(alignment: .leading) {
                        Text(p.symbol)
                        Text("持有 \(p.quantity)　可卖 \(p.available)")
                        if let day = p.entry_date { Text("连续持有自 \(day)") }
                        if let close = p.close { Text("确认日补价 \(close.formatted()) 元") }
                    }
                }
                LabeledContent("佣金率", value: account.fees.commission_rate.formatted())
                LabeledContent("最低佣金", value: String(format: "%.2f 元", account.fees.minimum_commission))
                LabeledContent("滑点率", value: account.fees.slippage_rate.formatted())
            }
            Text(id).font(.caption.monospaced()).textSelection(.enabled)
        }.navigationTitle("当次账户")
            .task {
                do { account = try await model.vault?.personalRecord(id: id) }
                catch { model.error = error.localizedDescription }
            }
    }
}

private struct PositionDraft: Identifiable {
    let id = UUID()
    var symbol = "", quantity = "", available = "", close = "", entry = ""
    init(_ p: Position? = nil) {
        if let p {
            symbol = p.symbol; quantity = String(p.quantity); available = String(p.available)
            close = p.close.map { String($0) } ?? ""; entry = p.entry_date ?? ""
        }
    }
    func value() throws -> Position {
        guard let q = Int(quantity), let a = Int(available), q >= 0, (0...q).contains(a) else {
            throw ResearchError("请逐只填写整数份额。可卖份额不能超过持有份额。")
        }
        let supplemental: Double?
        if close.isEmpty { supplemental = nil }
        else if let x = Double(close), x.isFinite, x > 0 { supplemental = x }
        else { throw ResearchError("补录收盘价需为正数") }
        return Position(symbol: try AccountInput.symbol(symbol), quantity: q, available: a,
                        close: supplemental, entry: entry.isEmpty ? nil : entry)
    }
}

struct AccountEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var day: String
    @State private var cash: String
    @State private var rows: [PositionDraft]
    @State private var commission: String
    @State private var minimum: String
    @State private var slippage: String
    @State private var failure: String?
    @State private var saving = false

    init(account: Account?) {
        _day = State(initialValue: account?.as_of ?? ((try? Sessions().completed()) ?? ""))
        _cash = State(initialValue: account.map { String($0.cash) } ?? "")
        _rows = State(initialValue: account?.positions.map { PositionDraft($0) } ?? [])
        let fees = account?.fees ?? Fees()
        _commission = State(initialValue: String(fees.commission_rate))
        _minimum = State(initialValue: String(fees.minimum_commission))
        _slippage = State(initialValue: String(fees.slippage_rate))
    }
    var body: some View {
        Form {
            Section("账户余额") {
                LabeledContent("收盘日期") { TextField("YYYY-MM-DD", text: $day).keyboardType(.numbersAndPunctuation) }
                LabeledContent("可用现金（元）") { TextField("填写金额", text: $cash).keyboardType(.decimalPad) }
            }.multilineTextAlignment(.trailing)
            Section {
                ForEach($rows) { $row in
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("证券代码") { TextField("六位代码", text: $row.symbol).textInputAutocapitalization(.characters).autocorrectionDisabled() }
                        LabeledContent("持有份额") { TextField("实际持有", text: $row.quantity).keyboardType(.numberPad) }
                        LabeledContent("可卖份额") { TextField("当日可卖", text: $row.available).keyboardType(.numberPad) }
                        LabeledContent("持仓起始日") { TextField("选填 YYYY-MM-DD", text: $row.entry).keyboardType(.numbersAndPunctuation) }
                        LabeledContent("当日收盘价") { TextField("选填 元", text: $row.close).keyboardType(.decimalPad) }
                    }.multilineTextAlignment(.trailing)
                }.onDelete { rows.remove(atOffsets: $0) }
                Button("添加一只持仓") { rows.append(PositionDraft()) }
            } header: { Text("实际持仓") } footer: {
                Text("可卖份额按券商显示填写。缺少行情的证券可补录本日收盘价，改变日期会清除补价。")
            }
            Section {
                DisclosureGroup("费用设置") {
                    LabeledContent("佣金率") { TextField("0.0003", text: $commission).keyboardType(.decimalPad) }
                    LabeledContent("最低佣金（元）") { TextField("5", text: $minimum).keyboardType(.decimalPad) }
                    LabeledContent("滑点率") { TextField("0.0005", text: $slippage).keyboardType(.decimalPad) }
                }.multilineTextAlignment(.trailing)
            }
            Section {
                if let failure { Text(failure).foregroundStyle(.red) }
                Button("确认以上为我的真实现金与持仓") {
                    saving = true
                    Task { await submit() }
                }.disabled(saving || day.isEmpty || cash.isEmpty)
            }
        }
        .navigationTitle("录入账户")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .onChange(of: day) { _ in for i in rows.indices { rows[i].close = "" } }
    }
    @MainActor private func submit() async {
        defer { saving = false }
        do {
            guard let amount = Double(cash) else { throw ResearchError("请填写可用现金，金额可为零") }
            guard let rate = Double(commission), let minFee = Double(minimum), let slip = Double(slippage) else {
                throw ResearchError("请填写佣金率、最低佣金和滑点率")
            }
            var fees = Fees()
            fees.commission_rate = rate; fees.minimum_commission = minFee; fees.slippage_rate = slip
            let account = Account(date: day, cash: amount, positions: try rows.map { try $0.value() }, confirmed: true, fees: fees)
            try await model.saveAccount(account)
            dismiss()
        } catch { failure = error.localizedDescription }
    }
}
