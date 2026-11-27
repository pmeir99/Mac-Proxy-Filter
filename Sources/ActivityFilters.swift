import Foundation

struct Event: Codable, Identifiable {
    let id, site, host, verdict, mime: String
    struct Origin: Codable { let status: Int; let encoding, declaredLength: String; let noTransform, partial: Bool }
    let origin: Origin?
    let searchText, path: String?
    let outcome, method: String
    let failure: String?
    let processing: [String:Int]
    let cacheHit: Bool?
    let time: Double
    let elapsedMS, beforeBytes, afterBytes, status: Int
}

struct ActivityFilters {
    var site = "", durations = ""
    var decisions = Set<String>(), hosts = Set<String>(), methods = Set<String>()
    var statuses = Set<String>(), types = Set<String>()
    // Inclusive comma-separated millisecond intervals, exact values and open upper bounds.
    var ranges: [ClosedRange<Int>]? {
        var result = [ClosedRange<Int>]()
        for token in durations.split(separator:",") {
            let t = token.trimmingCharacters(in:.whitespaces)
            if t.hasSuffix("+"), let n = Int(t.dropLast()), n >= 0 { result.append(n...Int.max); continue }
            let parts = t.components(separatedBy:"-").map { $0.trimmingCharacters(in:.whitespaces) }
            guard parts.count <= 2, let low = Int(parts[0]), let high = Int(parts.last ?? ""),
                  low >= 0, high >= low else { return nil }
            result.append(low...high)
        }
        return result
    }
    func select(_ events: [Event]) -> [Event] {
        guard let ranges else { return [] }
        let searches = site.lowercased().split(separator:",").map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }.filter { !$0.isEmpty }
        return events.filter { event in
            let text = event.searchText ?? ""
            return (searches.isEmpty || searches.contains { terms in terms.allSatisfy { text.contains($0) } })
                && (decisions.isEmpty || decisions.contains(event.outcome))
                && (hosts.isEmpty || hosts.contains(event.host) || hosts.contains(event.site))
                && (methods.isEmpty || methods.contains(event.method))
                && (types.isEmpty || types.contains(event.mime))
                && (statuses.isEmpty || statuses.contains(String(event.status)))
                && (ranges.isEmpty || ranges.contains { $0.contains(event.elapsedMS) })
        }
    }
}
