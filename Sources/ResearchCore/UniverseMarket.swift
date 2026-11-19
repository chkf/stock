import Foundation

struct UniverseManifest: Codable {
    static let format = "etf-universe-1"
    let schema, from, through, catalog, scopeEvidence:String
    let partitions:[String:[String]]
}

struct PointMetadata: Codable, Hashable {
    let effective, known, evidence, name, assetClass, role, group, indexID:String
    let candidate:Bool
}

struct UniverseListing: Codable {
    let listed, listingEvidence:String
    let terminal, terminalEvidence:String?
    let metadata:[PointMetadata]
    func active(_ date:String) -> Bool { listed <= date && (terminal.map { date < $0 } ?? true) }
    func metadata(on date:String) -> PointMetadata? { metadata.last { $0.effective <= date && $0.known <= date } }
}

struct UniverseSession: Codable {
    let state, known, evidence, execution:String
    let upper, lower:Double?
}

struct UniversePartition: Codable {
    let schema,symbol,from,through,quotes,audit:String
    let sessions:[String:UniverseSession]
}

private struct ActionAudit:Decodable {
    let schema,symbol,from,through:String
    let sources:[String], events:[AuditedEvent]
}
private struct AuditedEvent:Decodable {
    let value:MarketEvent
    private static let fields:Set<String>=["date","announced","record_date","source","payment_date","cash_per_share","share_factor","available_date","rounding","exact_factor","share_timing","settlement","supported","date_needs_reconciliation"]
    init(from decoder:Decoder) throws {
        let fields=try decoder.container(keyedBy:EventField.self).allKeys.map(\.stringValue)
        var event=try MarketEvent(from:decoder)
        if !Set(fields).isSubset(of:Self.fields) { event.supported=false }
        value=event
    }
    private struct EventField:CodingKey {
        let stringValue:String
        var intValue:Int? { nil }
        init?(stringValue:String) { self.stringValue=stringValue }
        init?(intValue:Int) { return nil }
    }
}
struct QuoteReceipt:Codable {
    let schema,symbol,from,through,url,body:String
}
private struct ListingProof:Decodable { let symbol,instrument,listed,known,source:String }
private struct MetadataProof:Decodable { let symbol:String, verified:Bool, classification:PointMetadata }
private struct TerminalProof:Decodable { let symbol,inactiveFrom,known,source:String }
private struct ScopeProof:Decodable { let schema,scope,from,through,catalog:String; let sources:[String] }

struct VerifiedUniverse {
    let id, from,catalog,scopeEvidence:String
    let listings:[String:UniverseListing]
    var turnover=[String:[String:Double]](), lengths=[String:[String:Int]](), issues=[String:[String:String]]()
}

