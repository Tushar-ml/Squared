import Foundation

// Decoded with .convertFromSnakeCase. Coin fields are optional: old payloads and
// ineligible groups simply omit them, and the UI hides coin elements.

struct User: Codable, Equatable {
    let id: Int
    let phone: String
    var name: String
    var email: String?
    var upiId: String?
    let role: String
    var hideCoins: Bool
    var introSeen: Bool
    let createdAt: String
}

struct AuthResponse: Codable { let token: String; let isNew: Bool; let user: User }

struct GroupSummary: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let groupType: String
    let memberCount: Int
    let myNetPaise: Int
    let coinsEnabled: Bool
}

struct GroupsResponse: Codable { let groups: [GroupSummary] }

struct Member: Codable, Identifiable, Hashable { let id: Int; let name: String?; let isYou: Bool }

struct Debt: Codable, Hashable {
    let debtorId: Int
    let debtorName: String?
    let creditorId: Int
    let creditorName: String?
    let amountPaise: Int
    let youOwe: Bool
    let creditorUpi: String?
    let payRewardHint: Int?
}

struct PersonRef: Codable, Hashable { let userId: Int; let name: String? }
struct Dispute: Codable, Hashable { let userId: Int; let name: String?; let reason: String?; let note: String? }

struct RewardPreview: Codable, Hashable {
    let coins: Int
    let firstWinBonus: Int
    let cappedReason: String?
}

struct Confirmation: Codable, Hashable {
    let status: String            // WAITING, CONFIRMED, DISPUTED, UNCONFIRMED
    let version: Int
    let confirmedBy: [PersonRef]
    let disputedBy: [Dispute]
    let waitingOn: [PersonRef]
    let myResponse: String?
    let canConfirm: Bool
    let canRemind: [PersonRef]
    let adderReward: Int
    let rewardPreview: RewardPreview?
}

struct Split: Codable, Hashable { let userId: Int; let name: String?; let sharePaise: Int }

struct SuccessHint: Codable, Hashable { let adderCoins: Int; let notified: [String?] }

struct Expense: Codable, Identifiable, Hashable {
    let id: Int
    let groupId: Int
    let description: String
    let amountPaise: Int
    let currency: String
    let paidBy: Int
    let paidByName: String?
    let createdBy: Int
    let createdByName: String?
    let version: Int
    let splits: [Split]
    let mySharePaise: Int
    let createdAt: String
    var confirmation: Confirmation?
    var successHint: SuccessHint?
    var rewardPreview: RewardPreview?
    var alreadyResponded: Bool?
}

struct PaymentConfirmation: Codable, Hashable {
    let status: String            // PENDING, CONFIRMED, REJECTED, UNVERIFIED
    let confirmedAt: String?
    let note: String?
    let canConfirm: Bool
    let coinsEligible: Bool
}

struct Payment: Codable, Identifiable, Hashable {
    let id: Int
    let groupId: Int
    let payerId: Int
    let payerName: String?
    let receiverId: Int
    let receiverName: String?
    let amountPaise: Int
    let note: String?
    let createdAt: String
    var confirmation: PaymentConfirmation?
}

struct GroupDetail: Codable {
    let id: Int
    let name: String
    let groupType: String
    let expectedMembers: Int?
    let arm: String?
    let coinsEnabled: Bool
    let members: [Member]
    let myNetPaise: Int
    let debts: [Debt]
    let expenses: [Expense]
    let payments: [Payment]
}

struct HouseholdMember: Codable, Hashable { let userId: Int; let name: String?; let confirmedThisWeek: Bool; let isYou: Bool }
struct LastWeek: Codable, Hashable { let progress: Int; let status: String; let target: Int }
struct PotRedemption: Codable, Hashable, Identifiable {
    let id: String; let redeemedBy: String?; let brand: String; let faceValueInr: Int; let coins: Int; let status: String; let createdAt: String
}

struct Household: Codable {
    let groupId: Int
    let weekStart: String
    let target: Int
    let progress: Int
    let goalMet: Bool
    let goalReward: Int
    let potCoins: Int
    let potInr: Double
    let weeksSquared: Int
    let members: [HouseholdMember]
    let expectedMembers: Int?
    let lastWeek: LastWeek?
    let potRedemptions: [PotRedemption]
    let inviteSuggested: Bool
}

