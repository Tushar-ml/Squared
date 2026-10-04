import Foundation

/// Everything Squared knows, stored on this device only: one JSON file in Application Support, written
/// atomically after every change, plus bill photos as separate files. Export copies this file.
final class LocalDB: @unchecked Sendable {
    static let shared = LocalDB()

    struct Person: Codable, Hashable {
        var id: Int
        var name: String
        var upi: String?
        var isMe: Bool
        var createdAt: Date
        // sync: the same uid on every phone; updatedAt + origin decide which edit wins
        var uid: String?
        var updatedAt: Date?
        var origin: String?
    }

    struct Group: Codable {
        var id: Int
        var name: String
        var type: String
        var currency: String
        var simplify = false
        var defaultSplit: DefaultSplit?
        var expected: Int?
        var members: [Int]
        var createdAt: Date
        var archived = false
        var uid: String?
        var updatedAt: Date?
        var origin: String?
        var shared: Bool?                    // synced with someone at least once
        var meUid: String?                   // which member uid is "you" in this group (yours, or the one you claimed)
        var memberChanges: [String: MemberChange]?   // person uid -> latest add/remove, for merging membership
    }

    struct MemberChange: Codable, Hashable { var present: Bool; var at: Date; var origin: String }

    /// What the expense form sends; also the template a recurring bill re-uses.
    struct ExpenseInput: Codable {
        var description: String
        var amount: Int                      // minor units of `currency`
        var currency: String?
        var paidBy: Int?
        var splitType: String?
        var participants: [Int]?
        var exact: [String: Int]?
        var percents: [String: Double]?
        var shares: [String: Double]?
        var category: String?
    }

    struct SplitRow: Codable { var person: Int; var share: Int }
    struct Note: Codable { var id: String; var body: String; var createdAt: Date }

    struct Expense: Codable {
        var id: Int
        var groupId: Int
        var description: String
        var amount: Int                      // group currency
        var splitType: String
        var meta: SplitMeta?
        var category: String
        var originalCurrency: String?
        var originalAmount: Int?
        var fxRate: Double?
        var paidBy: Int
        var version = 1
        var splits: [SplitRow]
        var createdAt: Date
        var recurringId: String?
        var notes: [Note] = []
        var deleted = false
        var uid: String?
        var updatedAt: Date?
        var origin: String?
        var addedBy: Int?                    // who logged it (you, unless it arrived by sync)
    }

    struct Payment: Codable {
        var id: Int
        var groupId: Int
        var payer: Int
        var receiver: Int
        var amount: Int
        var note: String?
        var createdAt: Date
        var deleted = false
        var uid: String?
        var updatedAt: Date?
        var origin: String?
    }

    struct Attachment: Codable { var id: String; var expenseId: Int; var file: String; var contentType: String; var bytes: Int; var createdAt: Date }

    struct Recurring: Codable {
        var id: String
        var groupId: Int
        var input: ExpenseInput
        var frequency: String                // MONTHLY or WEEKLY
        var day: Int                         // 1-28, or 0 (Mon) - 6
        var nextRun: String                  // yyyy-MM-dd, local time
        var lastRun: String?
        var active = true
    }

    struct Coin: Codable {
        var id: String
        var amount: Int
        var reason: String
        var text: String
        var groupId: Int?
        var source: String?                  // e.g. "expense:12", so deleting it takes the coins back
        var createdAt: Date
    }

    struct Celebration: Codable { var id: String; var kind: String; var coins: Int; var title: String; var multiplier: Int?; var bonus: Int; var seen = false }
    struct Fx: Codable { var rates: [String: Double]; var asOf: String?; var fetchedAt: Date }

    struct Store: Codable {
        var version = 1
        var nextId = 1
        var people: [Person] = []
        var groups: [Group] = []
        var expenses: [Expense] = []
        var payments: [Payment] = []
        var attachments: [Attachment] = []
        var recurring: [Recurring] = []
        var budgets: [String: [String: Int]] = [:]     // group id -> category -> monthly limit
        var budgetAlerts: [String] = []                 // "group:category:month:threshold" already announced
        var coins: [Coin] = []
        var celebrations: [Celebration] = []
        var goalWeeks: [String] = []                    // "group:weekStart" already rewarded
        var fx: [String: Fx] = [:]
        var hideCoins = false
        var introSeen = false
        var locale = "en"
        var createdAt = Date()
        var deviceId: String?                // this install, for sync tie-breaks
        var meUids: [String]?                // person uids that mean "you" in groups shared from other phones
    }

