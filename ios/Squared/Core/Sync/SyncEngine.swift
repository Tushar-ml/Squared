import Foundation

/// Merging a shared group between phones, with no server.
///
/// A phone sends the whole group: its people, expenses and payments, each carrying a global uid and a
/// "last changed" stamp (time + device). The receiver keeps whichever copy of each record is newer, so
/// the result is the same whichever phone sends first, and syncing twice changes nothing. Deletions are
/// records too (marked deleted), so they spread like edits. Membership merges per person: the latest
/// add or remove wins. Coins never travel; each phone keeps its own.
enum SyncEngine {
    struct Bundle: Codable {
        var version = 1
        var fromDevice: String
        var fromName: String
        var group: GroupRec
        var people: [PersonRec]
        var expenses: [ExpenseRec]
        var payments: [PaymentRec]
    }

    struct Stamp: Codable, Comparable {
        var at: Date
        var origin: String
        static func < (a: Stamp, b: Stamp) -> Bool { a.at == b.at ? a.origin < b.origin : a.at < b.at }
    }

    struct GroupRec: Codable {
        var uid: String, name: String, type: String, currency: String, simplify: Bool
        var defaultSplit: DefaultSplit?, expected: Int?, createdAt: Date, stamp: Stamp
        var members: [String]
        var memberChanges: [String: LocalDB.MemberChange]
        var senderUid: String                 // who "you" is on the sending phone
    }
    struct PersonRec: Codable { var uid: String, name: String, upi: String?, stamp: Stamp }
    struct ExpenseRec: Codable {
        var uid: String, description: String, amount: Int, splitType: String, category: String
        var originalCurrency: String?, originalAmount: Int?, fxRate: Double?
        var paidBy: String, addedBy: String?, splits: [String: Int], meta: MetaRec
        var notes: [LocalDB.Note], createdAt: Date, deleted: Bool, version: Int, stamp: Stamp
    }
    struct MetaRec: Codable { var participants: [String]?, exact: [String: Int]?, percents: [String: Double]?, shares: [String: Double]? }
    struct PaymentRec: Codable {
        var uid: String, payer: String, receiver: String, amount: Int, note: String?, createdAt: Date, deleted: Bool, stamp: Stamp
    }

    struct Result: Equatable { var newExpenses = 0, updatedExpenses = 0, newPayments = 0, newPeople = 0 }

    // MARK: sending

    static func bundle(_ s: LocalDB.Store, groupId: Int) -> Bundle? {
        guard let g = s.group(groupId), let guid = g.uid, let dev = s.deviceId else { return nil }
        let meId = s.me?.id
        // on this phone "you" is the me person; in the group it's the member uid this phone uses for you
        func uid(_ pid: Int) -> String? { pid == meId ? (g.meUid ?? s.me?.uid) : s.person(pid)?.uid }
        func stamp(_ at: Date?, _ origin: String?, _ fallback: Date) -> Stamp { Stamp(at: at ?? fallback, origin: origin ?? dev) }
        func keyed<T>(_ d: [String: T]?) -> [String: T]? {
            d.map { Dictionary(uniqueKeysWithValues: $0.compactMap { k, v in Int(k).flatMap(uid).map { ($0, v) } }) }
        }
        let exps = s.expenses.filter { $0.groupId == groupId }   // bills added by a recurring rule travel too; the rule doesn't
        var peopleIds = Set(g.members)
        for e in exps { peopleIds.insert(e.paidBy); e.splits.forEach { peopleIds.insert($0.person) }; if let a = e.addedBy { peopleIds.insert(a) } }
        let pays = s.payments.filter { $0.groupId == groupId }
        for p in pays { peopleIds.insert(p.payer); peopleIds.insert(p.receiver) }
        let people: [PersonRec] = peopleIds.compactMap { pid in
            guard let p = s.person(pid), let u = uid(pid) else { return nil }
            return PersonRec(uid: u, name: p.name, upi: p.upi, stamp: stamp(p.updatedAt, p.origin, p.createdAt))
        }
        return Bundle(
            fromDevice: dev, fromName: s.me?.name ?? "",
            group: GroupRec(uid: guid, name: g.name, type: g.type, currency: g.currency, simplify: g.simplify,
                            defaultSplit: nil, expected: g.expected, createdAt: g.createdAt,
                            stamp: stamp(g.updatedAt, g.origin, g.createdAt), members: g.members.compactMap(uid),
                            memberChanges: g.memberChanges ?? [:], senderUid: g.meUid ?? s.me?.uid ?? ""),
            people: people,
            expenses: exps.compactMap { e in
                guard let u = e.uid, let payer = uid(e.paidBy) else { return nil }
                return ExpenseRec(uid: u, description: e.description, amount: e.amount, splitType: e.splitType, category: e.category,
                                  originalCurrency: e.originalCurrency, originalAmount: e.originalAmount, fxRate: e.fxRate,
                                  paidBy: payer, addedBy: e.addedBy.flatMap(uid),
                                  splits: Dictionary(uniqueKeysWithValues: e.splits.compactMap { sp in uid(sp.person).map { ($0, sp.share) } }),
                                  meta: MetaRec(participants: e.meta?.participants?.compactMap(uid), exact: keyed(e.meta?.exact),
                                                percents: keyed(e.meta?.percents), shares: keyed(e.meta?.shares)),
                                  notes: e.notes, createdAt: e.createdAt, deleted: e.deleted, version: e.version,
                                  stamp: stamp(e.updatedAt, e.origin, e.createdAt))
            },
            payments: pays.compactMap { p in
                guard let u = p.uid, let a = uid(p.payer), let b = uid(p.receiver) else { return nil }
                return PaymentRec(uid: u, payer: a, receiver: b, amount: p.amount, note: p.note, createdAt: p.createdAt,
                                  deleted: p.deleted, stamp: stamp(p.updatedAt, p.origin, p.createdAt))
            })
    }