struct ExpiringSoon: Codable { let coins: Int; let date: String? }
struct HouseholdPot: Codable, Hashable { let groupId: Int; let groupName: String; let coins: Int }
struct CapNotice: Codable, Hashable { let capKey: String; let message: String }

struct Wallet: Codable {
    let balance: Int
    let inrValue: Double
    let coinsPerInr: Int
    let expiringSoon: ExpiringSoon
    let pending: Int
    let deficit: Int
    let redemptionFrozen: Bool
    let householdPots: [HouseholdPot]
    let capNotice: CapNotice?
}

struct LedgerEntry: Codable, Identifiable, Hashable {
    let id: String
    let amount: Int
    let entryType: String
    let status: String
    let reasonCode: String
    let text: String
    let counterparty: String?
    let reversesEntryId: String?
    let createdAt: String
}

struct LedgerPage: Codable { let entries: [LedgerEntry]; let nextCursor: String? }

struct Celebration: Codable, Identifiable, Hashable {
    let id: String
    let kind: String
    let coins: Int
    let title: String
    let bonusMultiplier: Int?
    let bonusCoins: Int
}

struct CelebrationsResponse: Codable { let celebrations: [Celebration] }

struct CatalogItem: Codable, Identifiable, Hashable {
    let id: String
    let scope: String
    let brand: String
    let category: String
    let faceValueInr: Int
    let coinCost: Int
    let affordable: Bool
    let coinsNeeded: Int
}

struct Catalog: Codable { let items: [CatalogItem]; let balance: Int; let potBalance: Int? }

struct Redemption: Codable, Identifiable, Hashable {
    let id: String
    let status: String     // REQUESTED, HELD, FULFILLED, FAILED, REFUNDED
    let coins: Int
    let brand: String
    let faceValueInr: Int
    let scope: String
    let groupId: Int?
    let code: String?
    let failureCode: String?
    let createdAt: String
}

struct RedemptionsResponse: Codable { let redemptions: [Redemption] }

struct NeedsYouItem: Codable, Identifiable, Hashable {
    let kind: String
    let groupName: String
    let expense: Expense?
    let payment: Payment?
    let receiverReward: Int?
    var id: String { kind + "-" + String(expense?.id ?? payment?.id ?? 0) }
}

struct NeedsYou: Codable { let items: [NeedsYouItem] }

struct InviteLink: Codable { let referralId: String; let token: String; let link: String; let appLink: String; let message: String; let whatsappUrl: String }
struct InviteStatus: Codable, Identifiable, Hashable { let id: String; let status: String; let statusText: String; let inviteeName: String?; let createdAt: String }
struct InvitesResponse: Codable { let invites: [InviteStatus] }
struct AcceptResponse: Codable { let groupId: Int; let alreadyMember: Bool; let groupName: String? }

struct AppNotification: Codable, Identifiable, Hashable {
    let id: String
    let notificationId: String
    let title: String
    let body: String
    let payload: [String: JSONValue]
    let status: String
    let read: Bool
    let createdAt: String
}

struct NotificationsResponse: Codable { let notifications: [AppNotification]; let unread: Int? }

struct NotificationPref: Codable, Identifiable, Hashable { let id: String; let label: String; var enabled: Bool }
struct PrefsResponse: Codable { var prefs: [NotificationPref]; let hideCoins: Bool }

struct RemindResponse: Codable { let reminded: [PersonRef] }

struct Surprise: Codable { let pAny: Double; let p3x: Double; let p2x: Double }
struct EarnConfig: Codable {
    let firstWin: Int; let expenseAdder: Int; let expenseConfirmer: Int; let settlePayer: Int; let settleQuickBonus: Int
    let settleReceiver: Int; let inviteEach: Int; let householdGoal: Int; let householdGoalTarget: Int; let quickWindowHours: Int
}

struct CoinConfig: Codable {
    let version: Int
    let enabled: Bool
    let killSwitch: Bool
    let coinValueInr: Double
    let coinsPerInr: Int
    let earn: EarnConfig
    let surprise: Surprise
}

/// Minimal JSON value for free-form payloads.
enum JSONValue: Codable, Hashable {
    case string(String), int(Int), double(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var intValue: Int? { if case .int(let v) = self { return v }; if case .string(let s) = self { return Int(s) }; return nil }
    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
}
