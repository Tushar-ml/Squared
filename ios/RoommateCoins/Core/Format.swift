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
