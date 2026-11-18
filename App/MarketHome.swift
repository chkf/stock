import SwiftUI
import ResearchCore

func percent(_ value: Double, _ digits: Int = 1) -> String { String(format: "%.*f%%", digits, 100 * value) }
private func regime(_ value: String) -> String {
    ["BULL":"强势","BEAR":"弱势","TRANSITION":"过渡","UNKNOWN":"资料不足"][value] ?? value
}
struct MarketBlock: View {
    @EnvironmentObject var model: AppModel
    let type: String
    let target: String?
    var body: some View {
        if type == "marketUpdate" {
            Section {
                Button { model.refresh() } label: { Label(model.handset == nil ? "联网获取 28 只 ETF" : "更新收盘行情",systemImage:"arrow.clockwise") }.disabled(model.busy || model.vault == nil)
                if model.archivedMarket != nil && model.handset != nil { Toggle("使用导入的历史快照",isOn:$model.preferArchive) }
                if model.busy { ProgressView(value:model.fraction) { Text(model.progress) }; Button("取消") { model.cancel() } }
            }
        } else if type == "strategyPicker", let w = model.workspace {
            Section {
                if w.design.strategies.count <= 5 {
                    Picker("策略",selection:$model.selectedStrategy) { ForEach(w.design.strategies) { Text($0.short).tag($0.id) } }.pickerStyle(.segmented)
                } else { Picker("策略",selection:$model.selectedStrategy) { ForEach(w.design.strategies) { Text($0.title).tag($0.id) } } }
                Text(model.selectedFile?.title ?? model.selectedStrategy).font(.caption).foregroundStyle(.secondary)
            }
        } else if let m = model.market, let d = model.decision, d.strategy == model.selectedStrategy, d.date == m.as_of {
            if type == "strength", target == nil || d.strategy == target { StrengthCard(d:d) }
            if type == "outlook", let s = leadersFirst(d,m) { OutcomeSection(strategy:d.strategy,symbol:s,name:m.securities[s]?.name ?? s) }
            if type == "decision" {
                let stale = m.as_of < model.today
                Section(stale ? "历史判断 · \(d.date)" : "下一交易日 · \(model.next)") {
                    VStack(alignment:.leading,spacing:8) {
                        Text(d.headline ?? d.route).font(.title2.bold())
                        Text("A 股\(regime(d.marketState)) · \(d.date) 收盘").font(.subheadline)
                        if let why=d.rationale { Text(why).font(.callout).foregroundStyle(.secondary) }
                        if stale { Label("该判断只对应 \(model.next)，请更新行情。",systemImage:"clock").font(.caption).foregroundStyle(.orange) }
                    }.padding(.vertical,3)
                    ForEach(Array(ranked(d,m).filter { $0.place != nil }.prefix(3))) { item in
                        NavigationLink { QuoteDetail(symbol:item.symbol) } label: {
                            HStack { VStack(alignment:.leading) { Text(m.securities[item.symbol]?.name ?? item.symbol); Text(item.symbol).font(.caption).foregroundStyle(.secondary) }
                                Spacer(); Text(percent(item.weight ?? 0)).monospacedDigit() }
                        }
                    }
                    let cash = max(0,1-d.weights.values.reduce(0,+))
                    if cash > 1e-8 { LabeledContent("目标现金",value:percent(cash)) }
                    NavigationLink("查看全部 28 只 ETF 排名") { RankingView(d:d,market:m) }
                }
            }
        } else if type == "decision" {
            Section { if model.market == nil { Text("获取 28 只 ETF 行情后，下一交易日的配置会出现在这里。") }
                else if !model.signalReason.isEmpty { Text(model.signalReason) } else { ProgressView("正在本机计算") } }
        }
    }
}
struct StrengthCard: View {
    let d: Decision
    var body: some View {
        Section("离强势还差多少") {
            if let v = d.strength {
                VStack(alignment: .leading, spacing: 16) {
                    Text("两道门槛各需 \(v.required) / \(v.eligible) 只 A 股 ETF 达标").font(.headline)
                    StrengthBar(days: 60, votes: v.shortVotes, eligible: v.eligible, gap: v.shortGap, threshold: v.threshold)
                    StrengthBar(days: 200, votes: v.longVotes, eligible: v.eligible, gap: v.longGap, threshold: v.threshold)
                    Text("收盘价高于对应均线，且均线高于 20 个交易日前，计为一只达标。两项均达 \(percent(v.threshold,0)) 时判为强势。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if d.marketState == "BEAR" {
                        Text("偏弱依据：60 日有 \(v.shortDown) 只、200 日有 \(v.longDown) 只处于均线下方且均线下行。任一项达到 \(v.required) 只即触发。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 3)
            } else { Text("没有具备完整 252 个交易日记录的 A 股 ETF，暂时无法计算距离。") }
        }
    }
}

private struct StrengthBar: View {
    let days, votes, eligible, gap: Int
    let threshold: Double
    var body: some View {
        let fraction = Double(votes)/Double(eligible)
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text("\(days) 日趋势").fontWeight(.medium); Spacer()
                Text(gap == 0 ? "已达标" : "还差 \(gap) 只").fontWeight(.semibold).foregroundStyle(gap == 0 ? Color.green : Color.primary) }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.16)).frame(height: 7)
                    Capsule().fill(days == 60 ? Color.teal : Color.indigo).frame(width: geo.size.width*fraction, height: 7)
                    Rectangle().fill(Color.primary).frame(width: 2, height: 15).offset(x: geo.size.width*threshold-1)
                }.frame(height: 16)
            }.frame(height: 16)
            HStack { Text("\(votes) / \(eligible) 只 · \(percent(fraction))"); Spacer(); Text("门槛 \(percent(threshold, 0))") }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}
private struct RankRow: Identifiable {
    let symbol: String, weight: Double?, place: Int?
    var id: String { symbol }
}
private func ranked(_ d: Decision, _ m: MarketSnapshot) -> [RankRow] {
    let keys = m.securities.keys.sorted {
        let a = d.weights[$0] ?? 0, b = d.weights[$1] ?? 0
        if a != b { return a > b }
        let x = d.scores[$0] ?? -.infinity, y = d.scores[$1] ?? -.infinity
        return x != y ? x > y : $0 < $1
    }
    var rank = 0, previous = -1.0
    return keys.enumerated().map { index, s in
        let w = d.weights[s] ?? 0
        if abs(w-previous) > 1e-10 { rank = index+1; previous = w }
        return RankRow(symbol: s, weight: d.weights[s], place: w > 0 ? rank : nil)
    }
}
private func leadersFirst(_ d: Decision, _ m: MarketSnapshot) -> String? { ranked(d,m).first { $0.place != nil }?.symbol }
private struct RankingView: View {
    let d: Decision, market: MarketSnapshot
    var body: some View {
        List {
            Section { Text("\(d.date) 收盘 · 按当前策略的目标权重排名，同权重并列。").font(.footnote) }
            ForEach(ranked(d,market)) { row in
                NavigationLink { QuoteDetail(symbol: row.symbol) } label: {
                    HStack {
                        Text(row.place.map(String.init) ?? "—").monospacedDigit().foregroundStyle(.secondary).frame(width: 23)
                        VStack(alignment: .leading) {
                            Text(market.securities[row.symbol]?.name ?? row.symbol)
                            Text(row.symbol).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(row.weight.map { percent($0) } ?? "未配置")
                            if let score = d.scores[row.symbol] { Text("年动量 \(percent(score))").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }.navigationTitle("28 ETF 排行")
    }
}
