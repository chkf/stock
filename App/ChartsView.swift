import SwiftUI
import UIKit
import ResearchCore

struct PlotLine {
    let title: String
    let color: UIColor
    let values: [Double?]
}
struct PlotMarker { let index: Int; let buy: Bool }
struct MarketPlot: View {
    let dates: [String], lines: [PlotLine]
    var markers: [PlotMarker] = []
    var isPercent = false
    var identity: String
    @State private var range = 126
    @State private var reading: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !dates.isEmpty && !lines.isEmpty {
                HStack {
                    ForEach([(21,"1月"),(63,"3月"),(126,"半年"),(252,"1年"),(0,"全部")], id: \.0) { n,label in
                        Button(label) { range = n; reading = nil }
                            .buttonStyle(.borderless).font(.caption.weight(range == n ? .bold : .regular))
                            .frame(maxWidth: .infinity)
                    }
                }
                PlotSurface(dates: dates, lines: lines, markers: markers, percent: isPercent, window: range,
                            identity: identity, reading: $reading).frame(height: 216)
                let index = min(max(0,reading ?? dates.count-1), dates.count-1)
                Text(dates[index]).font(.caption.monospacedDigit())
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if line.values.indices.contains(index), let v = line.values[index] {
                        HStack { Circle().fill(Color(uiColor: line.color)).frame(width: 8,height: 8)
                            Text(line.title); Spacer(); Text(isPercent ? percent(v,2) : String(format: "%.3f",v)).monospacedDigit() }.font(.caption)
                    }
                }
                Text("双指缩放，左右拖动，轻点或长按读数。").font(.caption2).foregroundStyle(.secondary)
            } else { Text("当前区间没有可绘制的数据。") }
        }.onChange(of: identity) { _ in reading = nil }
    }
}
private struct PlotSurface: UIViewRepresentable {
    let dates: [String], lines: [PlotLine], markers: [PlotMarker], percent: Bool, window: Int, identity: String
    @Binding var reading: Int?
    func makeUIView(context: Context) -> PlotCanvas { PlotCanvas() }
    func updateUIView(_ v: PlotCanvas, context: Context) {
        let key = identity + "|" + String(window) + "|" + String(dates.count)
        v.dates = dates; v.lines = lines; v.markers = markers; v.percentAxis = percent
        v.valueChanged = { i in reading = i }
        if key != v.key {
            v.key = key; v.span = CGFloat(window == 0 ? dates.count : min(window,dates.count))
            v.start = CGFloat(dates.count)-v.span; v.cursor = nil
        }
        v.setNeedsDisplay()
    }
}
private final class PlotCanvas: UIView, UIGestureRecognizerDelegate {
    var dates = [String](), lines = [PlotLine](), markers = [PlotMarker]()
    var percentAxis = false, key = "", span = CGFloat(1), start = CGFloat(0), cursor: Int?
    var valueChanged: ((Int?) -> Void)?
    private var savedStart: CGFloat = 0, savedSpan: CGFloat = 1, anchor: CGFloat = 0
    private var plot: CGRect { bounds.inset(by: UIEdgeInsets(top: 13,left: 1,bottom: 22,right: 51)) }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isAccessibilityElement = true
        accessibilityLabel = "历史曲线，左右轻扫调整日期"
        accessibilityTraits = .adjustable
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panChart(_:)))
        pan.maximumNumberOfTouches = 1; pan.delegate = self
        let pinch = UIPinchGestureRecognizer(target: self,action: #selector(zoom(_:)))
        let press = UILongPressGestureRecognizer(target: self,action: #selector(readValue(_:)))
        press.minimumPressDuration = 0.3
        pan.require(toFail: press)
        [pinch,pan,press,UITapGestureRecognizer(target: self,action: #selector(readValue(_:)))].forEach(addGestureRecognizer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let p = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let v = p.velocity(in: self); return abs(v.x) > abs(v.y)
    }
    @objc private func zoom(_ g: UIPinchGestureRecognizer) {
        let ratio = min(1,max(0,(g.location(in: self).x-plot.minX)/max(1,plot.width)))
        if g.state == .began { savedSpan = span; anchor = start + ratio*(span-1) }
        span = min(CGFloat(dates.count),max(CGFloat(min(5,dates.count)), savedSpan/g.scale))
        start = min(max(0,anchor-ratio*(span-1)), CGFloat(dates.count)-span)
        cursor = nil; valueChanged?(nil); setNeedsDisplay()
    }
    @objc private func panChart(_ g: UIPanGestureRecognizer) {
        if g.state == .began { savedStart = start }
        start = min(max(0,savedStart-g.translation(in: self).x/max(1,plot.width)*(span-1)),CGFloat(dates.count)-span)
        cursor = nil; valueChanged?(nil); setNeedsDisplay()
    }
    @objc private func readValue(_ g: UIGestureRecognizer) {
        let x = max(0,min(1,(g.location(in: self).x-plot.minX)/max(1,plot.width)))
        select(Int((start+x*(span-1)).rounded()))
    }
    private func select(_ i: Int) {
        guard !dates.isEmpty else { return }
        let pos = max(0,min(dates.count-1,i))
        cursor = pos; valueChanged?(pos)
        accessibilityValue = ([dates[pos]] + lines.compactMap { l in l.values[pos].map { l.title+" "+format($0) } }).joined(separator: "，")
        setNeedsDisplay()
    }
    override func accessibilityIncrement() { select((cursor ?? Int(start))+1) }
    override func accessibilityDecrement() { select((cursor ?? dates.count-1)-1) }
    private func format(_ v: Double) -> String { percentAxis ? String(format: "%.1f%%",100*v) : String(format: "%.3f",v) }
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), !dates.isEmpty, plot.width > 1 else { return }
        let first = max(0,min(dates.count-1,Int(start.rounded()))), last = min(dates.count-1,first+max(1,Int(span.rounded()))-1)
        let vals = lines.flatMap { $0.values[first...last].compactMap { $0 } }
        guard let low = vals.min(), let high = vals.max() else { return }
        let pad = max((high-low)*0.06, max(abs(high)*0.0002,0.00001)), bottom = low-pad, top = high+pad
        func x(_ i: Int) -> CGFloat { plot.minX + plot.width*CGFloat(i-first)/CGFloat(max(1,last-first)) }
        func y(_ v: Double) -> CGFloat { plot.maxY - plot.height*CGFloat((v-bottom)/(top-bottom)) }
        func label(_ text: String,_ p: CGPoint) {
            (text as NSString).draw(at: p, withAttributes: [.font:UIFont.monospacedDigitSystemFont(ofSize: 10,weight: .regular),.foregroundColor:UIColor.secondaryLabel])
        }
        for j in 0...3 {
            let v = bottom+(top-bottom)*Double(j)/3, row = y(v)
            ctx.setStrokeColor(UIColor.separator.cgColor); ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: plot.minX,y: row)); ctx.addLine(to: CGPoint(x: plot.maxX,y: row)); ctx.strokePath()
            label(format(v),CGPoint(x: plot.maxX+3,y: row-6))
        }
        label(dates[first],CGPoint(x: plot.minX,y: plot.maxY+5))
        if last != first { label(dates[last],CGPoint(x: max(0,plot.maxX-67),y: plot.maxY+5)) }
        ctx.saveGState(); ctx.clip(to: plot.insetBy(dx: -3,dy: -3))
        for l in lines {
            ctx.setStrokeColor(l.color.cgColor); ctx.setLineWidth(1.8); ctx.setLineJoin(.round)
            var running = false
            for i in first...last {
                guard let value = l.values[i] else { running = false; continue }
                let p = CGPoint(x: x(i),y: y(value))
                if running { ctx.addLine(to: p) } else { ctx.move(to: p) }
                running = true
                if first == last { ctx.addLine(to: CGPoint(x: p.x+1,y: p.y)) }
            }
            ctx.strokePath()
        }
        for mark in markers where mark.index >= first && mark.index <= last {
            if let value = lines.first?.values[mark.index] {
                let center = CGPoint(x: x(mark.index),y: y(value)), sign: CGFloat = mark.buy ? 1 : -1
                ctx.setFillColor((mark.buy ? UIColor.systemRed : UIColor.systemGreen).cgColor)
                ctx.move(to: center); ctx.addLine(to: CGPoint(x: center.x-4,y: center.y+7*sign))
                ctx.addLine(to: CGPoint(x: center.x+4,y: center.y+7*sign)); ctx.closePath(); ctx.fillPath()
            }
        }
        if let cursor, (first...last).contains(cursor) {
            ctx.setStrokeColor(UIColor.label.cgColor); ctx.setLineWidth(1); ctx.setLineDash(phase: 0,lengths: [3,3])
            ctx.move(to: CGPoint(x: x(cursor),y: plot.minY)); ctx.addLine(to: CGPoint(x: x(cursor),y: plot.maxY)); ctx.strokePath()
        }
        ctx.restoreGState()
    }
}

