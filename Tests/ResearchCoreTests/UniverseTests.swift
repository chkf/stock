import XCTest
@testable import ResearchCore

private final class UniverseFixture {
    let calendar:Sessions, days:[String], root:URL, store:WorkspaceStore, vault:PrivateLibrary
    var sources=[String:Data]()
    init() throws {
        calendar=try Sessions(); let first=try calendar.index("2024-12-02"); days=Array(calendar.days[first..<first+35])
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store=WorkspaceStore(root:root); vault=PrivateLibrary(root:root.appendingPathComponent("数据")); try store.installIfNeeded()
    }
    deinit { try? FileManager.default.removeItem(at:root) }
    func put(_ object:Any) throws -> String {
        let bytes=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]), id=Integrity.sha(bytes); sources[id]=bytes; return id
    }
    func manifest(_ symbols:[String],count:Int=30,listed:Int=2,exit:Int?=nil,halt:Int?=nil,terminal:Int?=nil,gap:Int?=nil,
                  unknown:Int?=nil,action:Int?=nil,split:Bool=false,unsupported:Bool=false,future:Bool=false,lastListed:Int?=nil,extraTerms:[String:String]=[:]) throws -> Data {
        let scope=try put(["review":"synthetic test only"]), from=days[0], end=days[count-1]
        var catalog=[String:Any](),parts=[String:[String]]()
        for (index,symbol) in symbols.enumerated() {
            let first=index==symbols.count-1 ? (lastListed ?? (future ? count-2:listed)) : listed
            let listing=try put(["symbol":symbol,"instrument":"ETF","listed":days[first],"known":days[first],"source":scope])
            func meta(_ effective:Int,_ known:Int,_ candidate:Bool) throws -> [String:Any] {
                var value:[String:Any]=["effective":days[effective],"known":days[known],"evidence":scope,"name":"ETF-"+symbol,"assetClass":"equity","role":"sample","group":"same-index","indexID":"test:index","candidate":candidate]
                value["evidence"]=try put(["symbol":symbol,"verified":true,"classification":value] as [String:Any]);return value
            }
            var metadata=try [meta(first,unknown ?? first,true)]
            if index==0,let exit { metadata.append(try meta(exit,exit,false)) }
            if future,index==0 { metadata.append(try meta(count-1,count-1,false)) }
            var entry:[String:Any]=["listed":days[first],"listingEvidence":listing,"metadata":metadata]
            if index==0,let terminal { entry["terminal"]=days[terminal];entry["terminalEvidence"]=try put(["symbol":symbol,"inactiveFrom":days[terminal],"known":days[terminal],"source":scope]) }; catalog[symbol]=entry
            var records=[String:Any](),lines=[String](),events=[[String:Any]]()
            for offset in first..<count where !(index==0 && terminal.map({offset >= $0})==true) {
                let day=days[offset], halted=index==0 && offset==halt
                records[day]=["state":halted ? "halted":"trading","known":day,"evidence":scope,"execution":"CN_ETF_T1_LOT100","upper":12,"lower":1]
                let close=(action.map { offset >= $0 } == true && index==0) ? (split ? 5:9) : 10
                if !halted,offset != gap { lines.append("\(day),\(close),\(close),\(close),\(close),100,100000") }
                if index==0,offset==action {
                    var event:[String:Any]=["date":day,"announced":days[offset-2],"record_date":days[offset-1],"source":scope,"supported":!unsupported,"date_needs_reconciliation":false]
                    if split { event["share_factor"]=2;event["exact_factor"]="2";event["settlement"]="single_account_shares";event["available_date"]=days[offset+2];event["share_timing"]="before_open" }
                    else { event["payment_date"]=days[offset+2];event["cash_per_share"]=1 };for (key,value) in extraTerms { event[key]=value };events.append(event)
                }
            }
            let body=try put(["rc":0,"data":["code":String(symbol.prefix(6)),"market":symbol.hasSuffix(".SH") ? 1:0,"klines":lines] as [String:Any]] as [String:Any])
            let receipt=try put(["schema":"eastmoney-raw-1","symbol":symbol,"from":from,"through":end,"url":PublicFeed.universeURL(symbol,from,end).absoluteString,"body":body])
            let audit=try put(["schema":"etf-action-audit-1","symbol":symbol,"from":from,"through":end,"sources":[scope],"events":events] as [String:Any])
            parts[symbol]=[try put(["schema":"etf-session-partition-1","symbol":symbol,"from":from,"through":end,"quotes":receipt,"audit":audit,"sessions":records] as [String:Any])]
        }
        let catalogID=try put(catalog), review=try put(["schema":"etf-scope-review-1","scope":"TEST","from":from,"through":end,"catalog":catalogID,"sources":[scope]] as [String:Any]);let hash=try put(["schema":"etf-universe-1","from":from,"through":end,"catalog":catalogID,"scopeEvidence":review,"partitions":parts] as [String:Any]); return sources[hash]!
    }
    func load(_ bytes:Data) throws -> MarketSnapshot { try UniverseMarket.load(bytes,calendar:calendar) { try XCTUnwrap(self.sources[$0]) } }
    static let js="""
    function screen(input) { return Object.keys(input.securities).filter(s=>input.securities[s].eligible).sort().slice(0,input.config.limit); }
    function run(input) {
      const keys=Object.keys(input.securities).sort(), s=keys[0], row=input.securities[s];
      if(input.contractVersion!==2 || input.stage!=='run' || input.dates.length!==3 || row.turnover.at(-1)!==100000 || row.close.length!==3 || row.role!=='sample') throw Error('contract mismatch');
      return {strategy:input.strategy,date:input.date,route:'TEST',marketState:'OK',selected:[s],weights:{[s]:0.5},scores:{},breadth:{},headline:input.catalogVersion+input.metadataVersion+input.marketVersion};
    }
    """
    func workspace(_ code:String=js,policy:String="cash",limit:Int=1) throws -> WorkspaceVersion {
        let file=store.working.appendingPathComponent("workspace.json")
        var design=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any]); var strategies=design["strategies"] as! [[String:Any]]
        strategies.removeAll { ($0["id"] as? String)=="LOCAL" };strategies.append(["id":"LOCAL","short":"L","title":"Local","file":"local.js","history":3,"rebalance":"daily","requirements":["contract":2,"screenHistory":1,"insufficient":policy,"config":"config.json"] as [String:Any]])
        design["strategies"]=strategies;try JSONSerialization.data(withJSONObject:design,options:[.sortedKeys]).write(to:file)
        try Data(code.utf8).write(to:store.working.appendingPathComponent("local.js"));try JSONSerialization.data(withJSONObject:["schema":"etf-strategy-config-1","versions":[["effective":days[0],"known":days[0],"values":["limit":limit]] as [String:Any]]] as [String:Any]).write(to:store.working.appendingPathComponent("config.json"));return try store.activate()
    }
    func replay(_ market:MarketSnapshot,_ version:WorkspaceVersion,start:Int=1,end:Int=12,observe:((StudyLedgerDay)->Void)?=nil) throws -> ReplayReport {
        let stamp=try ReplayReport.fingerprint(market:market.universe!.id,workspace:version.hash,dynamic:true)
        return try StrategyEngine(market:market,sessions:calendar,workspace:version).replay("LOCAL",snapshot:stamp,start:days[start],end:days[end],observe:observe)
    }
}