enum UniverseMarket {
    static func load(_ bytes:Data,calendar:Sessions,read:(String)throws->Data) throws -> MarketSnapshot {
        let manifest=try JSONDecoder().decode(UniverseManifest.self,from:bytes)
        guard manifest.schema==UniverseManifest.format, try calendar.index(manifest.from)<=calendar.index(manifest.through),
              manifest.through <= (try calendar.completed()) else { throw ResearchError("目录快照版本或交易日范围无效") }
        var sources=[String:String](), totalBytes=0
        func blob(_ hash:String) throws -> Data {
            try Task.checkCancellation()
            guard Integrity.digestID(hash) else { throw ResearchError("无效来源摘要 "+hash) }
            let data=try read(hash)
            guard !data.isEmpty, data.count<=16*1024*1024, Integrity.sha(data)==hash else { throw ResearchError("来源损坏 "+hash) }
            if sources.updateValue(hash,forKey:hash)==nil { totalBytes+=data.count }
            guard totalBytes<=256*1024*1024 else { throw ResearchError("目录输入超过本机读取预算，请分区") }
            return data
        }
        func evidence(_ hash:String) throws { if sources[hash]==nil { _=try blob(hash) } }
        let scope=try JSONDecoder().decode(ScopeProof.self,from:blob(manifest.scopeEvidence))
        guard scope.schema=="etf-scope-review-1",!scope.scope.isEmpty,scope.from==manifest.from,scope.through==manifest.through,
              scope.catalog==manifest.catalog,!scope.sources.isEmpty else { throw ResearchError("缺所声明证券范围及历史身份完整性审核") }
        for source in scope.sources { try evidence(source) }
        let listings=try JSONDecoder().decode([String:UniverseListing].self,from:blob(manifest.catalog))
        guard !listings.isEmpty, Set(manifest.partitions.keys).isSubset(of:Set(listings.keys)) else { throw ResearchError("行情采集范围或目录身份无效") }
        var verified=VerifiedUniverse(id:Integrity.sha(bytes),from:manifest.from,catalog:manifest.catalog,scopeEvidence:manifest.scopeEvidence,listings:listings), securities=[String:MarketSecurity]()
        let days=calendar.days[try calendar.index(manifest.from)...calendar.index(manifest.through)]
        guard listings.count<=3_000_000/days.count else { throw ResearchError("目录与日期矩阵超过本机加载预算") }
        for symbol in listings.keys.sorted() {
            try Task.checkCancellation()
            let entry=listings[symbol]!
            guard symbol.range(of:#"^[0-9]{6}\.(SH|SZ)$"#,options:.regularExpression) != nil,
                  ExchangeDay.date(entry.listed) != nil, (entry.terminal==nil)==(entry.terminalEvidence==nil) else { throw ResearchError("\(symbol) 上市身份无效") }
            let identity=try JSONDecoder().decode(ListingProof.self,from:blob(entry.listingEvidence))
            guard identity.symbol==symbol,identity.instrument=="ETF",identity.listed==entry.listed,ExchangeDay.date(identity.known) != nil,identity.known<=entry.listed else { throw ResearchError("\(symbol) ETF 上市记录与可知身份不符") }; try evidence(identity.source)
            if let end=entry.terminal,let proof=entry.terminalEvidence {
                let terminal=try JSONDecoder().decode(TerminalProof.self,from:blob(proof))
                guard ExchangeDay.date(end) != nil,end>entry.listed,terminal.symbol==symbol,terminal.inactiveFrom==end,
                      ExchangeDay.date(terminal.known) != nil,terminal.known<=end else { throw ResearchError("\(symbol) 终止记录缺历史身份或来源") }; try evidence(terminal.source)
            }
            var previous:PointMetadata?
            for meta in entry.metadata {
                guard ExchangeDay.date(meta.known) != nil, ExchangeDay.date(meta.effective) != nil,
                      [meta.name,meta.assetClass,meta.role,meta.group,meta.indexID].allSatisfy({ !$0.isEmpty && $0.utf8.count<=512 }),
                      previous.map({ ($0.effective,$0.known)<(meta.effective,meta.known) }) ?? true else { throw ResearchError("\(symbol) 历史分类缺失或版本乱序") }
                let proof=try JSONDecoder().decode(MetadataProof.self,from:blob(meta.evidence)), audited=proof.classification
                guard proof.verified,proof.symbol==symbol,audited.effective==meta.effective,audited.known==meta.known,audited.name==meta.name,
                      audited.assetClass==meta.assetClass,audited.role==meta.role,audited.group==meta.group,audited.indexID==meta.indexID,
                      audited.candidate==meta.candidate else { throw ResearchError("\(symbol) 元数据与历史核验版本不符") }; try evidence(audited.evidence); previous=meta
            }
            let current=entry.metadata(on:manifest.through)
            var security=MarketSecurity(name:current?.name ?? symbol,group:current?.group ?? "",bars:[:],signal_close:[:],events:[],statuses:[:])
            var records=[String:UniverseSession](), amount=[String:Double](), issues=[String:String](), lengths=[String:Int]()
            var covered=Set<String>()
            for hash in manifest.partitions[symbol] ?? [] {
                let part=try JSONDecoder().decode(UniversePartition.self,from:blob(hash))
                guard part.schema=="etf-session-partition-1",part.symbol==symbol,part.from>=manifest.from,part.through<=manifest.through,
                      try calendar.index(part.from)<=calendar.index(part.through) else { throw ResearchError("\(symbol) 行情分区身份或日期不符") }
                let audit=try JSONDecoder().decode(ActionAudit.self,from:blob(part.audit))
                guard audit.schema=="etf-action-audit-1",audit.symbol==symbol,audit.from==part.from,audit.through==part.through,
                      !audit.sources.isEmpty else { throw ResearchError("\(symbol) 公司行动审核不匹配") }
                for source in audit.sources { try evidence(source) }
                for auditedEvent in audit.events {
                    let event=auditedEvent.value
                    guard let source=event.source,audit.sources.contains(source),part.from<=event.date,event.date<=part.through,
                          (try? calendar.index(event.date)) != nil,entry.active(event.date) else { throw ResearchError("\(symbol) 行动缺原件或日期无效") }
                    security.events.append(event)
                }
                for day in calendar.days[try calendar.index(part.from)...calendar.index(part.through)] {
                    guard covered.insert(day).inserted else { throw ResearchError("\(symbol) \(day) 重叠分区") }
                }
                for (day,session) in part.sessions {
                    guard part.from<=day,day<=part.through,(try? calendar.index(day)) != nil,entry.active(day) else { throw ResearchError("\(symbol) \(day) 状态超出上市区间") }
                    try evidence(session.evidence); records[day]=session
                }
                let receipt=try JSONDecoder().decode(QuoteReceipt.self,from:blob(part.quotes))
                guard receipt.schema=="eastmoney-raw-1",receipt.symbol==symbol,receipt.from==part.from,receipt.through==part.through,
                      receipt.url==PublicFeed.universeURL(symbol,part.from,part.through).absoluteString else { throw ResearchError("\(symbol) 缺不复权请求或成交额来源") }
                for (day,row) in try PublicFeed.universeQuotes(blob(receipt.body),symbol:symbol) {
                    guard part.from<=day,day<=part.through,entry.active(day),(try? calendar.index(day)) != nil else { throw ResearchError("\(symbol) \(day) 原价超出分区") }
                    security.bars[day]=row.0; amount[day]=row.1
                }
            }
            var mark:Double?, signal:Double?, streak=0, broken:String?
            let events=Dictionary(grouping:security.events,by:\.date)
            for day in days where entry.active(day) {
                if let broken { issues[day]=broken; continue }
                do {
                    guard covered.contains(day) else { throw ResearchError("缺行情分区或公司行动完整性审核") }
                    guard let session=records[day], session.known==day, session.execution=="CN_ETF_T1_LOT100", ["trading","halted","no_trades_confirmed"].contains(session.state) else { throw ResearchError("交易状态、可知日或执行规则缺失/不支持") }
                    let halted=session.state != "trading", bar=security.bars[day]
                    let actions=events[day] ?? []
                    guard actions.count<=1 else { throw ResearchError("同日多项行动顺序不明") }
                    var reference=mark
                    if let event=actions.first {
                        let cash=event.cash_per_share ?? 0, factor=event.share_factor ?? 1
                        guard event.supported==true,event.date_needs_reconciliation==false,let known=event.announced,ExchangeDay.date(known) != nil,
                              let record=event.record_date,known<=record,let prior=mark,cash>=0,prior>cash,factor>0,
                              (cash>0) != (factor != 1) else { throw ResearchError("公司行动未核或缺事件前参考价") }
                        if factor != 1 {
                            guard event.settlement=="single_account_shares",event.exact_factor != nil,event.share_timing != nil,event.available_date != nil,event.payment_date==nil else { throw ResearchError("缺拆合结算条款或含未支持的支付条款") }
                            _=try SplitTerms(event,symbol:symbol,calendar:calendar,halted:halted,legacy:false)
                        } else {
                            guard event.settlement==nil,event.exact_factor==nil,event.share_timing==nil,event.rounding==nil,event.available_date==nil,
                                  let record=event.record_date, try calendar.next(record)==day, let pay=event.payment_date,ExchangeDay.date(pay) != nil,pay>=day else { throw ResearchError("分红登记/到账或附加结算条款不支持") }
                        }
                        reference=(prior-cash)/factor
                    }
                    if halted {
                        guard reference != nil,(bar?.volume ?? 0)==0,(amount[day] ?? 0)==0 else { throw ResearchError("停牌缺前估值或存在成交") }
                        amount[day]=0
                    } else {
                        guard let bar,bar.volume>0,(amount[day] ?? 0)>0,let upper=session.upper,let lower=session.lower,lower>0,upper>lower,
                              bar.high<=upper+0.000001,bar.low>=lower-0.000001 else { throw ResearchError("缺原价、成交额、真实涨跌停或当日价格越界") }
                    }
                    let price=halted ? reference! : bar!.close
                    let adjusted=signal.flatMap { prior in reference.map { prior*price/$0 } } ?? price
                    guard adjusted.isFinite, adjusted>0 else { throw ResearchError("复权信号异常") }
                    mark=price; signal=adjusted; streak+=1; lengths[day]=streak
                    security.signal_close[day]=adjusted
                    security.statuses?[day] = .init(state:session.state,upper_limit:session.upper,lower_limit:session.lower,source:session.evidence,assumption:false)
                    if entry.metadata(on:day)==nil { issues[day]="历史身份/分类/资格未知" }
                } catch { issues[day]=error.localizedDescription; broken="\(day) 后复权链未核："+error.localizedDescription }
            }
            verified.turnover[symbol]=amount; verified.issues[symbol]=issues; verified.lengths[symbol]=lengths; securities[symbol]=security
        }
        return MarketSnapshot(schema:manifest.schema,as_of:manifest.through,securities:securities,sources:sources,extras:[:],limitations:[],universe:verified)
    }
}

extension PublicFeed {
    static func universeURL(_ symbol:String,_ from:String,_ through:String) -> URL {
        var url=URLComponents(string:"https://push2his.eastmoney.com/api/qt/stock/kline/get")!
        let query=[("secid",(symbol.hasSuffix(".SH") ? "1.":"0.")+symbol.prefix(6)),("beg",from.replacingOccurrences(of:"-",with:"")),("end",through.replacingOccurrences(of:"-",with:"")),("klt","101"),("fqt","0"),("fields1","f1,f2,f3,f4,f5,f6"),("fields2","f51,f52,f53,f54,f55,f56,f57")]
        url.queryItems=query.map { URLQueryItem(name:$0.0,value:String($0.1)) }; return url.url!
    }
    static func universeQuotes(_ bytes:Data,symbol:String) throws -> [String:(Bar,Double)] {
        struct Response:Decodable { struct Payload:Decodable { let code:String, market:Int, klines:[String] }; let rc:Int,data:Payload }
        let response=try JSONDecoder().decode(Response.self,from:bytes), data=response.data
        guard response.rc==0,data.code==String(symbol.prefix(6)),data.market==(symbol.hasSuffix(".SH") ? 1:0) else { throw ResearchError("\(symbol) 原价来源证券身份冲突") }
        var result=[String:(Bar,Double)]()
        for line in data.klines {
            let fields=line.components(separatedBy:","), values=fields.dropFirst().prefix(6).compactMap(Double.init)
            guard fields.count==7,values.count==6,values.allSatisfy(\.isFinite),values[5]>=0,result[fields[0]]==nil else { throw ResearchError("\(symbol) 原始日线或元成交额无效") }
            let bar=Bar(open:values[0],close:values[1],high:values[2],low:values[3],volume:values[4]); guard bar.valid,bar.low>=0.001 else { throw ResearchError("\(symbol) OHLC 无效") }
            result[fields[0]]=(bar,values[5])
        }
        return result
    }
}
