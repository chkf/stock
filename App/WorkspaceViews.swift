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
            .task(id:phase) {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    model.processFileRequest()
                    do { try await Task.sleep(nanoseconds:3_000_000_000) } catch { return }
                }
            }
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
        case "field","dateField":
            if b.key == "replayStart" { StudyCoverageView(); StudyDateRow(start:true) }
            else if b.key == "replayEnd" { StudyDateRow(start:false) }
            else { TextField(b.text ?? b.key ?? "",text:Binding(get:{ model.fields[b.key ?? ""] ?? "" },set:{ model.fields[b.key ?? ""]=$0 })) }
        case "command","accountBalance","holdings","watchRows","etfRows","job","nativeLink":
            WorkspaceDataBlock(b:b)
        case "studyChart": StudyChartBlock(title:b.text ?? "策略对照")
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
        default: MarketBlock(type:b.type,target:b.target)
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

private struct WorkspaceDataBlock: View {
    @EnvironmentObject var model: AppModel
    let b: ScreenBlock
    var body: some View {
        switch b.type {
        case "command":
            Button(b.text ?? "执行") {
                switch b.target {
                case "watch.add": model.editWatch(model.fields["symbol"] ?? "")
                case "market.refresh": model.refresh()
                case "study.run": model.runStudies()
                case "job.cancel": model.cancel()
                default: break
                }
            }.disabled((b.target != "job.cancel" && model.busy) || (b.target == "study.run" && model.rangeProblem != nil) || (b.target == "watch.add" && (model.fields["symbol"] ?? "").isEmpty))
        case "job":
            if model.busy { Section { ProgressView(value:model.fraction) { Text(model.progress) }; Button("暂停") { model.cancel() } } }
        case "accountBalance":
            if let a=model.personal { LabeledContent("收盘日",value:a.as_of); LabeledContent("可用现金",value:String(format:"%.2f 元",a.cash)) }
            else { Text("尚未录入真实账户。").foregroundStyle(.secondary) }
        case "holdings":
            if let a=model.personal {
                if a.positions.isEmpty { Text("已确认空仓") }
                ForEach(a.positions,id:\.symbol) { p in VStack(alignment:.leading) {
                    Text(model.market?.securities[p.symbol]?.name ?? p.symbol)
                    Text("\(p.symbol) · 持有 \(p.quantity) · 可卖 \(p.available)").font(.subheadline)
                    if let day=p.entry_date { Text("自 \(day) 持有").font(.caption) }
                    if let close=p.close { Text("补录收盘 \(close.formatted()) 元").font(.caption) }
                } }
            }
        case "watchRows":
            ForEach(model.watch) { w in NavigationLink { QuoteDetail(symbol:w.symbol) } label: { LabeledContent(w.name,value:w.symbol) }
                    .swipeActions { Button("移除",role:.destructive) { model.editWatch(w.symbol,remove:true) } } }
        case "etfRows":
            if let m=model.market {
                let q=model.fields["query"] ?? ""
                ForEach(m.securities.keys.sorted().filter { q.isEmpty || $0.contains(q) || m.securities[$0]!.name.contains(q) },id:\.self) { s in
                    NavigationLink { QuoteDetail(symbol:s) } label: { LabeledContent(m.securities[s]!.name,value:s) }
                }
            } else { Button("获取 ETF 行情") { model.refresh() }.disabled(model.busy) }
        case "nativeLink":
            switch b.target {
            case "account.edit": NavigationLink(b.text ?? "录入账户") { AccountEditor(account:model.personal) }
            case "account.history": NavigationLink(b.text ?? "账户记录") { AccountHistoryView() }
            case "account.plan": NavigationLink(b.text ?? "参考份额") { StrategyView() }
            case "reports": NavigationLink(b.text ?? "历史报告") { HistoryView() }
            case "archive": NavigationLink(b.text ?? "原始资料") { LibraryView() }
            default: EmptyView()
            }
        default: EmptyView()
        }
    }
}