struct QuotesView: View {
    @EnvironmentObject var model: AppModel
    @State private var input = ""
    @State private var query = ""
    var body: some View {
        List {
            Section("我的自选") {
                HStack { TextField("输入证券代码",text: $input).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button("添加") { model.editWatch(input); input = "" }.disabled(input.isEmpty || model.busy || model.vault == nil) }
                ForEach(model.watch) { w in
                    NavigationLink { QuoteDetail(symbol: w.symbol) } label: { VStack(alignment: .leading) { Text(w.name); Text(w.symbol).font(.caption) } }
                        .swipeActions { Button("移除",role: .destructive) { model.editWatch(w.symbol,remove: true) } }
                }
                if model.busy { ProgressView(model.progress) }
            }
            Section("28 只 ETF") {
                if let market = model.market {
                    ForEach(market.securities.keys.sorted().filter { query.isEmpty || $0.contains(query) || market.securities[$0]!.name.contains(query) },id: \.self) { s in
                        NavigationLink { QuoteDetail(symbol: s) } label: { HStack { Text(market.securities[s]!.name); Spacer(); Text(s).font(.caption.monospacedDigit()).foregroundStyle(.secondary) } }
                    }
                } else { Button("获取 ETF 行情") { model.refresh() }.disabled(model.busy) }
            }
        }.navigationTitle("行情").searchable(text: $query,prompt: "查找 ETF 名称或代码")
    }
}
struct QuoteDetail: View {
    @EnvironmentObject var model: AppModel
    let symbol: String
    var body: some View {
        let security = model.market?.securities[symbol], watched = model.watch.first { $0.symbol == symbol }
        let bars = security?.bars ?? watched?.bars ?? [:], dates = bars.keys.sorted()
        let report = model.studies[model.selectedStrategy]
        let indices = Dictionary(uniqueKeysWithValues: dates.enumerated().map { ($1,$0) })
        let marks = (report?.trades ?? []).filter { $0.symbol == symbol }.compactMap { fill in indices[fill.date].map { PlotMarker(index: $0,buy: fill.side == "BUY") } }
        List {
            Section(symbol) {
                if let date = dates.last, let bar = bars[date] {
                    Text(String(format: "%.3f",bar.close)).font(.largeTitle.bold().monospacedDigit())
                    Text("\(date) 收盘 · 原始日线").font(.footnote).foregroundStyle(.secondary)
                }
                MarketPlot(dates: dates,lines: [PlotLine(title: "收盘价（元）",color: .systemTeal,values: dates.map { bars[$0]?.close })],
                           markers: marks,identity: symbol+(dates.last ?? "")+model.selectedStrategy)
                if security != nil, let report {
                    Text("\(model.selectedFile?.short ?? model.selectedStrategy) 回测 · \(report.start) 至 \(report.outcomeDate) · 红色向上为买入，绿色向下为卖出。").font(.caption)
                }
            }
            if security != nil { OutcomeSection(strategy: model.selectedStrategy,symbol: symbol,name: security!.name) }
            if watched != nil { Button("更新这只自选证券") { model.editWatch(symbol) }.disabled(model.busy) }
        }.navigationTitle(security?.name ?? watched?.name ?? symbol).navigationBarTitleDisplayMode(.inline)
    }
}
