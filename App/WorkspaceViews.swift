import ResearchCore
import SwiftUI

struct FunctionOutput: Codable {
    struct Row: Codable { let label, value: String }
    struct Series: Codable { let name: String; let values: [Double?] }
    let title, text: String?
    let rows: [Row]?
    let dates: [String]?
    let series: [Series]?
}
let studyColors: [UIColor] = [.systemTeal,.systemIndigo,.systemOrange,.systemBlue,.systemPink,.systemBrown]
struct WorkspaceRoot: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Group {
            if let ws = model.workspace {
                TabView {
                    ForEach(ws.design.tabs,id:\.self) { id in
                        if let page=ws.pages[id] {
                            NavigationStack { WorkspacePage(id:id) }.tabItem { Label(page.tab ?? page.title,systemImage:page.icon) }.tag(id)
                        }
                    }
                }
            } else if model.vault != nil { NavigationStack { WorkspaceControls() } }
            else { ProgressView("正在打开股票研究台") }
        }.task(id:model.signalKey) { await model.updateDecision() }
            .onChange(of:phase) { phase in if phase == .active { model.today = (try? Sessions().completed()) ?? model.today } }
    }
}
struct WorkspacePage: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @State private var manages = false
    @ViewBuilder private func block(_ b: ScreenBlock) -> some View {
        switch b.type {
        case "group": Section(b.text ?? "") { children(b) }
        case "row": HStack(alignment:.top,spacing:12) { children(b) }
        case "stack": VStack(alignment:.leading,spacing:8) { children(b) }
        case "divider": Divider()
        case "title": Text(b.text ?? "").font(.title2.bold())
        case "text": Text(b.text ?? "")
        case "link": NavigationLink(b.text ?? model.workspace?.pages[b.target ?? ""]?.title ?? "打开") { WorkspacePage(id:b.target ?? "") }
        case "archiveLink": NavigationLink(b.text ?? "原始资料与报告") { LibraryView() }
        case "field":
            TextField(b.text ?? b.key ?? "",text:Binding(get:{ model.fields[b.key ?? ""] ?? "" },set:{ model.fields[b.key ?? ""]=$0 }))
        case "button": Button(b.text ?? "运行") { model.runAction(b.target ?? "") }.disabled(model.busy)
        case "reload": Button(b.text ?? "重新载入工作区") { model.reloadWorkspace() }.disabled(model.busy)
        case "result":
            if let output=model.widgetResults[b.target ?? ""] {
                Section(output.title ?? "结果") {
                    if let text=output.text { Text(text) }
                    ForEach(Array((output.rows ?? []).enumerated()),id:\.offset) { _,row in LabeledContent(row.label,value:row.value) }
                    if let dates=output.dates, let series=output.series {
                        MarketPlot(dates:dates,lines:series.enumerated().map { i,s in PlotLine(title:s.name,color:studyColors[i%studyColors.count],values:s.values) },
                                   identity:(b.target ?? "")+(dates.last ?? ""))
                    }
                }
            }
        case "quotes": NavigationLink(b.text ?? "ETF 和自选行情") { QuotesView() }
        case "replay": NavigationLink(b.text ?? "策略回测") { ReplayView() }
        case "account": NavigationLink(b.text ?? "我的账户") { AccountView() }
        default: MarketBlock(type:b.type)
        }
    }
    private func children(_ b: ScreenBlock) -> AnyView {
        AnyView(ForEach(Array((b.blocks ?? []).enumerated()),id:\.offset) { _,child in AnyView(block(child)) })
    }
    var body: some View {
        Group {
            if let page=model.workspace?.pages[id] {
                Group {
                    if page.blocks.count == 1, page.blocks[0].type == "quotes" { QuotesView() }
                    else if page.blocks.count == 1, page.blocks[0].type == "replay" { ReplayView() }
                    else if page.blocks.count == 1, page.blocks[0].type == "account" { AccountView() }
                    else { List { ForEach(Array(page.blocks.enumerated()),id:\.offset) { _,b in block(b) } } }
                }.navigationTitle(page.title)
            }
        }.toolbar { ToolbarItem(placement:.navigationBarTrailing) {
            Button { manages=true } label: { Image(systemName:"folder.badge.gearshape") }.accessibilityLabel("管理工作区")
        } }.sheet(isPresented:$manages) { NavigationStack { WorkspaceControls() } }
    }
}
struct WorkspaceControls: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Section("手机上的位置") {
                Text("文件 → 浏览 → 我的 iPhone → 股票研究台 → 研究工作区")
                Text("在手机 agent 中选择这个文件夹。修改「设计」里的页面、策略或功能，回到这里启用新版本。").font(.footnote)
            }
            Section("版本") {
                if let id=model.workspace?.hash { Text(String(id.prefix(16))).font(.caption.monospaced()).textSelection(.enabled) }
                Button("重新载入工作区") { model.reloadWorkspace() }.disabled(model.busy)
                Button("使用上一个已验证版本") { model.reloadWorkspace(rollback:true) }.disabled(model.busy)
                if model.busy { ProgressView(model.progress) } else if !model.progress.isEmpty { Text(model.progress).font(.caption) }
            }
        }.navigationTitle("工作区").toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
    }
}