extension AppModel {
    func confirmStudyDay(_ day:String,start:Bool) {
        if start { replayStart=day } else { replayEnd=day }
        guard let vault,let id=marketID,let workspace,ExchangeDay.date(replayStart) != nil,ExchangeDay.date(replayEnd) != nil else { return }
        do { try vault.setStudyRange([replayStart,replayEnd],market:id,workspace:workspace.hash) }
        catch { self.error=error.localizedDescription }
    }
    func runAction(_ id: String,request:WorkspaceTicket? = nil) {
        guard let w=workspace, let store else { return }
        let m=market, fields=request?.request.fields ?? (request == nil ? self.fields : [:])
        start("正在运行工作区功能",request:request) {
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
        studies=[:]; coverage=nil; coverageError=""; replayStart=""; replayEnd=""
        guard let m=market, let w=workspace, let v=vault, let raw=marketID else { coverageError=origin.title+"尚无可读快照"; return }
        let key=studyKey, strategy=studyStrategy
        do {
            let data = try await Task.detached { () throws -> (String,String,[String:ReplayReport],HistoryCoverage) in
                let definitions=w.design.strategies.filter { strategy.isEmpty || $0.id==strategy }
                let coverage=try HistoryCoverage(market:m,sessions:Sessions(),strategies:definitions)
                let window=coverage.windows.last
                let range=try v.studyRange(market:raw,workspace:w.hash) ?? [window?.start ?? "",window?.end ?? ""]
                let fingerprint=ReplayReport.fingerprint(market:raw,workspace:w.hash)
                var found=[String:ReplayReport]()
                for s in definitions where coverage.problem(start:range[0],end:range[1])==nil {
                    found[s.id]=try v.savedReplay(snapshot:fingerprint,strategy:s.id,start:range[0],end:range[1])
                }
                return (range[0],range[1],found,coverage)
            }.value
            if !Task.isCancelled, studyKey == key { replayStart=data.0; replayEnd=data.1; studies=data.2; coverage=data.3 }
        } catch { if !Task.isCancelled,studyKey==key { coverageError=error.localizedDescription } }
    }
    func runStudies() {
        guard let m=market, let w=workspace, let vault, let raw=marketID else { return }
        guard let coverage,rangeProblem==nil else { self.error=rangeProblem; return }
        let key=studyKey, from=replayStart, end=replayEnd, selection=studyStrategy
        start("准备本机回测") {
            let task=Task.detached(priority:.userInitiated) {
                let cal=try Sessions()
                if let reason=coverage.problem(start:from,end:end,completed:try cal.completed()) { throw ResearchError(reason) }
                try vault.setStudyRange([from,end],market:raw,workspace:w.hash)
                let stamp=ReplayReport.fingerprint(market:raw,workspace:w.hash)
                let engine=StrategyEngine(market:m,sessions:cal,workspace:w)
                let definitions=w.design.strategies.filter { selection.isEmpty || $0.id==selection }
                for (i,s) in definitions.enumerated() {
                    try Task.checkCancellation()
                    let old=try vault.savedReplay(snapshot:stamp,strategy:s.id,start:from,end:end)
                    let r=try engine.replay(s.id,snapshot:stamp,start:from,end:end,resume:old) { state,progress in
                        try vault.storeReplay(state)
                        Task { @MainActor in self.progress="\(s.short) · \(state.outcomeDate)"; self.fraction=(Double(i)+progress)/Double(definitions.count) }
                    }
                    await MainActor.run { if self.studyKey == key { self.studies[s.id]=r } }
                }
            }
            try await withTaskCancellationHandler(operation:{ try await task.value },onCancel:{ task.cancel() })
            self.progress="回测已保存"
        }
    }
}

struct MarketSourceControl:View {
    @EnvironmentObject var model:AppModel
    var body:some View {
        Picker("行情来源",selection:Binding(get:{ model.origin },set:{ model.selectOrigin($0) })) {
            Text("本机行情").tag(MarketOrigin.phone); Text("导入快照").tag(MarketOrigin.archive)
        }.pickerStyle(.segmented).accessibilityIdentifier("market.origin").disabled(model.busy)
        if let id=model.marketID { Text("快照 "+id).font(.caption.monospaced()).textSelection(.enabled) }
        else { Text(model.origin.title+"尚无可读快照").foregroundStyle(.secondary) }
    }
}
private struct StudyCoverageView:View {
    @EnvironmentObject var model:AppModel
    var body:some View {
        MarketSourceControl()
        Picker("研究策略",selection:$model.studyStrategy) {
            Text("全部策略").tag("")
            ForEach(model.workspace?.design.strategies ?? []) { s in Text(s.short).tag(s.id) }
        }.disabled(model.busy)
        if let c=model.coverage {
            LabeledContent("行情请求范围",value:c.from+" 至 "+c.through)
            if let first=c.securities.compactMap(\.firstBar).min(),let last=c.securities.compactMap(\.lastBar).max() {
                LabeledContent("实际原价范围",value:first+" 至 "+last)
            }
            if let w=c.windows.last { LabeledContent("最近已核区间",value:w.start+" 至 "+w.end) }
            else { Text("当前快照没有可运行的区间") }
            Text("起日前一交易日需有合格样本，最长预热 \(c.warmup) 个交易日。选定起日合格 \(c.sampleCount(on:model.replayStart)) 只。").font(.footnote)
            NavigationLink("覆盖明细 · \(c.securities.reduce(0){$0+$1.missingDays}) 个证券缺日") {
                List {
                    Section("连续可回测区间") { ForEach(c.windows,id:\.start) { w in Text(w.start+" 至 "+w.end) } }
                    Section("待核原因") { ForEach(Array(c.issues.enumerated()),id:\.offset) { _,i in Text(i.message) } }
                    Section("逐证券覆盖") { ForEach(c.securities,id:\.symbol) { s in
                        NavigationLink {
                            List {
                                if s.gaps.isEmpty { Text("请求区间内每天都有原价") }
                                ForEach(s.gaps,id:\.start) { g in
                                    VStack(alignment:.leading) {
                                        Text(g.start+" 至 "+g.end+" · \(g.days) 日")
                                        Text(g.state.title).font(.subheadline)
                                        if let ref=g.evidence { Text(ref).font(.caption).textSelection(.enabled) }
                                    }
                                }
                            }.navigationTitle(s.symbol)
                        } label: {
                            VStack(alignment:.leading) { Text(s.symbol); Text("原价 \(s.firstBar ?? "无") 至 \(s.lastBar ?? "无")\n信号 \(s.firstSignal ?? "无") 至 \(s.lastSignal ?? "无")\n上市凭证 \(s.listed ?? "未知") · 缺日 \(s.missingDays)").font(.caption) }
                        }
                    } }
                }.navigationTitle("核验明细")
            }
        }
        if let problem=model.rangeProblem { Text(problem).font(.footnote).foregroundStyle(.orange) }
    }
}
private struct StudyDateRow:View {
    @EnvironmentObject var model:AppModel
    let start:Bool
    @State private var editing=false
    @State private var draft=Date()
    private var value:String { start ? model.replayStart : model.replayEnd }
    private var bounds:ClosedRange<Date>? {
        guard let c=model.coverage,let first=c.windows.first,let last=c.windows.last,let lo=ExchangeDay.date(first.start),let hi=ExchangeDay.date(last.end) else { return nil }
        return lo...hi
    }
    var body:some View {
        Button {
            guard let bounds else { return }; draft=ExchangeDay.date(value).flatMap { bounds.contains($0) ? $0 : nil } ?? (start ? bounds.lowerBound : bounds.upperBound)
            editing=true
        } label: { LabeledContent(start ? "起始交易日" : "结束交易日",value:value.isEmpty ? "选择日期" : value) }
        .accessibilityLabel(start ? "起始交易日" : "结束交易日").accessibilityValue(value)
        .accessibilityIdentifier(start ? "replay.start" : "replay.end")
        .disabled(bounds==nil || model.busy)
        .sheet(isPresented:$editing) {
            NavigationStack {
                if let bounds {
                    VStack {
                        DatePicker("交易日",selection:$draft,in:bounds,displayedComponents:.date)
                            .accessibilityIdentifier("replay.wheel")
                            .datePickerStyle(.wheel).environment(\.calendar,ExchangeDay.calendar).environment(\.timeZone,ExchangeDay.zone).environment(\.locale,Locale(identifier:"zh_CN"))
                        let day=ExchangeDay.string(draft)
                        if let issue=model.coverage?.problem(start:start ? day:model.replayStart,end:start ? model.replayEnd:day,completed:model.today.isEmpty ? nil:model.today) {
                            Text(issue).font(.footnote).foregroundStyle(.orange)
                        }
                    }.navigationTitle(start ? "起始交易日" : "结束交易日")
                    .toolbar {
                        ToolbarItem(placement:.cancellationAction) { Button("取消") { editing=false }.accessibilityIdentifier("replay.cancel") }
                        ToolbarItem(placement:.confirmationAction) { Button("确认") {
                            model.confirmStudyDay(ExchangeDay.string(draft),start:start); editing=false
                        }.accessibilityIdentifier("replay.confirm") }
                    }
                }
            }.presentationDetents([.medium])
        }
    }
}
struct HistoryDownloadView:View {
    @EnvironmentObject var model:AppModel
    @State private var from=Date(), through=Date()
    @State private var calendar:Sessions?
    @State private var last=""
    @State private var loadError=""
    private var invalid:String? {
        guard let calendar else { return loadError.isEmpty ? "正在读取交易日历" : loadError }
        let a=ExchangeDay.string(from),b=ExchangeDay.string(through)
        guard (try? calendar.index(a)) != nil,(try? calendar.index(b)) != nil else { return "起止日期须为交易日" }
        guard a<=b,b<=last else { return "起止倒置或尚未收盘" }
        if let previous=model.handset?.market.as_of,b<previous { return "本机已有行情至 "+previous+"，请选择相同或更晚截止日" }
        return nil
    }
    var body:some View {
        Form {
            DatePicker("历史起点",selection:$from,displayedComponents:.date)
            DatePicker("目标截止日",selection:$through,displayedComponents:.date)
            if let invalid { Text(invalid).font(.footnote).foregroundStyle(.orange) }
            Text("补历史会分证券、分页保存原响应。已有截止日也能向前补。缺公告、缺原价或出现修订时保留候选及诊断。").font(.footnote)
            Button("下载并核验候选") { model.refresh(from:ExchangeDay.string(from),through:ExchangeDay.string(through)) }.disabled(invalid != nil || model.busy)
            if model.busy { ProgressView(value:model.fraction); Button("暂停") { model.cancel() } }
            if !model.progress.isEmpty { Text(model.progress) }
            if model.handset != nil {
                Button("恢复上一代本机行情") {
                    guard let vault=model.vault else { return }
                    model.start("正在核对上一代行情") {
                        model.handset=try await vault.restorePreviousPhoneMarket()
                        model.progress="已恢复经校验的上一代本机行情"
                    }
                }.disabled(model.busy)
            }
        }.navigationTitle("历史行情回填").environment(\.calendar,ExchangeDay.calendar).environment(\.timeZone,ExchangeDay.zone)
        .task { do {
            let c=try Sessions(),day=try c.completed()
            calendar=c; last=day; through=ExchangeDay.date(day) ?? Date()
            from=ExchangeDay.date(model.handset?.market.history?.from ?? model.handset?.market.securities.values.compactMap { $0.bars.keys.min() }.min() ?? day) ?? through
        } catch { loadError=error.localizedDescription } }
    }
}
struct ReplayView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            Section("回测区间") {
                StudyCoverageView()
                StudyDateRow(start:true); StudyDateRow(start:false)
                Button("计算或续跑") { model.runStudies() }.disabled(model.busy || model.rangeProblem != nil)
                if model.busy { ProgressView(value:model.fraction) { Text(model.progress) }; Button("暂停") { model.cancel() } }
                Text("首次按上一交易日收盘选取，随后月末换仓，按策略检查保护退出。下一交易日以原始开盘价模拟成交，计入整手、涨跌停、分红、佣金和滑点。").font(.caption)
            }
            StudyChartBlock(title:"同区间策略对照")
            if model.market == nil { Text("请先在市场页获取行情。") }
        }.navigationTitle("策略回测")
    }
}
private struct StudyChartBlock: View {
    @EnvironmentObject var model: AppModel
    let title: String
    @State private var dd=false
    var body: some View {
            let reports=(model.workspace?.design.strategies ?? []).compactMap { s -> (StrategyFile,ReplayReport)? in
                guard let r=model.studies[s.id], r.finished, r.start==model.replayStart, r.end==model.replayEnd else { return nil }; return (s,r)
            }
            if let first=reports.first {
                let dates=first.1.curve.map(\.date)
                Section(title) {
                    Picker("指标",selection:$dd) { Text("净值").tag(false); Text("回撤").tag(true) }.pickerStyle(.segmented)
                    MarketPlot(dates:dates,lines:reports.enumerated().map { i,p in
                        PlotLine(title:p.0.short,color:studyColors[i%studyColors.count],values:p.1.curve.map { dd ? $0.drawdown : $0.equity/p.1.capital })
                    },isPercent:dd,identity:model.studyKey+first.1.start+first.1.end+String(dd))
                }
            }
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
                Button("计算历史样本") { model.runStudies() }.disabled(model.busy || model.rangeProblem != nil)
            }
        }
    }
}
