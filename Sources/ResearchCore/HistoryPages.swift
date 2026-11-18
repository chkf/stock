import Foundation

/// The vendor may ignore the lower date or return fewer rows than requested.
/// Each successful page must cross a strictly earlier calendar-day boundary.
enum HistoryPages {
    static func collect(symbol:String,from:String,through:String,calendar:Sessions,previous:[String:Bar],
                        page:(String,Int) async throws->[String:Bar]) async throws -> [String:Bar] {
        var cursor=through,index=0,bars=[String:Bar]()
        while cursor>=from {
            try Task.checkCancellation()
            let rows=try await page(cursor,index)
            guard let earliest=rows.keys.min() else { break }
            for (day,bar) in rows {
                guard (try? calendar.index(day)) != nil, day>=from, day<=cursor else { throw ResearchError("\(symbol) \(day) 分页未前进或返回非交易日") }
                guard previous[day].map({ $0==bar }) ?? true else { throw ResearchError("\(symbol) \(day) 与旧快照重叠 OHLC/成交量不符") }
                bars[day]=bar
            }
            if earliest==from { break }
            guard let d=ExchangeDay.date(earliest),let last=ExchangeDay.calendar.date(byAdding:.day,value:-1,to:d) else { throw ResearchError("\(symbol) 分页日期无效") }
            let next=ExchangeDay.string(last)
            guard next<cursor else { throw ResearchError("\(symbol) \(cursor) 分页未前进") }
            cursor=next; index+=1
        }
        for (day,bar) in previous where from<=day && day<=through && bars[day] != bar {
            throw ResearchError("\(symbol) \(day) 与旧原价重叠区间不完整")
        }
        return bars
    }
}
