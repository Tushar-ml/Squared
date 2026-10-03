import Foundation

enum Format {
    private static let inrFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_IN")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f
    }()

    /// "INR 1,00,000" / "INR 266.50" (en-IN grouping).
    static func inr(paise: Int) -> String {
        let rupees = Double(abs(paise)) / 100
        let f = inrFormatter
        f.minimumFractionDigits = paise % 100 == 0 ? 0 : 2
        let s = f.string(from: NSNumber(value: rupees)) ?? "\(rupees)"
        return (paise < 0 ? "-" : "") + "INR " + s
    }

    static func inr(rupees: Double) -> String { inr(paise: Int((rupees * 100).rounded())) }

    static let zeroDecimal: Set<String> = ["JPY", "KRW", "IDR"]
    static func digits(_ currency: String) -> Int { zeroDecimal.contains(currency) ? 0 : 2 }

    /// Money in any currency from minor units. INR keeps en-IN grouping ("INR 1,00,000").
    static func money(_ minor: Int, _ currency: String?) -> String {
        let cur = currency ?? "INR"
        if cur == "INR" { return inr(paise: minor) }
        let d = digits(cur)
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.maximumFractionDigits = d
        f.minimumFractionDigits = (d > 0 && minor % Int(pow(10.0, Double(d))) != 0) ? d : 0
        let major = Double(abs(minor)) / pow(10.0, Double(d))
        return (minor < 0 ? "-" : "") + "\(cur) " + (f.string(from: NSNumber(value: major)) ?? "\(major)")
    }

    /// Parses typed text into minor units for a currency.
    static func minor(from text: String, currency: String?) -> Int? {
        let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let dec = Decimal(string: cleaned), dec > 0 else { return nil }
        var v = dec * Decimal(sign: .plus, exponent: digits(currency ?? "INR"), significand: 1)
        var r = Decimal()
        NSDecimalRound(&r, &v, 0, .plain)
        let out = NSDecimalNumber(decimal: r).intValue
        return out > 0 ? out : nil
    }

    static func majorString(_ minor: Int, _ currency: String?) -> String {
        let d = digits(currency ?? "INR")
        if d == 0 { return "\(minor)" }
        return minor % 100 == 0 ? "\(minor / 100)" : String(format: "%.2f", Double(minor) / 100)
    }

    /// Parses "799", "799.5", "1,200" into paise.
    static func paise(from text: String) -> Int? {
        let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let d = Decimal(string: cleaned), d > 0 else { return nil }
        var v = d * 100
        var r = Decimal()
        NSDecimalRound(&r, &v, 0, .plain)
        return NSDecimalNumber(decimal: r).intValue
    }

    static func coinsInr(_ coins: Int, coinValue: Double) -> String {
        "about " + inr(rupees: Double(coins) * coinValue)
    }

    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

    static func shortDate(_ iso: String?) -> String {
        guard let d = date(iso) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_IN")
        f.timeZone = TimeZone(identifier: "Asia/Kolkata")
        f.dateFormat = "d MMM"
        return f.string(from: d)
    }

    static func relative(_ iso: String?) -> String {
        guard let d = date(iso) else { return "" }
        // Past times only; small clock skew with the server shouldn't read as "in 2 sec".
        if Date().timeIntervalSince(d) < 60 { return String(localized: "just now") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func names(_ list: [String]) -> String {
        switch list.count {
        case 0: return "a roommate"
        case 1: return list[0]
        case 2: return "\(list[0]) or \(list[1])"
        default: return list.dropLast().joined(separator: ", ") + " or " + list.last!
        }
    }
}
