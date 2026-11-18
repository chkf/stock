import Foundation

/// Rebuild from actual raw closes. Missing non-trading days carry an ex-adjusted mark only.
enum HistoryAdjustment {
    static func signals(symbol:String,days:[String],bars:[String:Bar],anchor:String,anchorSignal:Double,
                        previousClose:Double?,events:[MarketEvent],listed:String?,
                        nonTrading:(String)->Bool,band:(String)->Double) throws -> [String:Double] {
        guard let pivot=days.firstIndex(of:anchor), anchorSignal.isFinite, anchorSignal>0 else { throw ResearchError("\(symbol) 信号缺归一化锚点 \(anchor)") }
        let actions=Dictionary(grouping:events,by:\.date)
        var marks=[Double?](repeating:nil,count:days.count), steps=[Double](repeating:1,count:days.count), prev=previousClose
        for (i,d) in days.enumerated() {
            if let listed,d<listed {
                guard bars[d]==nil, actions[d]==nil else { throw ResearchError("\(symbol) \(d) 上市前出现行情或行动") }
                continue
            }
            let ev=actions[d] ?? []
            guard ev.count<=1 else { throw ResearchError("\(symbol) \(d) 未核定多项行动的执行次序") }
            var reference=prev
            if let e=ev.first {
                let cash=e.cash_per_share ?? 0,split=e.share_factor ?? 1
                guard let last=prev,last>cash,cash>=0,split>0,split.isFinite else { throw ResearchError("\(symbol) \(d) 缺公司行动前真实参考价或现金/比例无效") }
                reference=(last-cash)/split
                steps[i]=split*last/(last-cash)
            }
            if nonTrading(d) {
                guard let reference,bars[d].map({ $0.valid && $0.volume==0 }) ?? true else { throw ResearchError("\(symbol) \(d) 缺停牌前参考价，或原价与停牌证据冲突") }
                marks[i]=reference
            } else if let bar=bars[d] {
                guard bar.valid else { throw ResearchError("\(symbol) \(d) OHLC 无效") }
                if let reference { try PublicFeed.validateBand(bar,reference:reference,band:band(d),symbol:symbol,date:d) }
                marks[i]=bar.close
            } else {
                throw ResearchError("\(symbol) \(d) SOURCE_MISSING 缺原价、上市或正式停牌/无成交依据")
            }
            prev=marks[i]
        }
        guard let mark=marks[pivot] else { throw ResearchError("\(symbol) \(anchor) 锚点缺估值") }
        var out=[anchor:anchorSignal], scale=anchorSignal/mark
        for i in days.indices where i>pivot {
            scale *= steps[i]
            if let p=marks[i] { out[days[i]]=p*scale }
        }
        scale=anchorSignal/mark
        for i in (0..<pivot).reversed() {
            scale /= steps[i+1]
            if let p=marks[i] { out[days[i]]=p*scale }
        }
        guard out.values.allSatisfy({ $0.isFinite && $0>0 }) else { throw ResearchError("\(symbol) 复权尺度异常") }
        return out
    }
}