final class UniverseTests:XCTestCase {
    let symbols=["510300.SH","510500.SH"]
    func testPhoneActivationFormalReplayReloadAndResume() async throws {
        let fixture=try UniverseFixture(),bytes=try fixture.manifest(symbols),id=Integrity.sha(bytes), version=try fixture.workspace()
        let inbox=fixture.root.appendingPathComponent("目录行情/blobs");try FileManager.default.createDirectory(at:inbox,withIntermediateDirectories:true)
        for (hash,data) in fixture.sources { try data.write(to:inbox.appendingPathComponent(hash)) }
        _=try await fixture.vault.activateCatalog(id); try FileManager.default.removeItem(at:inbox)
        let snapshot=try await fixture.vault.catalogMarket(),market=try XCTUnwrap(snapshot?.market)
        let old=try await fixture.vault.phoneMarket();XCTAssertNil(old)
        var interrupted=false
        XCTAssertThrowsError(try fixture.vault.formalReplay(market:market,id:id,workspace:version,strategy:"LOCAL",start:fixture.days[1],end:fixture.days[26]) { _,_ in interrupted=true;throw CancellationError() });XCTAssertTrue(interrupted)
        let result=try fixture.vault.formalReplay(market:market,id:id,workspace:version,strategy:"LOCAL",start:fixture.days[1],end:fixture.days[26]);XCTAssertTrue(result.finished);XCTAssertEqual(result.ledgerVersion,4)
        XCTAssertEqual(result.firstSignal,fixture.days[4]);XCTAssertEqual(result.firstTrade,fixture.days[5]);XCTAssertEqual(result.waiting,["noListedProducts":2,"listingWarmup":2]);XCTAssertEqual(result.trades.first?.symbol,symbols[0]);XCTAssertFalse(MarketSnapshot.pool.contains(symbols[0]))
        let full=try fixture.replay(market,version,end:26), encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];XCTAssertEqual(try encoder.encode(full),try encoder.encode(result))
        let updated=try fixture.workspace(UniverseFixture.js.replacingOccurrences(of:"[s]:0.5",with:"[s]:0.25"));XCTAssertNotEqual(updated.hash,version.hash)
        let newResult=try fixture.replay(market,updated);XCTAssertNotEqual(newResult.trades.first?.quantity,result.trades.first?.quantity);XCTAssertNotEqual(newResult.snapshot,result.snapshot)
        XCTAssertThrowsError(try StrategyEngine(market:market,sessions:fixture.calendar,workspace:updated).replay("LOCAL",snapshot:result.snapshot,start:result.start,end:result.end,resume:result))
    }
    func testHistoryPrefixAndUnknownAreNotCash() throws {
        let fixture=try UniverseFixture(),version=try fixture.workspace(),before=try fixture.load(fixture.manifest(symbols,count:14)),after=try fixture.load(fixture.manifest(symbols+["159900.SZ"],future:true))
        for offset in [1,4,8,10] {
            let left=try StrategyEngine(market:before,sessions:fixture.calendar,workspace:version).decision("LOCAL",on:fixture.days[offset]),right=try StrategyEngine(market:after,sessions:fixture.calendar,workspace:version).decision("LOCAL",on:fixture.days[offset]);XCTAssertEqual(left.headline,right.headline);XCTAssertEqual(left.weights,right.weights)
        }
        XCTAssertTrue(try fixture.replay(before,version,start:6).finished)
        for market in [try fixture.load(fixture.manifest(symbols,gap:6)),try fixture.load(fixture.manifest(symbols,unknown:8))] {
            XCTAssertThrowsError(try fixture.replay(market,version));XCTAssertNotNil(try HistoryCoverage(market:market,sessions:fixture.calendar,strategies:[version.design.strategies.last!]).problem(start:fixture.days[1],end:fixture.days[12]))
        }
        XCTAssertThrowsError(try fixture.replay(before,fixture.workspace(policy:"error")));XCTAssertThrowsError(try fixture.replay(before,version,start:0));XCTAssertThrowsError(try fixture.replay(before,version,end:15))
    }
    func testLaterListingEntersWithoutHoldingUpEarlierETF() throws {
        let fixture=try UniverseFixture(),market=try fixture.load(fixture.manifest(symbols,lastListed:7))
        let code=UniverseFixture.js.replacingOccurrences(of:".sort().slice(0,input.config.limit)",with:".sort().reverse().slice(0,input.config.limit)")
        let report=try fixture.replay(market,fixture.workspace(code),end:13)
        XCTAssertEqual(report.trades.first { $0.symbol==symbols[0] && $0.side=="BUY" }?.date,fixture.days[5])
        XCTAssertEqual(report.trades.first { $0.symbol==symbols[1] && $0.side=="BUY" }?.date,fixture.days[10])
        XCTAssertEqual(report.waiting,["noListedProducts":2,"listingWarmup":2])
    }
    func testHeldOutsideCandidatesSuspensionDistributionAndTerminal() throws {
        let fixture=try UniverseFixture(),version=try fixture.workspace(),market=try fixture.load(fixture.manifest(symbols,exit:7,halt:8,action:8));var ledger=[StudyLedgerDay]()
        let result=try fixture.replay(market,version) { ledger.append($0) };let stopped=try XCTUnwrap(ledger.first { $0.date==fixture.days[8] }?.holdings[symbols[0]])
        XCTAssertGreaterThan(stopped.shares,0);XCTAssertLessThan(stopped.pending,0);XCTAssertEqual(stopped.mark,9);XCTAssertEqual(stopped.receivable,Double(stopped.shares));XCTAssertTrue(result.trades.contains { $0.side=="SELL" && $0.date==fixture.days[9] });XCTAssertTrue(result.trades.contains { $0.symbol==symbols[1] });XCTAssertEqual(ledger.last?.holdings[symbols[0]]?.receivable,0)
        XCTAssertThrowsError(try fixture.replay(fixture.load(fixture.manifest(symbols,terminal:8)),version))
    }
    func testLargeUniverseSmallSolverAndBoundaries() throws {
        let fixture=try UniverseFixture(),ids=(0..<120).map { String(format:"51%04d.SH",$0) },market=try fixture.load(fixture.manifest(ids,count:12,listed:0))
        let code=UniverseFixture.js.replacingOccurrences(of:"return {strategy:",with:"minimumVariance(3,[1,0,0,0,1,0,0,0,1]); return {strategy:")
        XCTAssertTrue(try fixture.replay(market,fixture.workspace(code,limit:3),start:4,end:11).finished)
        for call in ["minimumVariance(29,[])","minimumVariance(3,[1])","minimumVariance(3,Array(9).fill(null))","minimumVariance(3.5,Array(9).fill(1))"] {
            XCTAssertThrowsError(try fixture.replay(market,fixture.workspace(UniverseFixture.js.replacingOccurrences(of:"return {strategy:",with:call+";return {strategy:")),start:4,end:5))
        }
        let bytes=try fixture.manifest(symbols);XCTAssertThrowsError(try UniverseMarket.load(bytes,calendar:fixture.calendar) { _ in Data("corrupt".utf8) })
    }
    func testDelayedSharesRemainSellableAfterExitAndUnsupportedBlocks() throws {
        let fixture=try UniverseFixture(),version=try fixture.workspace(), market=try fixture.load(fixture.manifest(symbols,exit:7,action:8,split:true)); var ledger=[StudyLedgerDay]()
        let result=try fixture.replay(market,version) { ledger.append($0) }
        let pending=try XCTUnwrap(ledger.first { $0.date==fixture.days[8] }?.holdings[symbols[0]])
        XCTAssertGreaterThan(pending.shares,0);XCTAssertEqual(pending.available,0);XCTAssertLessThan(pending.pending,0)
        XCTAssertTrue(result.trades.contains { $0.symbol==symbols[0] && $0.side=="SELL" && $0.date==fixture.days[10] })
        XCTAssertThrowsError(try fixture.replay(fixture.load(fixture.manifest(symbols,action:8,unsupported:true)),version))
        for terms in [["conversionTarget":symbols[1]],["settlement":"liquidation"]] {
            let mixed=try fixture.load(fixture.manifest(symbols,action:8,extraTerms:terms))
            XCTAssertTrue(try fixture.replay(mixed,version,end:7).finished);XCTAssertThrowsError(try fixture.replay(mixed,version))
        }
        let unresolved=try fixture.load(fixture.manifest(symbols,exit:7,terminal:9,action:8,split:true));XCTAssertThrowsError(try fixture.replay(unresolved,version))
    }
    func testIncrementalReceiptCacheRetryAndIsolation() async throws {
        let fixture=try UniverseFixture(), from=fixture.days[0],end=fixture.days[1],symbol=symbols[0]
        let bytes=try JSONSerialization.data(withJSONObject:["rc":0,"data":["code":"510300","market":1,"klines":["\(from),2,2,2,2,100,20000"]] as [String:Any]] as [String:Any])
        do { _=try await fixture.vault.collectPartition(symbol:symbol,from:from,through:end) { _ in throw CancellationError() };XCTFail() } catch is CancellationError {}
        let receipt=try await fixture.vault.collectPartition(symbol:symbol,from:from,through:end) { _ in bytes }
        let same=try await fixture.vault.collectPartition(symbol:symbol,from:from,through:end) { _ in XCTFail("重复采集");return bytes };XCTAssertEqual(receipt,same)
        do { _=try await fixture.vault.collectPartition(symbol:symbols[1],from:from,through:end) { _ in bytes };XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("身份")) }
        let current=try await fixture.vault.catalogMarket();XCTAssertNil(current)
    }
    func testReplayTicketIsNotAnActionAndCannotBeReused() throws {
        let fixture=try UniverseFixture(),path=fixture.root.appendingPathComponent("请求.json"), version=try fixture.workspace()
        let request=Data(#"{"id":"job-1","operation":"replay","target":"LOCAL","fields":{"start":"2024-12-16","end":"2024-12-19","marketOrigin":"phone"}}"#.utf8)
        try request.write(to:path);let job=try XCTUnwrap(fixture.store.nextRequest());XCTAssertNil(try fixture.store.nextRequest());XCTAssertThrowsError(try version.action("LOCAL",input:Data()))
        try fixture.store.replayStatus(job,status:"running",message:"验证",fraction:0);try fixture.store.replayStatus(job,status:"cancelled",message:"取消")
        try Data((String(decoding:request,as:UTF8.self)+" ").utf8).write(to:path);XCTAssertNil(try fixture.store.nextRequest())
        let receipt=try JSONSerialization.jsonObject(with:Data(contentsOf:fixture.root.appendingPathComponent("输出/回测请求/job-1.json"))) as? [String:Any];XCTAssertEqual(receipt?["status"] as? String,"cancelled")
    }
    func testFileReplayCompletesOnlyAfterSavingAndRejectsDamagedLedger() throws {
        let fixture=try UniverseFixture(),version=try fixture.workspace(),market=try fixture.load(fixture.manifest(symbols)),id=market.universe!.id
        let bytes=Data(#"{"id":"formal","operation":"replay","target":"LOCAL","fields":{"start":"2024-12-16","end":"2024-12-19","marketOrigin":"phone"}}"#.utf8)
        try bytes.write(to:fixture.root.appendingPathComponent("请求.json"));let job=try XCTUnwrap(fixture.store.nextRequest())
        func receipt() throws -> [String:Any] { try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:fixture.root.appendingPathComponent("输出/回测请求/formal.json"))) as? [String:Any]) }
        XCTAssertEqual(try receipt()["status"] as? String,"accepted")
        try fixture.store.performReplay(job,workspace:version,library:fixture.vault,phone:nil,catalog:.init(market:market,hash:id,usableFrom:fixture.days[0]),archive:nil,archiveID:nil) { _,_ in XCTAssertEqual((try? receipt())?["status"] as? String,"running") }
        let record=try receipt(),result=fixture.root.appendingPathComponent(try XCTUnwrap(record["resultPath"] as? String));XCTAssertEqual(record["status"] as? String,"done")
        var saved=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:result)) as? [String:Any]);XCTAssertEqual(saved["ledgerVersion"] as? Int,4);saved["cash"]=0
        try JSONSerialization.data(withJSONObject:saved).write(to:result);XCTAssertThrowsError(try fixture.vault.formalReplay(market:market,id:id,workspace:version,strategy:"LOCAL",start:"2024-12-16",end:"2024-12-19"))
    }
    func testLateConfigAndTruncatedEstablishedHistory() throws {
        let config=Data(#"{"schema":"etf-strategy-config-1","versions":[{"effective":"2024-01-01","known":"2024-01-01","values":{"v":1}},{"effective":"2024-01-01","known":"2025-01-01","values":{"v":2}}]}"#.utf8)
        XCTAssertEqual(try WorkspaceVersion.strategyConfig(config,on:"2024-06-01")["v"] as? Int,1);XCTAssertEqual(try WorkspaceVersion.strategyConfig(config,on:"2025-01-01")["v"] as? Int,2)
        let fixture=try UniverseFixture(),symbol=symbols[0],market=try fixture.load(fixture.manifest([symbol],listed:0)); var universe=try XCTUnwrap(market.universe)
        let row=try XCTUnwrap(universe.listings[symbol]),listed=UniverseListing(listed:"2024-11-29",listingEvidence:row.listingEvidence,terminal:nil,terminalEvidence:nil,metadata:row.metadata)
        universe=VerifiedUniverse(id:universe.id,from:universe.from,catalog:universe.catalog,scopeEvidence:universe.scopeEvidence,listings:[symbol:listed],turnover:universe.turnover,lengths:universe.lengths,issues:universe.issues)
        XCTAssertThrowsError(try universe.check(symbol,day:fixture.days[0],windowStart:"2024-11-28",history:3))
    }
    func testScreenTimeoutStopsFormalReplay() throws {
        let fixture=try UniverseFixture(),market=try fixture.load(fixture.manifest(symbols))
        let version=try fixture.workspace("function screen(){for(;;){}} function run(){return {}}")
        XCTAssertThrowsError(try fixture.replay(market,version)) { XCTAssertTrue($0.localizedDescription.contains("interrupted")) }
    }
    #if os(macOS) || os(Linux)
    func testArchiveVerifiesSameContentAddressedMarket() throws {
        let fixture=try UniverseFixture(),bytes=try fixture.manifest(symbols,count:12),id=Integrity.sha(bytes),version=try fixture.workspace()
        let plain=fixture.root.appendingPathComponent("manifest-input"),zip=Process(), output=Pipe();try bytes.write(to:plain)
        zip.executableURL=URL(fileURLWithPath:"/usr/bin/gzip");zip.arguments=["-cn",plain.path];zip.standardOutput=output;try zip.run();let compressed=output.fileHandleForReading.readDataToEndOfFile();zip.waitUntilExit();XCTAssertEqual(zip.terminationStatus,0)
        let info=MarketID(hash:id,as_of:fixture.days[11]);var files=["data/advice/market/latest.json":try JSONEncoder().encode(info),"data/advice/market/snapshots/"+id+".json.gz":compressed]
        for (hash,data) in fixture.sources where hash != id { files["data/advice/market/blobs/"+hash]=data }
        var entries=[ArchiveEntry](),payload=Data()
        for path in files.keys.sorted() {
            let data=files[path]!;entries.append(ArchiveEntry(path:path,offset:payload.count,size:data.count,sha256:Integrity.sha(data)));payload.append(data)
        }
        let manifest=Manifest(schema:"stock-transfer-1",profile:"snapshot",sourceRoot:"",aliases:[:],snapshot:info,files:entries,fileCount:entries.count,totalBytes:payload.count,chunkSize:2*1024*1024,chunks:[Integrity.sha(payload)])
        let raw=try JSONEncoder().encode(manifest);try raw.write(to:fixture.root.appendingPathComponent("manifest.json"));try payload.write(to:fixture.root.appendingPathComponent("payload.bin"))
        let archive=try Archive(directory:fixture.root,id:Integrity.sha(raw));try archive.verify { _,_ in };let market=try archive.loadMarket();XCTAssertEqual(try fixture.replay(market,version,end:10).trades.first?.symbol,symbols[0])
    }
    #endif
}