extension AppModel {
    func runAction(_ id: String) {
        guard let w=workspace, let store else { return }
        let m=market, fields=self.fields
        start("正在运行工作区功能") {
            let result = try await Task.detached { () throws -> FunctionOutput in
                let summary: [String:Any] = m?.securities.mapValues { ["name":$0.name,"group":$0.group,"bars":$0.bars.count] as [String:Any] } ?? [:]
                var input: [String:Any]=["asOf":m?.as_of ?? "","market":summary,"fields":fields,"records":try store.inputs()]
                if let s=fields["symbol"], let sec=m?.securities[s] { input["security"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(sec)) }
                let out = try w.action(id,input:JSONSerialization.data(withJSONObject:input))
                let display=try JSONDecoder().decode(FunctionOutput.self,from:out)
                guard (display.rows?.count ?? 0) <= 10_000, (display.series?.count ?? 0) <= 30,
                      display.series?.allSatisfy({ $0.values.count == display.dates?.count }) ?? true,
                      display.text != nil || display.rows != nil || display.series != nil else { throw ResearchError("功能必须返回文字、表格或等长的图表数据") }
                try out.write(to:store.root.appendingPathComponent("输出/\(id).json"),options:.atomic)
                return display
            }.value
            self.widgetResults[id]=result; self.progress="已保存功能结果"
        }
    }
    func restoreStudies() async {
        studies=[:]
        guard let m=market, let w=workspace, let v=vault, let raw=marketID else { return }
        let key = studyKey, phone = !useArchive ? handset?.usableFrom : nil
        do {
            let data = try await Task.detached { () throws -> (String,String,[String:ReplayReport]) in
                let cal=try Sessions(), end=try cal.index(m.as_of)
                let from=phone ?? "2007-01-02"
                let earliest=cal.days.firstIndex(where:{ $0 >= from }) ?? end
                let start=cal.days[min(end,max(earliest+1,end-1259))]
                let range=try v.studyRange(market:raw,workspace:w.hash) ?? [start,m.as_of]
                let fingerprint=Integrity.sha(Data((raw+"|"+w.hash).utf8))
                var found=[String:ReplayReport]()
                for s in w.design.strategies {
                    found[s.id]=try v.savedReplay(snapshot:fingerprint,strategy:s.id,start:range[0],end:range[1])
                }
                return (range[0],range[1],found)
            }.value
            if !Task.isCancelled, studyKey == key { replayStart=data.0; replayEnd=data.1; studies=data.2 }
        } catch { if !Task.isCancelled { self.error=error.localizedDescription } }
    }
    func runStudies() {
        guard let m=market, let w=workspace, let vault, let raw=marketID else { return }
        let key=studyKey, from=replayStart, end=replayEnd, warmup=useArchive ? nil : handset?.usableFrom
        start("准备本机回测") {
            let task=Task.detached(priority:.userInitiated) {
                let cal=try Sessions()
                guard try cal.index(from) <= cal.index(end), end <= m.as_of, warmup.map({ from > $0 }) ?? true else { throw ResearchError("起止日须为有效交易日，并在行情完成暖机之后") }
                try vault.setStudyRange([from,end],market:raw,workspace:w.hash)
                let stamp=Integrity.sha(Data((raw+"|"+w.hash).utf8))
                let engine=StrategyEngine(market:m,sessions:cal,workspace:w)
                for (i,s) in w.design.strategies.enumerated() {
                    try Task.checkCancellation()
                    let old=try vault.savedReplay(snapshot:stamp,strategy:s.id,start:from,end:end)
                    let r=try engine.replay(s.id,snapshot:stamp,start:from,end:end,resume:old) { state,progress in
                        try vault.storeReplay(state)
                        Task { @MainActor in self.progress="\(s.short) · \(state.outcomeDate)"; self.fraction=(Double(i)+progress)/Double(w.design.strategies.count) }
                    }
                    await MainActor.run { if self.studyKey == key { self.studies[s.id]=r } }
                }
            }
            try await withTaskCancellationHandler(operation:{ try await task.value },onCancel:{ task.cancel() })
            self.progress="回测已保存"
        }
    }
}