    // MARK: receiving

    /// True if this phone already has the group (merge silently); false means ask "which one is you?" first.
    static func knows(_ s: LocalDB.Store, _ b: Bundle) -> Bool { s.groups.contains { $0.uid == b.group.uid && !$0.archived } }

    /// Merge a bundle. For a group this phone hasn't seen, `claim` is the member uid that is you.
    static func merge(_ s: inout LocalDB.Store, _ b: Bundle, claim: String? = nil) throws -> Result {
        var r = Result()
        if s.needsSyncIds { s.fillSyncIds() }
        guard let meId = s.me?.id else { throw LocalError(400, "Set your name first") }
        let dev = s.deviceId ?? ""
        var gi = s.groups.firstIndex { $0.uid == b.group.uid && !$0.archived }
        if gi == nil {
            guard let claim, b.group.members.contains(claim) || b.people.contains(where: { $0.uid == claim }) else {
                throw LocalError(409, "Pick which member is you")
            }
            let id = s.newId()
            s.groups.append(.init(id: id, name: b.group.name, type: b.group.type, currency: b.group.currency,
                                  simplify: b.group.simplify, expected: b.group.expected, members: [meId],
                                  createdAt: b.group.createdAt, uid: b.group.uid, updatedAt: b.group.stamp.at,
                                  origin: b.group.stamp.origin, shared: true, meUid: claim, memberChanges: [:]))
            gi = s.groups.count - 1
        }
        let g = gi!
        let meUid = s.groups[g].meUid ?? s.me?.uid

        // people: uids map to local people; the group's "you" uid maps to me
        var local: [String: Int] = [:]
        if let meUid { local[meUid] = meId }
        if let mine = s.me?.uid { local[mine] = meId }
        for p in b.people where local[p.uid] == nil {
            if let i = s.people.firstIndex(where: { $0.uid == p.uid }) {
                local[p.uid] = s.people[i].id
                let mine = Stamp(at: s.people[i].updatedAt ?? s.people[i].createdAt, origin: s.people[i].origin ?? dev)
                if p.stamp > mine && !s.people[i].isMe {
                    s.people[i].name = p.name; s.people[i].upi = p.upi
                    s.people[i].updatedAt = p.stamp.at; s.people[i].origin = p.stamp.origin
                }
            } else {
                let id = s.newId()
                s.people.append(.init(id: id, name: p.name, upi: p.upi, isMe: false, createdAt: Date(),
                                      uid: p.uid, updatedAt: p.stamp.at, origin: p.stamp.origin))
                local[p.uid] = id
                r.newPeople += 1
            }
        }
        func pid(_ u: String) -> Int? { local[u] }

        // group fields: newer wins
        let gStamp = Stamp(at: s.groups[g].updatedAt ?? s.groups[g].createdAt, origin: s.groups[g].origin ?? dev)
        if b.group.stamp > gStamp {
            s.groups[g].name = b.group.name; s.groups[g].simplify = b.group.simplify
            s.groups[g].expected = b.group.expected
            if s.liveExpenses(s.groups[g].id).isEmpty { s.groups[g].currency = b.group.currency }
            s.groups[g].updatedAt = b.group.stamp.at; s.groups[g].origin = b.group.stamp.origin
        }
        // membership: per person, the latest add/remove wins; people with no record stay in
        var changes = s.groups[g].memberChanges ?? [:]
        for (u, c) in b.group.memberChanges {
            if let mine = changes[u], Stamp(at: mine.at, origin: mine.origin) >= Stamp(at: c.at, origin: c.origin) { continue }
            changes[u] = c
        }
        s.groups[g].memberChanges = changes
        let currentUids = Set(s.groups[g].members.compactMap { id in id == meId ? meUid : s.person(id)?.uid })
        var members: [Int] = []
        for u in currentUids.union(b.group.members) {
            if let c = changes[u], !c.present { continue }
            if let id = pid(u) ?? s.people.first(where: { $0.uid == u })?.id, !members.contains(id) { members.append(id) }
        }
        members.removeAll { $0 == meId }
        s.groups[g].members = [meId] + members.sorted()
        s.groups[g].shared = true
        let gid = s.groups[g].id

        func keyed<T>(_ d: [String: T]?) -> [String: T]? {
            d.map { Dictionary(uniqueKeysWithValues: $0.compactMap { k, v in pid(k).map { (String($0), v) } }) }
        }
        for e in b.expenses {
            guard let payer = pid(e.paidBy) else { continue }
            let splits = e.splits.compactMap { k, v in pid(k).map { LocalDB.SplitRow(person: $0, share: v) } }.sorted { $0.person < $1.person }
            let meta = SplitMeta(participants: e.meta.participants?.compactMap(pid), exact: keyed(e.meta.exact),
                                 percents: keyed(e.meta.percents), shares: keyed(e.meta.shares))
            if let i = s.expenses.firstIndex(where: { $0.uid == e.uid }) {
                let mine = Stamp(at: s.expenses[i].updatedAt ?? s.expenses[i].createdAt, origin: s.expenses[i].origin ?? dev)
                guard e.stamp > mine else { continue }
                s.expenses[i].description = e.description; s.expenses[i].amount = e.amount; s.expenses[i].splitType = e.splitType
                s.expenses[i].category = e.category; s.expenses[i].originalCurrency = e.originalCurrency
                s.expenses[i].originalAmount = e.originalAmount; s.expenses[i].fxRate = e.fxRate
                s.expenses[i].paidBy = payer; s.expenses[i].splits = splits; s.expenses[i].meta = meta
                s.expenses[i].notes = e.notes; s.expenses[i].deleted = e.deleted; s.expenses[i].version = max(s.expenses[i].version, e.version)
                s.expenses[i].updatedAt = e.stamp.at; s.expenses[i].origin = e.stamp.origin
                r.updatedExpenses += 1
            } else {
                s.expenses.append(.init(id: s.newId(), groupId: gid, description: e.description, amount: e.amount, splitType: e.splitType,
                                        meta: meta, category: e.category, originalCurrency: e.originalCurrency, originalAmount: e.originalAmount,
                                        fxRate: e.fxRate, paidBy: payer, version: e.version, splits: splits, createdAt: e.createdAt,
                                        recurringId: nil, notes: e.notes, deleted: e.deleted, uid: e.uid, updatedAt: e.stamp.at,
                                        origin: e.stamp.origin, addedBy: e.addedBy.flatMap(pid)))
                if !e.deleted { r.newExpenses += 1 }
            }
        }
        for p in b.payments {
            guard let a = pid(p.payer), let c = pid(p.receiver) else { continue }
            if let i = s.payments.firstIndex(where: { $0.uid == p.uid }) {
                let mine = Stamp(at: s.payments[i].updatedAt ?? s.payments[i].createdAt, origin: s.payments[i].origin ?? dev)
                guard p.stamp > mine else { continue }
                s.payments[i].amount = p.amount; s.payments[i].note = p.note; s.payments[i].deleted = p.deleted
                s.payments[i].payer = a; s.payments[i].receiver = c
                s.payments[i].updatedAt = p.stamp.at; s.payments[i].origin = p.stamp.origin
            } else {
                s.payments.append(.init(id: s.newId(), groupId: gid, payer: a, receiver: c, amount: p.amount, note: p.note,
                                        createdAt: p.createdAt, deleted: p.deleted, uid: p.uid, updatedAt: p.stamp.at, origin: p.stamp.origin))
                if !p.deleted { r.newPayments += 1 }
            }
        }
        return r
    }
}
