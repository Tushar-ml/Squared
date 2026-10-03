import Foundation

/// Client-side preview of the server's split rules (the server is authoritative).
/// Mirrors backend/app/splits.py: largest-remainder rounding, ties to the earlier person.
enum SplitMode: String, CaseIterable, Identifiable {
    case equal = "EQUAL", exact = "EXACT", percent = "PERCENT", shares = "SHARES"
    var id: String { rawValue }
    var label: String {
        switch self { case .equal: "Equally"; case .exact: "Amounts"; case .percent: "%"; case .shares: "Shares" }
    }
}

enum SplitMath {
    static func allocate(_ total: Int, _ weights: [Double]) -> [Int] {
        let s = weights.reduce(0, +)
        guard total > 0, s > 0, weights.allSatisfy({ $0 >= 0 }) else { return weights.map { _ in 0 } }
        let raw = weights.map { Double(total) * $0 / s }
        var base = raw.map { Int($0.rounded(.down)) }
        var left = total - base.reduce(0, +)
        let order = raw.indices.sorted { a, b in
            let ra = raw[a] - Double(base[a]), rb = raw[b] - Double(base[b])
            return ra == rb ? a < b : ra > rb
        }
        for i in order where left > 0 { base[i] += 1; left -= 1 }
        return base
    }

    struct Result {
        var shares: [Int: Int]
        var error: String?
        var remaining: Int = 0      // EXACT: amount still to assign (negative = over)
        var percentTotal: Double = 0
    }

    /// `values` are the typed per-person inputs: minor units (exact), percent, or share weight.
    static func compute(total: Int, mode: SplitMode, people: [Int], included: Set<Int>, values: [Int: Double]) -> Result {
        switch mode {
        case .equal:
            let ids = people.filter(included.contains)
            guard !ids.isEmpty else { return Result(shares: [:], error: "Pick at least one person") }
            return Result(shares: Dictionary(uniqueKeysWithValues: zip(ids, allocate(total, ids.map { _ in 1 }))))
        case .exact:
            let shares = values.compactMapValues { $0 > 0 ? Int($0) : nil }
            let rem = total - shares.values.reduce(0, +)
            var r = Result(shares: shares, remaining: rem)
            if shares.isEmpty { r.error = "Enter how much each person owes" }
            else if rem != 0 { r.error = rem > 0 ? "Left to assign" : "Over by" }
            return r
        case .percent:
            let ids = people.filter { (values[$0] ?? 0) > 0 }
            let sum = ids.reduce(0) { $0 + (values[$1] ?? 0) }
            var r = Result(shares: Dictionary(uniqueKeysWithValues: zip(ids, allocate(total, ids.map { values[$0] ?? 0 })))
                           , percentTotal: sum)
            if ids.isEmpty { r.error = "Enter percentages" }
            else if abs(sum - 100) > 0.01 { r.error = "Percentages add up to \(sum.formatted(.number.precision(.fractionLength(0...2))))%" }
            return r
        case .shares:
            let ids = people.filter { (values[$0] ?? 0) > 0 }
            guard !ids.isEmpty else { return Result(shares: [:], error: "Give at least one person a share") }
            return Result(shares: Dictionary(uniqueKeysWithValues: zip(ids, allocate(total, ids.map { values[$0] ?? 0 }))))
        }
    }
}