struct ReplayView: View {
    @EnvironmentObject var model: AppModel
    @State private var dd=false
    var body: some View {
        List {
            Section("独立区间 · 每套初始 50,000 元") {
                TextField("起始交易日 YYYY-MM-DD",text:$model.replayStart)
                TextField("结束交易日 YYYY-MM-DD",text:$model.replayEnd)
                Button("计算或续跑全部策略") { model.runStudies() }.disabled(model.busy || model.market == nil)
                if model.busy { ProgressView(value:model.fraction) { Text(model.progress) }; Button("暂停") { model.cancel() } }
                Text("首次按上一交易日收盘选取，随后月末换仓，按策略检查保护退出。下一交易日以原始开盘价模拟成交，计入整手、涨跌停、分红、佣金和滑点。").font(.caption)
            }
            let reports=(model.workspace?.design.strategies ?? []).compactMap { s -> (StrategyFile,ReplayReport)? in
                guard let r=model.studies[s.id], r.finished, r.start==model.replayStart, r.end==model.replayEnd else { return nil }; return (s,r)
            }
            if let first=reports.first {
                let dates=first.1.curve.map(\.date)
                Section("同区间策略对照") {
                    Picker("指标",selection:$dd) { Text("净值").tag(false); Text("回撤").tag(true) }.pickerStyle(.segmented)
                    MarketPlot(dates:dates,lines:reports.enumerated().map { i,p in
                        PlotLine(title:p.0.short,color:studyColors[i%studyColors.count],values:p.1.curve.map { dd ? $0.drawdown : $0.equity/p.1.capital })
                    },isPercent:dd,identity:model.studyKey+first.1.start+first.1.end+String(dd))
                }
            }
            if model.market == nil { Text("请先在市场页获取行情。") }
        }.navigationTitle("策略回测")
    }
}
struct OutcomeSection: View {
    @EnvironmentObject var model: AppModel
    let strategy,symbol,name: String
    var body: some View {
        Section("\(name) · 盈利概率") {
            if let r=model.studies[strategy], r.finished, let d=model.decision,
               strategy == d.strategy, r.end <= d.date {
                let e=r.evidence(symbol:symbol,route:d.route,asOf:d.date)
                LabeledContent("历史扣费盈利",value:e.count > 0 ? "\(e.wins) / \(e.count) · "+percent(Double(e.wins)/Double(e.count)) : "0 笔完整周期")
                LabeledContent("本次持有至退出",value:e.forecast.map { percent($0) } ?? "证据不足")
                Text("\(r.start) 至 \(r.end)，由首次建仓至全部退出。"+e.reason).font(.caption)
            } else {
                Text("运行回测后显示该 ETF 的已平仓笔数、历史净盈利比例及本次预测的可用样本。").font(.footnote)
                Button("计算历史样本") { model.runStudies() }.disabled(model.busy || model.replayStart.isEmpty)
            }
        }
    }
}
