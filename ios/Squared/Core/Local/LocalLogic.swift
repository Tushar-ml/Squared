import Foundation

/// Rules ported from the old backend: currencies, categories, splits and balances.
enum LocalLogic {
    // MARK: currencies

    static let currencies = ["INR", "USD", "EUR", "GBP", "AED", "SGD", "AUD", "CAD", "JPY", "THB", "SAR", "QAR", "CHF",
                             "CNY", "HKD", "NZD", "MYR", "IDR", "LKR", "NPR", "BDT", "ZAR", "KRW", "SEK"]
    static let currencyNames = ["INR": "Indian rupee", "USD": "US dollar", "EUR": "Euro", "GBP": "British pound",
        "AED": "UAE dirham", "SGD": "Singapore dollar", "AUD": "Australian dollar", "CAD": "Canadian dollar",
        "JPY": "Japanese yen", "THB": "Thai baht", "SAR": "Saudi riyal", "QAR": "Qatari riyal", "CHF": "Swiss franc",
        "CNY": "Chinese yuan", "HKD": "Hong Kong dollar", "NZD": "New Zealand dollar", "MYR": "Malaysian ringgit",
        "IDR": "Indonesian rupiah", "LKR": "Sri Lankan rupee", "NPR": "Nepalese rupee", "BDT": "Bangladeshi taka",
        "ZAR": "South African rand", "KRW": "South Korean won", "SEK": "Swedish krona"]
    static let symbols = ["INR": "₹", "USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥", "KRW": "₩", "THB": "฿", "CNY": "¥"]
    static func digits(_ c: String) -> Int { ["JPY", "KRW", "IDR"].contains(c) ? 0 : 2 }

    static func convert(_ minor: Int, from: String, to: String, rate: Double) -> Int {
        if from == to { return minor }
        let major = Double(minor) / pow(10, Double(digits(from)))
        return Int((major * rate * pow(10, Double(digits(to)))).rounded(.toNearestOrEven))
    }

