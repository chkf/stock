import Foundation

/// Dates below were read from the issuer notices. Raw originals and their hashes are in fixtures/history.
struct SplitNotice {
    let symbol, record, ex, available, factor: String
    let rounding: String?
    let halted, atClose: Bool
    static let published = [
        Self(symbol:"159919.SZ",record:"2019-01-11",ex:"2019-01-11",available:"2019-01-14",factor:"1.110680861",rounding:"ceil",halted:true,atClose:true),
        Self(symbol:"512200.SH",record:"2024-08-09",ex:"2024-08-12",available:"2024-08-12",factor:"0.35806260",rounding:"ceil",halted:false,atClose:false),
        Self(symbol:"512010.SH",record:"2021-06-24",ex:"2021-06-25",available:"2021-06-28",factor:"4",rounding:nil,halted:true,atClose:false)
    ]
    func matches(_ e:MarketEvent) -> Bool {
        e.date==ex && e.record_date==record && e.share_factor==Double(factor) &&
        (e.rounding == nil || e.rounding==rounding) && (e.available_date == nil || e.available_date==available)
    }
}

struct SplitTerms {
    let factor:Decimal, available:String, atClose:Bool, rounding:String?
    init(_ event:MarketEvent, symbol:String, calendar:Sessions, halted:Bool, fallback:MarketEvent?=nil) throws {
        func problem(_ field:String) -> ResearchError { ResearchError("\(symbol) \(event.date) 拆合 · \(field)") }
        let notice=SplitNotice.published.first { $0.symbol==symbol && ($0.ex==event.date || $0.record==event.record_date) }
        if let n=notice, !n.matches(event) { throw problem("与公告的精确比例、登记、除权、可卖日期或舍入规则不符") }
        guard let original=event.share_factor, original.isFinite, original>0 else { throw problem("精确比例缺失") }
        let text=event.exact_factor ?? notice?.factor ?? String(original)
        guard text.range(of:#"^[0-9]+(\.[0-9]+)?$"#,options:.regularExpression) != nil,
              let precise=Decimal(string:text,locale:Locale(identifier:"en_US_POSIX")),Double(text)==original
        else { throw problem("精确比例不符") }
        if let settlement=event.settlement, settlement != "single_account_shares" { throw problem("引擎不支持现金替代、冻结或分托管单元结算") }
        guard let record=event.record_date, let available=event.available_date ?? notice?.available ?? fallback?.available_date,
              (try? calendar.index(available)) != nil, available >= event.date else { throw problem("缺可卖日或登记日") }
        let same=record==event.date
        if same {
            guard notice?.atClose==true, halted, available>event.date,
                  event.share_timing == nil || event.share_timing=="record_close" else { throw problem("同日登记须有已核停牌、日终变更和后续上市依据") }
        } else {
            guard try calendar.next(record)==event.date, event.share_timing == nil || event.share_timing=="before_open"
            else { throw problem("缺前一交易日登记或明确的开市前份额变更") }
        }
        let mode=event.rounding ?? notice?.rounding ?? fallback?.rounding
        guard mode=="ceil" || mode=="floor" || (mode==nil && original.rounded()==original) else { throw problem("非整数比例缺可执行舍入规则") }
        self.factor=precise; self.rounding=mode; self.available=available; self.atClose=same
    }
    func count(_ quantity:Int, round mode:NSDecimalNumber.RoundingMode) throws -> Int {
        var n=Decimal(quantity)*factor, result=Decimal()
        NSDecimalRound(&result,&n,0,mode)
        guard result >= 0, result < Decimal(Int.max) else { throw ResearchError("折算后的份额超出可表示范围") }
        return NSDecimalNumber(decimal:result).intValue
    }
    func converted(_ quantity:Int) throws -> Int { try count(quantity,round:rounding=="ceil" ? .up : .down) }
    func allocation(_ shares:[Int]) throws -> [Int] {
        let floors=try shares.map { try count($0,round:.down) }
        let target=try converted(shares.reduce(0,+))
        let fractions=shares.indices.map { Decimal(shares[$0])*factor-Decimal(floors[$0]) }
        let order=shares.indices.sorted { fractions[$0]==fractions[$1] ? $0<$1 : fractions[$0]>fractions[$1] }
        var result=floors
        for index in order.prefix(target-floors.reduce(0,+)) { result[index]+=1 }
        return result
    }
}
