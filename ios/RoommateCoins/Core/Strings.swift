import Foundation

/// String catalogue for coin copy (PRD section 7). Launch locale en-IN; Hindi is P1 (FR-18).
enum Strings {
    static let coinsUnavailable = String(localized: "coins.unavailable", defaultValue: "Coins unavailable right now")
    static let thisWeekTogether = String(localized: "household.title", defaultValue: "This week, together")
    static func confirmedOf(_ p: Int, _ t: Int) -> String {
        String(localized: "household.progress", defaultValue: "\(p) of \(t) expenses confirmed")
    }
    static func reachGoal(_ t: Int, _ reward: Int) -> String {
        String(localized: "household.reach", defaultValue: "Reach \(t) and the group earns +\(reward)")
    }
    static func goalMet(_ reward: Int) -> String {
        String(localized: "household.met", defaultValue: "Goal met. +\(reward) for the group.")
    }
    static let householdEmpty = String(localized: "household.empty",
        defaultValue: "Add your first shared expense. When someone confirms it, you both earn coins.")
    static func sharedPot(_ c: Int) -> String { String(localized: "household.pot", defaultValue: "Shared pot: \(c)") }
    static func weeksSquared(_ w: Int) -> String { String(localized: "household.squared", defaultValue: "Weeks squared: \(w)") }

    static let looksRight = String(localized: "confirm.prompt", defaultValue: "Looks right?")
    static let notRight = String(localized: "confirm.notright", defaultValue: "Not right")
    static let capDaily = String(localized: "cap.daily", defaultValue: "Daily coin limit reached, back tomorrow")
    static let capMonthly = String(localized: "cap.monthly", defaultValue: "Monthly coin limit reached, back next month")
    static func waitingFor(_ names: String) -> String { String(localized: "confirm.waiting", defaultValue: "Waiting for \(names)") }
    static func confirmedBy(_ n: String) -> String { String(localized: "confirm.by", defaultValue: "Confirmed by \(n)") }
    static let willSync = String(localized: "offline.sync", defaultValue: "Will sync")

    static func addedSuccess(_ coins: Int, _ names: String) -> String {
        String(localized: "add.success", defaultValue: "Added. You earn \(coins) coins when \(names) confirms.")
    }

    static func youOwe(_ name: String, _ amount: String) -> String { String(localized: "settle.owe", defaultValue: "You owe \(name) \(amount)") }
    static func payToday(_ coins: Int) -> String { String(localized: "settle.hint", defaultValue: "Pay today for +\(coins) coins") }
    static func waitingReceipt(_ name: String) -> String {
        String(localized: "settle.waiting", defaultValue: "Waiting for \(name) to confirm")
    }

    static let walletEmpty = String(localized: "wallet.empty", defaultValue: "No coins yet. Your first confirmed expense earns 50.")
    static let redeemFailed = String(localized: "redeem.failed", defaultValue: "That didn't go through. Your coins are safe.")
    static let readyIn48 = String(localized: "redeem.held", defaultValue: "Ready within 48 hours")
    static let alsoEmailed = String(localized: "redeem.email", defaultValue: "Also sent to your email")

    static let intro = [
        (String(localized: "intro.1.title", defaultValue: "Add or confirm a shared expense"),
         String(localized: "intro.1.body", defaultValue: "Log rent, a trip dinner or a cab. Others check it in one tap.")),
        (String(localized: "intro.2.title", defaultValue: "They confirm, you both earn"),
         String(localized: "intro.2.body", defaultValue: "Coins come from things you do together: confirming, settling, weekly goals.")),
        (String(localized: "intro.3.title", defaultValue: "Spend coins on vouchers, 4 coins = INR 1"),
         String(localized: "intro.3.body", defaultValue: "Your first voucher is only 100 coins.")),
    ]
}