    static func money(_ minor: Int, _ cur: String) -> String {
        let d = digits(cur)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: cur == "INR" ? "en_IN" : "en_US")
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = d
        return "\(cur) " + (f.string(from: NSNumber(value: Double(minor) / pow(10, Double(d)))) ?? "0")
    }

    /// Live rates from open.er-api.com, cached for an hour; the last good rates are reused when offline.
    static func rates(base: String) async throws -> LocalDB.Fx {
        let base = base.uppercased()
        let cached = LocalDB.shared.read { $0.fx[base] }
        if let c = cached, Date().timeIntervalSince(c.fetchedAt) < 3600 { return c }
        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "https://open.er-api.com/v6/latest/\(base)")!)
            guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any], j["result"] as? String == "success",
                  let all = j["rates"] as? [String: Double] else { throw LocalError(503, "Exchange rates are unavailable") }
            var rates = all.filter { currencies.contains($0.key) }
            rates[base] = 1
            let asOf = (j["time_last_update_unix"] as? Double).map { iso(Date(timeIntervalSince1970: $0)) }
            let fx = LocalDB.Fx(rates: rates, asOf: asOf, fetchedAt: Date())
            try LocalDB.shared.write { $0.fx[base] = fx }
            return fx
        } catch {
            if let c = cached { return c }
            throw LocalError(503, "Live exchange rates need an internet connection the first time")
        }
    }

    // MARK: categories

    static let categoryLabels = ["rent": "Rent", "utilities": "Utilities", "groceries": "Groceries", "food": "Food & dining",
        "help": "House help", "household": "Household", "transport": "Transport", "entertainment": "Entertainment",
        "travel": "Travel", "stay": "Stay", "shopping": "Shopping", "gifts": "Gifts", "other": "Other"]

    private static let rules: [(String, String)] = [
        ("stay", #"\b(hotel|airbnb|hostel|resort|homestay|villa|oyo)\b"#),
        ("rent", #"\b(rent|deposit|maintenance|society)\b"#),
        ("utilities", #"\b(wifi|wi-fi|internet|broadband|electric\w*|power|bill|gas|cylinder|water|dth|recharge|airtel|jio)\b"#),
        ("groceries", #"\b(grocer\w*|milk|bread|eggs?|vegetables?|veggies|fruits?|zepto|blinkit|bigbasket|instamart|dmart|kirana)\b"#),
        ("food", #"\b(swiggy|zomato|dinner|lunch|breakfast|pizza|biryani|food|cafe|restaurant|chai|coffee|takeaway)\b"#),
        ("help", #"\b(maid|cook|cleaning|cleaner|helper|bai|driver|laundry|dhobi|ironing)\b"#),
        ("household", #"\b(furniture|repair|plumber|electrician|detergent|toilet|kitchen|utensils?|bulb|curtain|mattress)\b"#),
        ("travel", #"\b(flights?|airfare|indigo|vistara|train|irctc|bus|visa|trip|ferry|toll)\b"#),
        ("transport", #"\b(uber|ola|rapido|cab|taxi|auto|petrol|fuel|metro|parking)\b"#),
        ("gifts", #"\b(gift|birthday|present|anniversary|wedding|farewell|flowers|cake)\b"#),
        ("shopping", #"\b(amazon|flipkart|myntra|shopping|clothes|shoes|mall|nykaa)\b"#),
        ("entertainment", #"\b(netflix|prime|hotstar|spotify|movie|party|drinks|beer|games?)\b"#),
    ]

    static func category(_ given: String?, description: String) -> String {
        if let g = given, categoryLabels[g] != nil { return g }
        let d = description.lowercased()
        for (cat, rx) in rules where d.range(of: rx, options: .regularExpression) != nil { return cat }
        return "other"
    }

    // MARK: splits (largest remainder; ties to the earlier person)

    static func split(_ amount: Int, _ input: LocalDB.ExpenseInput, members: [Int]) throws -> ([Int: Int], SplitMeta) {
        guard amount > 0 else { throw LocalError(400, "Amount must be more than zero") }
        let type = (input.splitType ?? "EQUAL").uppercased()
        func check(_ ids: [Int]) throws {
            guard !ids.isEmpty else { throw LocalError(400, "Pick at least one person") }
            guard Set(ids).isSubset(of: Set(members)) else { throw LocalError(400, "Everyone in the split must be in the group") }
        }
        func keyed<T>(_ d: [String: T]?) -> [Int: T] {
            Dictionary(uniqueKeysWithValues: (d ?? [:]).compactMap { k, v in Int(k).map { ($0, v) } })
        }
        switch type {
        case "EXACT":
            let vals = keyed(input.exact).filter { $0.value != 0 }
            try check(Array(vals.keys))
            guard vals.values.allSatisfy({ $0 > 0 }) else { throw LocalError(400, "Amounts can't be negative") }
            let total = vals.values.reduce(0, +)
            guard total == input.amount else {
                let diff = input.amount - total
                throw LocalError(400, "Amounts are \(diff > 0 ? "short" : "over") by \(String(format: "%.2f", Double(abs(diff)) / 100))")
            }
            // entered in the expense currency; scale into the group currency if they differ
            let ids = vals.keys.sorted()
            let shares = amount == total ? vals : Dictionary(uniqueKeysWithValues: zip(ids, SplitMath.allocate(amount, ids.map { Double(vals[$0]!) })))
            return (shares, SplitMeta(exact: Dictionary(uniqueKeysWithValues: vals.map { (String($0.key), $0.value) })))
        case "PERCENT":
            let vals = keyed(input.percents).filter { $0.value != 0 }
            try check(Array(vals.keys))
            guard abs(vals.values.reduce(0, +) - 100) < 0.01 else { throw LocalError(400, "Percentages must add up to 100") }
            let ids = vals.keys.sorted()
            return (Dictionary(uniqueKeysWithValues: zip(ids, SplitMath.allocate(amount, ids.map { vals[$0]! }))),
                    SplitMeta(percents: input.percents))
        case "SHARES":
            let vals = keyed(input.shares).filter { $0.value > 0 }
            try check(Array(vals.keys))
            let ids = vals.keys.sorted()
            return (Dictionary(uniqueKeysWithValues: zip(ids, SplitMath.allocate(amount, ids.map { vals[$0]! }))),
                    SplitMeta(shares: input.shares))
        default:
            let ids = Array(Set(input.participants ?? members)).sorted()
            try check(ids)
            return (Dictionary(uniqueKeysWithValues: zip(ids, SplitMath.allocate(amount, ids.map { _ in 1 }))),
                    SplitMeta(participants: ids))
        }
    }

    // MARK: balances

    struct Pair: Hashable { let debtor: Int; let creditor: Int }

    /// Net who-owes-whom per pair, positive amounts only.
    static func pairDebts(_ s: LocalDB.Store, _ gid: Int) -> [Pair: Int] {
        var raw: [Pair: Int] = [:]
        for e in s.liveExpenses(gid) {
            for sp in e.splits where sp.person != e.paidBy && sp.share > 0 {
                raw[Pair(debtor: sp.person, creditor: e.paidBy), default: 0] += sp.share
            }
        }
        for p in s.livePayments(gid) { raw[Pair(debtor: p.payer, creditor: p.receiver), default: 0] -= p.amount }
        var out: [Pair: Int] = [:]
        var seen = Set<Pair>()
        for (k, v) in raw where !seen.contains(k) {
            let rev = Pair(debtor: k.creditor, creditor: k.debtor)
            seen.insert(k); seen.insert(rev)
            let diff = v - (raw[rev] ?? 0)
            if diff > 0 { out[k] = diff } else if diff < 0 { out[rev] = -diff }
        }
        return out
    }

    static func nets(_ s: LocalDB.Store, _ gid: Int) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for (k, v) in pairDebts(s, gid) { out[k.debtor, default: 0] -= v; out[k.creditor, default: 0] += v }
        return out
    }

    /// Fewest payments: biggest debtor pays biggest creditor. Same totals as `pairDebts`.
    static func simplified(_ s: LocalDB.Store, _ gid: Int) -> [Pair: Int] {
        let net = nets(s, gid).filter { $0.value != 0 }
        // biggest first; ties by id so results are stable
        func order(_ a: (Int, Int), _ b: (Int, Int)) -> Bool { a.1 == b.1 ? a.0 < b.0 : a.1 > b.1 }
        var debtors: [(Int, Int)] = net.filter { $0.value < 0 }.map { ($0.key, -$0.value) }
        var creditors: [(Int, Int)] = net.filter { $0.value > 0 }.map { ($0.key, $0.value) }
        debtors.sort(by: order)
        creditors.sort(by: order)
        var out: [Pair: Int] = [:]
        var i = 0, j = 0
        while i < debtors.count && j < creditors.count {
            let pay = min(debtors[i].1, creditors[j].1)
            if pay > 0 { out[Pair(debtor: debtors[i].0, creditor: creditors[j].0), default: 0] += pay }
            debtors[i].1 -= pay; creditors[j].1 -= pay
            if debtors[i].1 == 0 { i += 1 }
            if creditors[j].1 == 0 { j += 1 }
        }
        return out
    }

    static func debts(_ s: LocalDB.Store, _ g: LocalDB.Group) -> [Pair: Int] { g.simplify ? simplified(s, g.id) : pairDebts(s, g.id) }

    // MARK: dates

    static let ist = TimeZone.current
    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
    static func parseDay(_ s: String) -> Date? {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
    static func weekStart(_ d: Date = Date()) -> Date {
        var cal = Calendar(identifier: .iso8601); cal.timeZone = .current
        return cal.dateInterval(of: .weekOfYear, for: d)!.start
    }
    static func monthBounds(_ month: String?) -> (start: Date, end: Date, key: String, label: String) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        var comps = cal.dateComponents([.year, .month], from: Date())
        if let m = month, m.count == 7, let y = Int(m.prefix(4)), let mo = Int(m.suffix(2)) { comps.year = y; comps.month = mo }
        comps.day = 1
        let start = cal.date(from: comps)!
        let end = cal.date(byAdding: .month, value: 1, to: start)!
        let k = DateFormatter(); k.dateFormat = "yyyy-MM"
        let l = DateFormatter(); l.dateFormat = "MMMM yyyy"
        return (start, end, k.string(from: start), l.string(from: start))
    }
}

struct LocalError: LocalizedError {
    let status: Int
    let message: String
    init(_ status: Int, _ message: String) { self.status = status; self.message = message }
    var errorDescription: String? { message }
}