    static var defaultFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Squared", isDirectory: true)
    }
    let folder: URL
    var file: URL { folder.appendingPathComponent("squared.json") }
    var photos: URL { folder.appendingPathComponent("photos", isDirectory: true) }

    private let lock = NSLock()
    private var store: Store

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(folder: URL = LocalDB.defaultFolder) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("photos"), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: folder.appendingPathComponent("squared.json")), let s = try? Self.decoder.decode(Store.self, from: data) {
            store = s
        } else {
            store = Store()
        }
        if store.needsSyncIds { try? write { $0.fillSyncIds() } }
    }

    func read<T>(_ body: (Store) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(store)
    }

    /// Mutate and save. A throw leaves the stored data untouched.
    func write<T>(_ body: (inout Store) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var copy = store
        let out = try body(&copy)
        if copy.needsSyncIds { copy.fillSyncIds() }     // new records get their global ids here
        let data = try Self.encoder.encode(copy)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        store = copy
        return out
    }

    // MARK: backup

    func exportData() throws -> Data { try read { try Self.encoder.encode($0) } }

    func importData(_ data: Data) throws {
        let s = try Self.decoder.decode(Store.self, from: data)
        try write { $0 = s }
    }

    func eraseEverything() throws {
        try write { $0 = Store() }
        try? FileManager.default.removeItem(at: photos)
        try? FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
    }
}

extension LocalDB.Store {
    /// Older data (and anything created before sync existed) gets global ids.
    var needsSyncIds: Bool {
        deviceId == nil || people.contains { $0.uid == nil } || groups.contains { $0.uid == nil || $0.meUid == nil }
            || expenses.contains { $0.uid == nil } || payments.contains { $0.uid == nil }
    }

    mutating func fillSyncIds() {
        if deviceId == nil { deviceId = UUID().uuidString }
        let dev = deviceId!
        for i in people.indices where people[i].uid == nil {
            people[i].uid = UUID().uuidString; people[i].updatedAt = people[i].createdAt; people[i].origin = dev
        }
        for i in groups.indices where groups[i].uid == nil {
            groups[i].uid = UUID().uuidString; groups[i].updatedAt = groups[i].createdAt; groups[i].origin = dev
        }
        for i in groups.indices where groups[i].meUid == nil { groups[i].meUid = me?.uid }
        for i in expenses.indices where expenses[i].uid == nil {
            expenses[i].uid = UUID().uuidString; expenses[i].updatedAt = expenses[i].createdAt; expenses[i].origin = dev
            if expenses[i].addedBy == nil { expenses[i].addedBy = me?.id }
        }
        for i in payments.indices where payments[i].uid == nil {
            payments[i].uid = UUID().uuidString; payments[i].updatedAt = payments[i].createdAt; payments[i].origin = dev
        }
    }

    /// Stamp a change so it wins over older copies on other phones.
    mutating func touchGroup(_ i: Int) { groups[i].updatedAt = Date(); groups[i].origin = deviceId }
    mutating func touchPerson(_ i: Int) { people[i].updatedAt = Date(); people[i].origin = deviceId }
    mutating func touchExpense(_ i: Int) { expenses[i].updatedAt = Date(); expenses[i].origin = deviceId }
    mutating func touchPayment(_ i: Int) { payments[i].updatedAt = Date(); payments[i].origin = deviceId }

    mutating func setMember(_ gi: Int, _ pid: Int, present: Bool) {
        guard let puid = person(pid)?.uid else { return }
        var m = groups[gi].memberChanges ?? [:]
        m[puid] = .init(present: present, at: Date(), origin: deviceId ?? "")
        groups[gi].memberChanges = m
        if present { if !groups[gi].members.contains(pid) { groups[gi].members.append(pid) } }
        else { groups[gi].members.removeAll { $0 == pid } }
    }

    mutating func newId() -> Int { defer { nextId += 1 }; return nextId }
    var me: LocalDB.Person? { people.first(where: \.isMe) }
    func person(_ id: Int) -> LocalDB.Person? { people.first { $0.id == id } }
    func name(_ id: Int) -> String { person(id).map { $0.isMe ? $0.name : $0.name } ?? "Someone" }
    func group(_ id: Int) -> LocalDB.Group? { groups.first { $0.id == id && !$0.archived } }
    func liveExpenses(_ gid: Int) -> [LocalDB.Expense] { expenses.filter { $0.groupId == gid && !$0.deleted } }
    func livePayments(_ gid: Int) -> [LocalDB.Payment] { payments.filter { $0.groupId == gid && !$0.deleted } }
}
