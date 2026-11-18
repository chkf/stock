import Foundation

public struct ChartObservation: Identifiable {
    public let id: Int
    public let date: Date
    public let value: Double
}

/// The eight original published HTML fragments embed their plotted data as JSON.
/// Read that data without running scripts or fetching a renderer from the network.
public struct ArchiveChart {
    public let title, detail, yLabel: String
    public let percent: Bool
    public let series: [String: [ChartObservation]]
    public let names: [String]

    public static func load(from data: Data) throws -> [ArchiveChart] {
        guard let html = String(data: data, encoding: .utf8) else { throw ResearchError("原图字符编码无效") }
        let re = try NSRegularExpression(pattern: #"<script\b[^>]*\btype\s*=\s*["']application/json["'][^>]*>(.*?)</script\s*>"#,
                                         options: [.caseInsensitive, .dotMatchesLineSeparators])
        var out = [ArchiveChart]()
        for match in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html),
                  let record = try JSONSerialization.jsonObject(with: Data(html[range].utf8)) as? [String: Any] else {
                throw ResearchError("原图缺少可解析的数据")
            }
            for chart in record["charts"] as? [[String: Any]] ?? [record] { out.append(try ArchiveChart(chart)) }
        }
        guard !out.isEmpty else { throw ResearchError("原图缺少已知的图表数据段") }
        return out
    }

    private init(_ chart: [String: Any]) throws {
        guard let title = chart["title"] as? String, let columns = chart["columns"] as? [String],
              let rows = chart["rows"] as? [[Any]], let spec = chart["spec"] as? [String: Any],
              let x = spec["x"] as? String, let xi = columns.firstIndex(of: x) else { throw ResearchError("原图缺少标题、横轴或序列") }
        self.title = title
        detail = chart["description"] as? String ?? ""
        yLabel = spec["yLabel"] as? String ?? ""
        percent = (spec["valueFormat"] as? [String: Any])?["style"] as? String == "percent"
        let fields = spec["y"] as? [String] ?? (spec["y"] as? String).map { [$0] } ?? []
        let yIndices = try fields.map { name -> Int in
            guard let i = columns.firstIndex(of: name) else { throw ResearchError("原图纵轴字段缺失") }
            return i
        }
        let seriesIndex = (spec["series"] as? String).flatMap { columns.firstIndex(of: $0) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        var dates = [String: Date](), grouped = [String: [ChartObservation]](), ordered = [String]()
        for row in rows {
            guard row.count == columns.count, let day = row[xi] as? String,
                  let date = dates[day] ?? f.date(from: day) else { throw ResearchError("原图日期或行长度无效") }
            dates[day] = date
            for (j, yi) in yIndices.enumerated() {
                guard let value = row[yi] as? NSNumber, value.doubleValue.isFinite else { throw ResearchError("原图数值缺失") }
                let name = seriesIndex.flatMap { row[$0] as? String } ?? fields[j]
                if grouped[name] == nil { ordered.append(name) }
                let point = ChartObservation(id: grouped[name]?.count ?? 0, date: date, value: value.doubleValue)
                grouped[name, default: []].append(point)
            }
        }
        guard !grouped.isEmpty else { throw ResearchError("原图没有数值序列") }
        series = grouped
        names = ordered
    }
}
