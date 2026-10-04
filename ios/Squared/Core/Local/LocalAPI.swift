import Foundation
import UIKit

/// The app's "server", running on the device. Screens still call `APIClient.request(method, path)`;
/// this answers from `LocalDB` with the same JSON the old backend returned, so the views didn't change.
/// Nothing leaves the device except exchange-rate lookups.
final class LocalAPI: @unchecked Sendable {
    static let shared = LocalAPI()
    private let db: LocalDB
    init(db: LocalDB = .shared) { self.db = db }

    // Coin rules (personal: you earn for keeping your own records square)
    static let earn: [String: Int] = ["first_win": 50, "expense_adder": 5, "expense_confirmer": 0, "settle_payer": 20,
                                      "settle_quick_bonus": 0, "settle_receiver": 10, "invite_each": 0,
                                      "household_goal": 120, "household_goal_target": 5, "quick_window_hours": 48]
    static let dailyCap = 60, monthlyCap = 600
    static let coinValueInr = 0.25

    func handle(_ method: String, _ rawPath: String, body: [String: Any]?, data: Data? = nil) async throws -> Data {
        let comps = URLComponents(string: "http://local" + rawPath)!
        let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let p = comps.path.split(separator: "/").map(String.init)
        let b = body ?? [:]
        func int(_ i: Int) -> Int? { p.count > i ? Int(p[i]) : nil }
        let out: Any
        switch (method, p.first ?? "", p.count) {
        case ("GET", "me", 1): out = me()
        case ("PATCH", "me", 1): out = try patchMe(b)
        case ("DELETE", "me", 1): try db.eraseEverything(); out = ["ok": true]
        case ("GET", "me", 2) where p[1] == "activation": out = activation()
        case ("GET", "me", 2) where p[1] == "insights": out = try await myInsights(q["month"], q["currency"] ?? "INR")
        case ("GET", "me", 2) where p[1] == "activity": out = activity()
        case ("GET", "me", 2) where p[1] == "notifications": out = ["notifications": [Any](), "unread": 0]
        case ("POST", "me", 2) where p[1] == "notifications": out = ["ok": true]
        case ("GET", "me", 3) where p[1] == "inbox": out = ["items": [Any]()]
        case ("GET", "config", 2): out = config()

        case ("GET", "groups", 1): out = ["groups": groupSummaries()]
        case ("POST", "groups", 1): out = try createGroup(b)
        case ("GET", "groups", 2): out = try groupDetail(int(1)!)
        case ("PATCH", "groups", 2): out = try patchGroup(int(1)!, b)
        case ("POST", "groups", 3) where p[2] == "expenses": out = try await createExpense(int(1)!, b)
        case ("POST", "groups", 3) where p[2] == "payments": out = try recordPayment(int(1)!, b)
        case ("POST", "groups", 3) where p[2] == "members": out = try addMember(int(1)!, b)
        case ("DELETE", "groups", 4) where p[2] == "members": out = try removeMember(int(1)!, int(3)!)
        case ("GET", "groups", 3) where p[2] == "household": out = try household(int(1)!)
        case ("GET", "groups", 3) where p[2] == "insights": out = try groupInsights(int(1)!, q["month"])
        case ("GET", "groups", 3) where p[2] == "report":
            return try report(int(1)!, q["month"], q["format"] ?? "csv")
        case ("GET", "groups", 3) where p[2] == "recurring": out = recurringList(int(1)!)
        case ("POST", "groups", 3) where p[2] == "recurring": out = try createRecurring(int(1)!, b)
        case ("GET", "groups", 3) where p[2] == "budgets": out = try budgets(int(1)!)
        case ("PUT", "groups", 3) where p[2] == "budgets": out = try setBudgets(int(1)!, b)
        case ("GET", "groups", 3) where p[2] == "search": out = try search(int(1)!, q)

        case ("PATCH", "people", 2): out = try patchPerson(int(1)!, b)
        case ("GET", "friends", 1): out = ["friends": friends()]
        case ("POST", "friends", 1): out = try addFriend(b)

        case ("GET", "expenses", 2): out = try expenseJSON(int(1)!)
        case ("PATCH", "expenses", 2): out = try await patchExpense(int(1)!, b)
        case ("DELETE", "expenses", 2): out = try deleteExpense(int(1)!)
        case ("GET", "expenses", 3) where p[2] == "comments": out = try notes(int(1)!)
        case ("POST", "expenses", 3) where p[2] == "comments": out = try addNote(int(1)!, b)
        case ("DELETE", "comments", 2): out = try deleteNote(p[1])
        case ("GET", "expenses", 3) where p[2] == "attachments": out = ["attachments": attachments(int(1)!)]
        case ("POST", "expenses", 3) where p[2] == "attachments": out = try addAttachment(int(1)!, data ?? Data())
        case ("GET", "attachments", 2): return try photo(p[1])
        case ("DELETE", "attachments", 2): out = try deletePhoto(p[1])
        case ("DELETE", "payments", 2): out = try deletePayment(int(1)!)

        case ("PATCH", "recurring", 2): out = try patchRecurring(p[1], b)
        case ("GET", "coins", 2) where p[1] == "wallet": out = wallet()
        case ("GET", "coins", 2) where p[1] == "ledger": out = ledger()
        case ("GET", "coins", 2) where p[1] == "celebrations": out = celebrations()
        case ("POST", "coins", 4) where p[1] == "celebrations": try markSeen(p[2]); out = ["ok": true]
        case ("GET", "fx", 2) where p[1] == "currencies": out = currencies()
        case ("GET", "fx", 2) where p[1] == "rates": out = try await rates(q["base"] ?? "INR")
        default:
            throw LocalError(404, "That isn't available in the offline app")
        }
        return try JSONSerialization.data(withJSONObject: out)
    }

    // MARK: - you

    /// The person using the app. Created on first launch; there's no account.
    @discardableResult
    func ensureMe(name: String = "") -> Int {
        if let id = db.read({ $0.me?.id }) { return id }
        return (try? db.write { s -> Int in
            let id = s.newId()
            s.people.append(.init(id: id, name: name, upi: nil, isMe: true, createdAt: Date()))
            return id
        }) ?? 0
    }

    private func me() -> [String: Any] {
        ensureMe()
        return db.read { s in
            let m = s.me!
            return ["id": m.id, "name": m.name, "email": NSNull(), "upi_id": m.upi as Any? ?? NSNull(), "role": "USER",
                    "hide_coins": s.hideCoins, "intro_seen": s.introSeen, "locale": s.locale,
                    "created_at": LocalLogic.iso(m.createdAt)]
        }
    }

    private func patchMe(_ b: [String: Any]) throws -> [String: Any] {
        let meId = ensureMe()
        try db.write { s in
            if let i = s.people.firstIndex(where: { $0.id == meId }) {
                if let n = b["name"] as? String { s.people[i].name = String(n.trimmingCharacters(in: .whitespaces).prefix(60)) }
                if let u = b["upi_id"] as? String { s.people[i].upi = u.isEmpty ? nil : u }
            }
            if let v = b["hide_coins"] as? Bool { s.hideCoins = v }
            if let v = b["intro_seen"] as? Bool { s.introSeen = v }
            if let v = b["locale"] as? String, ["en", "hi"].contains(v) { s.locale = v }
        }
        return me()
    }

    private func activation() -> [String: Any] {
        ["profile_done": true, "group": NSNull(), "steps": [Any](), "activated": true, "next_step": NSNull(),
         "confirm_expense_id": NSNull(), "waiting_expense_id": NSNull(), "waiting_on": [Any](), "coins_enabled": true,
         "first_win_coins": Self.earn["first_win"]!]
    }

    private func config() -> [String: Any] {
        ["version": 1, "enabled": true, "kill_switch": false, "coin_value_inr": Self.coinValueInr, "coins_per_inr": 4,
         "earn": Self.earn, "surprise": ["p_any": 0.2, "p_3x": 0.05, "p_2x": 0.15], "redemption": ["enabled": false]]
    }

    // MARK: - groups and people

    private func meId() -> Int { ensureMe() }

    private func groupSummaries() -> [[String: Any]] {
        let me = meId()
        return db.read { s in
            s.groups.filter { !$0.archived && $0.type != "DIRECT" }.sorted { $0.createdAt > $1.createdAt }.map { g in
                ["id": g.id, "name": g.name, "group_type": g.type, "currency": g.currency, "member_count": g.members.count,
                 "my_net_paise": LocalLogic.nets(s, g.id)[me] ?? 0, "coins_enabled": !s.hideCoins]
            }
        }
    }

    private func createGroup(_ b: [String: Any]) throws -> [String: Any] {
        let me = meId()
        let name = (b["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw LocalError(400, "Give the group a name") }
        let cur = (b["currency"] as? String ?? "INR").uppercased()
        guard LocalLogic.currencies.contains(cur) else { throw LocalError(400, "Unsupported currency") }
        let id = try db.write { s -> Int in
            let id = s.newId()
            s.groups.append(.init(id: id, name: String(name.prefix(60)), type: b["group_type"] as? String ?? "HOME",
                                  currency: cur, expected: b["expected_members"] as? Int, members: [me], createdAt: Date()))
            return id
        }
        return groupSummaries().first { $0["id"] as? Int == id } ?? [:]
    }

    private func requireGroup(_ s: LocalDB.Store, _ gid: Int) throws -> LocalDB.Group {
        guard let g = s.group(gid) else { throw LocalError(404, "Group not found") }
        return g
    }

    private func displayName(_ s: LocalDB.Store, _ g: LocalDB.Group) -> String {
        guard g.type == "DIRECT" else { return g.name }
        return g.members.compactMap { s.person($0) }.first { !$0.isMe }?.name ?? g.name
    }

    private func groupDetail(_ gid: Int) throws -> [String: Any] {
        let me = meId()
        return try db.read { s in
            let g = try requireGroup(s, gid)
            let debts = LocalLogic.debts(s, g).filter { $0.key.debtor == me || $0.key.creditor == me }
                .sorted { $0.value > $1.value }.map { k, v -> [String: Any] in
                    ["debtor_id": k.debtor, "debtor_name": s.name(k.debtor), "creditor_id": k.creditor,
                     "creditor_name": s.name(k.creditor), "amount_paise": v, "you_owe": k.debtor == me,
                     "creditor_upi": s.person(k.creditor)?.upi as Any? ?? NSNull(),
                     "pay_reward_hint": k.debtor == me ? Self.earn["settle_payer"]! : NSNull()] as [String: Any]
                }
            return ["id": g.id, "name": displayName(s, g), "group_type": g.type, "currency": g.currency,
                    "simplify_debts": g.simplify, "default_split": encodeDefaultSplit(g.defaultSplit), "created_by": me,
                    "expected_members": g.expected as Any? ?? NSNull(), "arm": NSNull(), "coins_enabled": !s.hideCoins,
                    "members": g.members.compactMap { s.person($0) }.map { ["id": $0.id, "name": $0.name, "is_you": $0.isMe] },
                    "my_net_paise": LocalLogic.nets(s, gid)[me] ?? 0, "debts": debts,
                    "expenses": s.liveExpenses(gid).sorted { $0.createdAt > $1.createdAt }.prefix(200).map { expenseDict(s, $0) },
                    "payments": s.livePayments(gid).sorted { $0.createdAt > $1.createdAt }.map { paymentDict(s, $0) }]
        }
    }

    private func encodeDefaultSplit(_ d: DefaultSplit?) -> Any {
        guard let d else { return NSNull() }
        var o: [String: Any] = [:]
        if let t = d.splitType { o["split_type"] = t }
        if let p = d.percents { o["percents"] = p }
        if let sh = d.shares { o["shares"] = sh }
        return o
    }

    private func patchGroup(_ gid: Int, _ b: [String: Any]) throws -> [String: Any] {
        try db.write { s in
            guard let i = s.groups.firstIndex(where: { $0.id == gid && !$0.archived }) else { throw LocalError(404, "Group not found") }
            if let n = b["name"] as? String, !n.trimmingCharacters(in: .whitespaces).isEmpty { s.groups[i].name = String(n.prefix(60)) }
            if let v = b["simplify_debts"] as? Bool { s.groups[i].simplify = v }
            if let c = b["currency"] as? String, LocalLogic.currencies.contains(c.uppercased()) {
                guard s.liveExpenses(gid).isEmpty else { throw LocalError(409, "Currency can only change before the first expense") }
                s.groups[i].currency = c.uppercased()
            }
            if let e = b["expected_members"] as? Int { s.groups[i].expected = e }
            if let ds = b["default_split"] as? [String: Any] {
                s.groups[i].defaultSplit = ds.isEmpty ? nil : DefaultSplit(splitType: ds["split_type"] as? String,
                                                                            percents: ds["percents"] as? [String: Double],
                                                                            shares: ds["shares"] as? [String: Double])
            }
        }
        return try groupDetail(gid)
    }

    private func addMember(_ gid: Int, _ b: [String: Any]) throws -> [String: Any] {
        let name = (b["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw LocalError(400, "Enter a name") }
        let upi = (b["upi_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let pid = try db.write { s -> Int in
            guard let i = s.groups.firstIndex(where: { $0.id == gid && !$0.archived }) else { throw LocalError(404, "Group not found") }
            // reuse a person you already split with elsewhere, if the name matches exactly
            let existing = s.people.first { !$0.isMe && $0.name.lowercased() == name.lowercased() }
            let pid = existing?.id ?? s.newId()
            if existing == nil { s.people.append(.init(id: pid, name: String(name.prefix(60)), upi: upi, isMe: false, createdAt: Date())) }
            else if let upi, let j = s.people.firstIndex(where: { $0.id == pid }) { s.people[j].upi = upi }
            if !s.groups[i].members.contains(pid) { s.groups[i].members.append(pid) }
            return pid
        }
        return ["id": pid, "name": name, "is_you": false]
    }

    private func removeMember(_ gid: Int, _ pid: Int) throws -> [String: Any] {
        let me = meId()
        try db.write { s in
            guard let i = s.groups.firstIndex(where: { $0.id == gid && !$0.archived }) else { throw LocalError(404, "Group not found") }
            let nets = LocalLogic.nets(s, gid)
            if pid == me {
                // "leave" in a one-person app = delete the group, once it's square
                guard nets.values.allSatisfy({ $0 == 0 }) else { throw LocalError(409, "Settle all balances before deleting this group") }
                s.groups[i].archived = true
                s.recurring.indices.forEach { if s.recurring[$0].groupId == gid { s.recurring[$0].active = false } }
                return
            }
            if let n = nets[pid], n != 0 {
                throw LocalError(409, "\(s.name(pid)) has an open balance of \(LocalLogic.money(abs(n), s.groups[i].currency)). Settle up first.")
            }
            s.groups[i].members.removeAll { $0 == pid }
        }
        return ["ok": true]
    }

    private func patchPerson(_ pid: Int, _ b: [String: Any]) throws -> [String: Any] {
        try db.write { s in
            guard let i = s.people.firstIndex(where: { $0.id == pid }) else { throw LocalError(404, "Not found") }
            if let n = b["name"] as? String, !n.trimmingCharacters(in: .whitespaces).isEmpty { s.people[i].name = String(n.prefix(60)) }
            if let u = b["upi_id"] as? String { s.people[i].upi = u.isEmpty ? nil : u }
        }
        return ["ok": true]
    }

    private func friends() -> [[String: Any]] {
        let me = meId()
        return db.read { s in
            s.groups.filter { !$0.archived && $0.type == "DIRECT" }.sorted { $0.createdAt > $1.createdAt }.compactMap { g in
                guard let other = g.members.compactMap({ s.person($0) }).first(where: { !$0.isMe }) else { return nil }
                return ["group_id": g.id, "user_id": other.id, "name": other.name, "currency": g.currency,
                        "my_net_paise": LocalLogic.nets(s, g.id)[me] ?? 0, "coins_enabled": !s.hideCoins]
            }
        }
    }

    /// A friend is a hidden two-person group with someone you name.
    private func addFriend(_ b: [String: Any]) throws -> [String: Any] {
        let me = meId()
        let name = (b["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw LocalError(400, "Enter their name") }
        let gid = try db.write { s -> Int in
            let existing = s.people.first { !$0.isMe && $0.name.lowercased() == name.lowercased() }
            if let e = existing, let g = s.groups.first(where: { !$0.archived && $0.type == "DIRECT" && $0.members.contains(e.id) }) {
                return g.id
            }
            let pid = existing?.id ?? s.newId()
            if existing == nil {
                s.people.append(.init(id: pid, name: String(name.prefix(60)), upi: (b["upi_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                      isMe: false, createdAt: Date()))
            }
            let gid = s.newId()
            s.groups.append(.init(id: gid, name: "Friends", type: "DIRECT", currency: b["currency"] as? String ?? "INR",
                                  expected: 2, members: [me, pid], createdAt: Date()))
            return gid
        }
        return friends().first { $0["group_id"] as? Int == gid }.map { $0.merging(["created": true]) { a, _ in a } } ?? [:]
    }

    // MARK: - expenses

    private func input(_ b: [String: Any]) -> LocalDB.ExpenseInput {
        func strKeys<T>(_ v: Any?) -> [String: T]? {
            guard let d = v as? [String: Any] else { return nil }
            return d.compactMapValues { ($0 as? T) ?? (($0 as? NSNumber).flatMap { T.self == Double.self ? $0.doubleValue as? T : $0.intValue as? T }) }
        }
        return .init(description: (b["description"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                     amount: (b["amount_paise"] as? Int) ?? (b["amount_paise"] as? NSNumber)?.intValue ?? 0,
                     currency: (b["currency"] as? String)?.uppercased(), paidBy: b["paid_by"] as? Int,
                     splitType: b["split_type"] as? String, participants: b["participants"] as? [Int],
                     exact: strKeys(b["exact"]), percents: strKeys(b["percents"]), shares: strKeys(b["shares"]),
                     category: b["category"] as? String)
    }

    /// Resolve currency conversion and splits for a group.
    private func build(_ inp: LocalDB.ExpenseInput, group g: LocalDB.Group, me: Int) async throws
        -> (amount: Int, splits: [Int: Int], meta: SplitMeta, orig: String?, origAmount: Int?, rate: Double?) {
        guard !inp.description.isEmpty else { throw LocalError(400, "Say what it was for") }
        guard inp.amount > 0 else { throw LocalError(400, "Amount must be more than zero") }
        let cur = inp.currency ?? g.currency
        guard LocalLogic.currencies.contains(cur) else { throw LocalError(400, "Unsupported currency") }
        var amount = inp.amount, rate: Double?
        if cur != g.currency {
            let r = try await LocalLogic.rates(base: cur).rates[g.currency]
            guard let r else { throw LocalError(503, "No exchange rate for \(cur) to \(g.currency)") }
            rate = r
            amount = LocalLogic.convert(inp.amount, from: cur, to: g.currency, rate: r)
        }
        let payer = inp.paidBy ?? me
        guard g.members.contains(payer) else { throw LocalError(400, "Whoever paid must be in the group") }
        let (shares, meta) = try LocalLogic.split(amount, inp, members: g.members)
        return (amount, shares, meta, cur == g.currency ? nil : cur, cur == g.currency ? nil : inp.amount, rate)
    }

    private func createExpense(_ gid: Int, _ b: [String: Any], recurringId: String? = nil) async throws -> [String: Any] {
        let me = meId()
        let g = try db.read { try requireGroup($0, gid) }
        let inp = input(b)
        let r = try await build(inp, group: g, me: me)
        var celebrate: [LocalDB.Celebration] = []
        let (eid, adderCoins) = try db.write { s -> (Int, Int) in
            let id = s.newId()
            s.expenses.append(.init(id: id, groupId: gid, description: String(inp.description.prefix(80)), amount: r.amount,
                                    splitType: (inp.splitType ?? "EQUAL").uppercased(), meta: r.meta,
                                    category: LocalLogic.category(inp.category, description: inp.description),
                                    originalCurrency: r.orig, originalAmount: r.origAmount, fxRate: r.rate, paidBy: inp.paidBy ?? me,
                                    splits: r.splits.sorted { $0.key < $1.key }.map { .init(person: $0.key, share: $0.value) },
                                    createdAt: Date(), recurringId: recurringId))
            guard recurringId == nil, !s.hideCoins else { return (id, 0) }       // automatic bills don't earn
            var got = 0
            let isFirst = !s.coins.contains { $0.reason == "FIRST_WIN" }
            if isFirst, let c = award(&s, Self.earn["first_win"]!, "FIRST_WIN", "First expense logged", gid, "expense:\(id)") {
                got += c; celebrate.append(.init(id: UUID().uuidString, kind: "FIRST_WIN", coins: c, title: "Your first expense", multiplier: nil, bonus: 0))
            } else if let c = award(&s, Self.earn["expense_adder"]!, "EXPENSE_ADDER", "Logged \(inp.description)", gid, "expense:\(id)") {
                got += c
            }
            if let c = weeklyGoal(&s, gid) {
                celebrate.append(.init(id: UUID().uuidString, kind: "HOUSEHOLD_GOAL", coins: c, title: "Weekly goal met in \(displayName(s, g))",
                                       multiplier: nil, bonus: 0))
            }
            s.celebrations.append(contentsOf: celebrate)
            return (id, got)
        }
        budgetCheck(gid)
        var out = try expenseJSON(eid)
        out["success_hint"] = ["adder_coins": adderCoins, "notified": [Any]()]
        if adderCoins > 0 { NotificationCenter.default.post(name: .coinsChanged, object: nil) }
        return out
    }

    private func patchExpense(_ eid: Int, _ b: [String: Any]) async throws -> [String: Any] {
        let me = meId()
        let (old, g) = try db.read { s -> (LocalDB.Expense, LocalDB.Group) in
            guard let e = s.expenses.first(where: { $0.id == eid && !$0.deleted }) else { throw LocalError(404, "Expense not found") }
            return (e, try requireGroup(s, e.groupId))
        }
        // start from the stored values so partial edits work
        var inp = LocalDB.ExpenseInput(description: old.description, amount: old.originalAmount ?? old.amount,
                                       currency: old.originalCurrency ?? g.currency, paidBy: old.paidBy, splitType: old.splitType,
                                       participants: old.meta?.participants, exact: old.meta?.exact, percents: old.meta?.percents,
                                       shares: old.meta?.shares, category: old.category)
        let patch = input(b)
        if b["description"] != nil { inp.description = patch.description }
        if b["amount_paise"] != nil { inp.amount = patch.amount }
        if b["currency"] != nil { inp.currency = patch.currency }
        if b["paid_by"] != nil { inp.paidBy = patch.paidBy }
        if b["category"] != nil { inp.category = patch.category }
        if b["split_type"] != nil {
            inp.splitType = patch.splitType
            inp.participants = patch.participants; inp.exact = patch.exact; inp.percents = patch.percents; inp.shares = patch.shares
        }
        let r = try await build(inp, group: g, me: me)
        try db.write { s in
            guard let i = s.expenses.firstIndex(where: { $0.id == eid }) else { return }
            s.expenses[i].description = String(inp.description.prefix(80))
            s.expenses[i].amount = r.amount
            s.expenses[i].splitType = (inp.splitType ?? "EQUAL").uppercased()
            s.expenses[i].meta = r.meta
            s.expenses[i].category = LocalLogic.category(inp.category, description: inp.description)
            s.expenses[i].originalCurrency = r.orig; s.expenses[i].originalAmount = r.origAmount; s.expenses[i].fxRate = r.rate
            s.expenses[i].paidBy = inp.paidBy ?? me
            s.expenses[i].splits = r.splits.sorted { $0.key < $1.key }.map { .init(person: $0.key, share: $0.value) }
            s.expenses[i].version += 1
        }
        return try expenseJSON(eid)
    }

    private func deleteExpense(_ eid: Int) throws -> [String: Any] {
        try db.write { s in
            guard let i = s.expenses.firstIndex(where: { $0.id == eid && !$0.deleted }) else { throw LocalError(404, "Expense not found") }
            s.expenses[i].deleted = true
            reverse(&s, source: "expense:\(eid)", text: "Deleted \(s.expenses[i].description)")
        }
        NotificationCenter.default.post(name: .coinsChanged, object: nil)
        return ["ok": true]
    }

    private func expenseJSON(_ eid: Int) throws -> [String: Any] {
        try db.read { s in
            guard let e = s.expenses.first(where: { $0.id == eid && !$0.deleted }) else { throw LocalError(404, "Expense not found") }
            return expenseDict(s, e)
        }
    }

    private func expenseDict(_ s: LocalDB.Store, _ e: LocalDB.Expense) -> [String: Any] {
        let me = s.me?.id ?? 0
        let cur = s.groups.first { $0.id == e.groupId }?.currency ?? "INR"
        var meta: [String: Any] = [:]
        if let m = e.meta {
            if let v = m.participants { meta["participants"] = v }
            if let v = m.exact { meta["exact"] = v }
            if let v = m.percents { meta["percents"] = v }
            if let v = m.shares { meta["shares"] = v }
        }
        return ["id": e.id, "group_id": e.groupId, "description": e.description, "amount_paise": e.amount, "currency": cur,
                "split_type": e.splitType, "split_meta": meta, "category": e.category,
                "original_currency": e.originalCurrency as Any? ?? NSNull(), "original_amount_minor": e.originalAmount as Any? ?? NSNull(),
                "fx_rate": e.fxRate as Any? ?? NSNull(), "paid_by": e.paidBy, "paid_by_name": s.name(e.paidBy),
                "created_by": me, "created_by_name": s.name(me), "version": e.version,
                "splits": e.splits.map { ["user_id": $0.person, "name": s.name($0.person), "share_paise": $0.share] },
                "my_share_paise": e.splits.first { $0.person == me }?.share ?? 0, "created_at": LocalLogic.iso(e.createdAt)]
    }

    // MARK: - payments

    private func recordPayment(_ gid: Int, _ b: [String: Any]) throws -> [String: Any] {
        let me = meId()
        guard let receiver = b["receiver_id"] as? Int else { throw LocalError(400, "Pick who was paid") }
        let payer = b["payer_id"] as? Int ?? me
        let amount = (b["amount_paise"] as? Int) ?? (b["amount_paise"] as? NSNumber)?.intValue ?? 0
        guard amount > 0 else { throw LocalError(400, "Amount must be more than zero") }
        let pid = try db.write { s -> Int in
            let g = try requireGroup(s, gid)
            guard payer != receiver, g.members.contains(payer), g.members.contains(receiver) else { throw LocalError(400, "Pick who was paid") }
            let id = s.newId()
            s.payments.append(.init(id: id, groupId: gid, payer: payer, receiver: receiver, amount: amount,
                                    note: b["note"] as? String, createdAt: Date()))
            // settling up is the habit that keeps things square: base reward plus a chance of a surprise bonus
            if !s.hideCoins, payer == me || receiver == me {
                let base = payer == me ? Self.earn["settle_payer"]! : Self.earn["settle_receiver"]!
                let roll = Double.random(in: 0..<1)
                let mult = roll < 0.05 ? 3 : (roll < 0.20 ? 2 : 1)
                if let c = award(&s, base * mult, "SETTLE", payer == me ? "Paid \(s.name(receiver))" : "\(s.name(payer)) paid you",
                                 gid, "payment:\(id)") {
                    s.celebrations.append(.init(id: UUID().uuidString, kind: "SETTLE", coins: c,
                                                title: payer == me ? "Settled with \(s.name(receiver))" : "Payment from \(s.name(payer))",
                                                multiplier: mult > 1 ? mult : nil, bonus: mult > 1 ? c - base : 0))
                }
            }
            return id
        }
        NotificationCenter.default.post(name: .coinsChanged, object: nil)
        return db.read { s in paymentDict(s, s.payments.first { $0.id == pid }!) }
    }

    private func deletePayment(_ pid: Int) throws -> [String: Any] {
        try db.write { s in
            guard let i = s.payments.firstIndex(where: { $0.id == pid && !$0.deleted }) else { throw LocalError(404, "Not found") }
            s.payments[i].deleted = true
            reverse(&s, source: "payment:\(pid)", text: "Deleted a payment")
        }
        return ["ok": true]
    }

    private func paymentDict(_ s: LocalDB.Store, _ p: LocalDB.Payment) -> [String: Any] {
        ["id": p.id, "group_id": p.groupId, "payer_id": p.payer, "payer_name": s.name(p.payer), "receiver_id": p.receiver,
         "receiver_name": s.name(p.receiver), "amount_paise": p.amount, "note": p.note as Any? ?? NSNull(),
         "created_at": LocalLogic.iso(p.createdAt)]
    }

    // MARK: - coins

    /// Add coins within the daily and monthly limits. Returns what was actually given.
    private func award(_ s: inout LocalDB.Store, _ amount: Int, _ reason: String, _ text: String, _ gid: Int?, _ source: String?) -> Int? {
        let cal = Calendar.current, now = Date()
        let earned = s.coins.filter { $0.amount > 0 }
        let today = earned.filter { cal.isDate($0.createdAt, inSameDayAs: now) }.reduce(0) { $0 + $1.amount }
        let month = earned.filter { cal.isDate($0.createdAt, equalTo: now, toGranularity: .month) }.reduce(0) { $0 + $1.amount }
        let give = min(amount, Self.dailyCap - today, Self.monthlyCap - month)
        guard give > 0 else { return nil }
        s.coins.append(.init(id: UUID().uuidString, amount: give, reason: reason, text: text, groupId: gid, source: source, createdAt: now))
        return give
    }

    private func reverse(_ s: inout LocalDB.Store, source: String, text: String) {
        let total = s.coins.filter { $0.source == source }.reduce(0) { $0 + $1.amount }
        guard total > 0 else { return }
        s.coins.append(.init(id: UUID().uuidString, amount: -total, reason: "REVERSAL", text: text, groupId: nil, source: source, createdAt: Date()))
    }

    private func weekCount(_ s: LocalDB.Store, _ gid: Int, _ start: Date) -> Int {
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
        return s.liveExpenses(gid).filter { $0.recurringId == nil && $0.createdAt >= start && $0.createdAt < end }.count
    }

    private func weeklyGoal(_ s: inout LocalDB.Store, _ gid: Int) -> Int? {
        let start = LocalLogic.weekStart()
        let key = "\(gid):\(LocalLogic.day(start))"
        guard !s.goalWeeks.contains(key), weekCount(s, gid, start) >= Self.earn["household_goal_target"]! else { return nil }
        s.goalWeeks.append(key)
        return award(&s, Self.earn["household_goal"]!, "HOUSEHOLD_GOAL", "Weekly goal met", gid, nil)
    }

    private func household(_ gid: Int) throws -> [String: Any] {
        let me = meId()
        return try db.read { s in
            let g = try requireGroup(s, gid)
            let start = LocalLogic.weekStart()
            let target = Self.earn["household_goal_target"]!
            let progress = weekCount(s, gid, start)
            let lastStart = Calendar.current.date(byAdding: .day, value: -7, to: start)!
            let last = weekCount(s, gid, lastStart)
            let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: start)!
            let active = Set(s.liveExpenses(gid).filter { $0.createdAt >= start && $0.createdAt < weekEnd }.map(\.paidBy))
            return ["group_id": gid, "week_start": LocalLogic.day(start), "target": target, "progress": progress,
                    "goal_met": progress >= target, "goal_reward": Self.earn["household_goal"]!, "pot_coins": 0, "pot_inr": 0,
                    "weeks_squared": s.goalWeeks.filter { $0.hasPrefix("\(gid):") }.count,
                    "members": g.members.compactMap { s.person($0) }.map {
                        ["user_id": $0.id, "name": $0.name, "confirmed_this_week": active.contains($0.id), "is_you": $0.id == me] },
                    "expected_members": g.expected as Any? ?? NSNull(),
                    "last_week": ["progress": last, "status": last >= target ? "MET" : "MISSED", "target": target],
                    "pot_redemptions": [Any](), "invite_suggested": false]
        }
    }

    private func wallet() -> [String: Any] {
        db.read { s in
            let bal = max(0, s.coins.reduce(0) { $0 + $1.amount })
            let today = s.coins.filter { $0.amount > 0 && Calendar.current.isDateInToday($0.createdAt) }.reduce(0) { $0 + $1.amount }
            let notice: Any = today >= Self.dailyCap ? ["cap_key": "daily", "message": "Daily coin limit reached, back tomorrow"] : NSNull()
            return ["balance": bal, "inr_value": Double(bal) * Self.coinValueInr, "coins_per_inr": 4,
                    "expiring_soon": ["coins": 0, "date": NSNull()], "pending": 0, "deficit": 0, "redemption_frozen": false,
                    "household_pots": [Any](), "cap_notice": notice]
        }
    }

    private func ledger() -> [String: Any] {
        db.read { s in
            ["entries": s.coins.sorted { $0.createdAt > $1.createdAt }.map {
                ["id": $0.id, "amount": $0.amount, "entry_type": $0.amount >= 0 ? "EARN" : "REVERSE", "status": "POSTED",
                 "reason_code": $0.reason, "text": $0.text, "counterparty": NSNull(), "reverses_entry_id": NSNull(),
                 "created_at": LocalLogic.iso($0.createdAt)] },
             "next_cursor": NSNull()]
        }
    }

    private func celebrations() -> [String: Any] {
        db.read { s in
            ["celebrations": s.celebrations.filter { !$0.seen }.map {
                ["id": $0.id, "kind": $0.kind, "coins": $0.coins, "title": $0.title,
                 "bonus_multiplier": $0.multiplier as Any? ?? NSNull(), "bonus_coins": $0.bonus] }]
        }
    }

    private func markSeen(_ id: String) throws {
        try db.write { s in
            if let i = s.celebrations.firstIndex(where: { $0.id == id }) { s.celebrations[i].seen = true }
            if s.celebrations.count > 50 { s.celebrations.removeAll { $0.seen } }
        }
    }

    // MARK: - notes and photos

    private func notes(_ eid: Int) throws -> [String: Any] {
        try db.read { s in
            guard let e = s.expenses.first(where: { $0.id == eid && !$0.deleted }) else { throw LocalError(404, "Expense not found") }
            let me = s.me?.id ?? 0
            return ["comments": e.notes.map { ["id": $0.id, "user_id": me, "name": s.name(me), "is_you": true, "body": $0.body,
                                               "created_at": LocalLogic.iso($0.createdAt)] }]
        }
    }

    private func addNote(_ eid: Int, _ b: [String: Any]) throws -> [String: Any] {
        let text = (b["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalError(400, "Write something first") }
        try db.write { s in
            guard let i = s.expenses.firstIndex(where: { $0.id == eid && !$0.deleted }) else { throw LocalError(404, "Expense not found") }
            s.expenses[i].notes.append(.init(id: UUID().uuidString, body: String(text.prefix(500)), createdAt: Date()))
        }
        return try notes(eid)
    }

    private func deleteNote(_ id: String) throws -> [String: Any] {
        try db.write { s in
            for i in s.expenses.indices { s.expenses[i].notes.removeAll { $0.id == id } }
        }
        return ["ok": true]
    }

    private func attachments(_ eid: Int) -> [[String: Any]] {
        db.read { s in
            s.attachments.filter { $0.expenseId == eid }.map {
                ["id": $0.id, "content_type": $0.contentType, "bytes": $0.bytes, "created_at": LocalLogic.iso($0.createdAt)] }
        }
    }

    private func addAttachment(_ eid: Int, _ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { throw LocalError(400, "Empty file") }
        guard data.count <= 12 * 1024 * 1024 else { throw LocalError(413, "File is larger than 12 MB") }
        let id = UUID().uuidString
        let file = "\(id).jpg"
        try data.write(to: db.photos.appendingPathComponent(file), options: [.atomic, .completeFileProtection])
        try db.write { s in
            guard s.expenses.contains(where: { $0.id == eid && !$0.deleted }) else { throw LocalError(404, "Expense not found") }
            s.attachments.append(.init(id: id, expenseId: eid, file: file, contentType: "image/jpeg", bytes: data.count, createdAt: Date()))
        }
        return ["id": id, "content_type": "image/jpeg", "bytes": data.count]
    }

    private func photo(_ id: String) throws -> Data {
        guard let a = db.read({ $0.attachments.first { $0.id == id } }),
              let d = try? Data(contentsOf: db.photos.appendingPathComponent(a.file)) else { throw LocalError(404, "Not found") }
        return d
    }

    private func deletePhoto(_ id: String) throws -> [String: Any] {
        let file = try db.write { s -> String? in
            let f = s.attachments.first { $0.id == id }?.file
            s.attachments.removeAll { $0.id == id }
            return f
        }
        if let file { try? FileManager.default.removeItem(at: db.photos.appendingPathComponent(file)) }
        return ["ok": true]
    }

    // MARK: - recurring bills

    private func recurringDict(_ s: LocalDB.Store, _ r: LocalDB.Recurring) -> [String: Any] {
        ["id": r.id, "group_id": r.groupId, "description": r.input.description, "amount_minor": r.input.amount,
         "currency": r.input.currency ?? (s.group(r.groupId)?.currency ?? "INR"), "paid_by": r.input.paidBy ?? (s.me?.id ?? 0),
         "paid_by_name": s.name(r.input.paidBy ?? (s.me?.id ?? 0)), "split_type": (r.input.splitType ?? "EQUAL").uppercased(),
         "category": LocalLogic.category(r.input.category, description: r.input.description), "frequency": r.frequency,
         "day": r.day, "next_run": r.nextRun, "last_run": r.lastRun as Any? ?? NSNull(), "active": r.active]
    }

    private func recurringList(_ gid: Int) -> [String: Any] {
        db.read { s in ["recurring": s.recurring.filter { $0.groupId == gid && $0.active }.map { recurringDict(s, $0) }] }
    }

    static func nextDate(_ frequency: String, _ day: Int, after: Date) -> Date {
        let cal = Calendar(identifier: .gregorian)
        if frequency == "WEEKLY" {
            let wd = (cal.component(.weekday, from: after) + 5) % 7      // Monday = 0
            return cal.date(byAdding: .day, value: (day - wd + 7) % 7, to: cal.startOfDay(for: after))!
        }
        var c = cal.dateComponents([.year, .month, .day], from: after)
        if c.day! > day { c.month! += 1 }
        c.day = day
        return cal.date(from: c)!
    }

    private func createRecurring(_ gid: Int, _ b: [String: Any]) throws -> [String: Any] {
        let freq = (b["frequency"] as? String ?? "MONTHLY").uppercased()
        guard ["MONTHLY", "WEEKLY"].contains(freq) else { throw LocalError(400, "Pick monthly or weekly") }
        let day = b["day"] as? Int ?? Calendar.current.component(.day, from: Date())
        guard freq == "WEEKLY" ? (0...6).contains(day) : (1...28).contains(day) else {
            throw LocalError(400, freq == "WEEKLY" ? "Pick a weekday" : "Pick a day from 1 to 28")
        }
        let inp = input(b["expense"] as? [String: Any] ?? [:])
        guard !inp.description.isEmpty, inp.amount > 0 else { throw LocalError(400, "Add a description and amount") }
        let start = (b["start"] as? String).flatMap(LocalLogic.parseDay) ?? Date()
        let r = try db.write { s -> LocalDB.Recurring in
            _ = try requireGroup(s, gid)
            let r = LocalDB.Recurring(id: UUID().uuidString, groupId: gid, input: inp, frequency: freq, day: day,
                                      nextRun: LocalLogic.day(Self.nextDate(freq, day, after: start)))
            s.recurring.append(r)
            return r
        }
        return db.read { recurringDict($0, r) }
    }

    private func patchRecurring(_ id: String, _ b: [String: Any]) throws -> [String: Any] {
        try db.write { s in
            guard let i = s.recurring.firstIndex(where: { $0.id == id }) else { throw LocalError(404, "Not found") }
            if let v = b["active"] as? Bool { s.recurring[i].active = v }
            if let v = b["amount_minor"] as? Int, v > 0 { s.recurring[i].input.amount = v }
            if let v = b["day"] as? Int {
                s.recurring[i].day = v
                s.recurring[i].nextRun = LocalLogic.day(Self.nextDate(s.recurring[i].frequency, v, after: Date()))
            }
        }
        return db.read { s in recurringDict(s, s.recurring.first { $0.id == id }!) }
    }

    /// Add every recurring bill that's due. Runs when the app opens or comes back to the foreground.
    func runDueRecurring() async {
        let today = LocalLogic.day(Date())
        let due = db.read { $0.recurring.filter { $0.active && $0.nextRun <= today && $0.lastRun != today } }
        for r in due {
            var body: [String: Any] = ["description": r.input.description, "amount_paise": r.input.amount,
                                       "split_type": r.input.splitType ?? "EQUAL"]
            if let v = r.input.currency { body["currency"] = v }
            if let v = r.input.paidBy { body["paid_by"] = v }
            if let v = r.input.participants { body["participants"] = v }
            if let v = r.input.exact { body["exact"] = v }
            if let v = r.input.percents { body["percents"] = v }
            if let v = r.input.shares { body["shares"] = v }
            if let v = r.input.category { body["category"] = v }
            let ok = (try? await createExpense(r.groupId, body, recurringId: r.id)) != nil
            try? db.write { s in
                guard let i = s.recurring.firstIndex(where: { $0.id == r.id }) else { return }
                let next = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
                s.recurring[i].nextRun = LocalLogic.day(Self.nextDate(r.frequency, r.day, after: next))
                if ok { s.recurring[i].lastRun = today } else { s.recurring[i].active = false }   // e.g. payer removed
            }
            await LocalNotify.post(title: ok ? "Added \(r.input.description)" : "Couldn't add \(r.input.description)",
                                   body: ok ? "Your recurring bill was added." : "Check the people in that group, then turn it back on.")
        }
    }

    // MARK: - budgets

    private func budgets(_ gid: Int) throws -> [String: Any] {
        try db.read { s in
            let g = try requireGroup(s, gid)
            let (start, end, _, _) = LocalLogic.monthBounds(nil)
            let limits = s.budgets[String(gid)] ?? [:]
            let rows: [[String: Any]] = limits.sorted { $0.key < $1.key }.map { cat, limit in
                let spent = s.liveExpenses(gid).filter { $0.category == cat && $0.createdAt >= start && $0.createdAt < end }.reduce(0) { $0 + $1.amount }
                return ["category": cat, "label": LocalLogic.categoryLabels[cat] ?? cat.capitalized, "limit": limit, "spent": spent,
                        "pct": limit > 0 ? (1000 * Double(spent) / Double(limit)).rounded() / 10 : 0]
            }
            return ["currency": g.currency, "budgets": rows]
        }
    }

    private func setBudgets(_ gid: Int, _ b: [String: Any]) throws -> [String: Any] {
        let incoming = b["budgets"] as? [String: Any] ?? [:]
        try db.write { s in
            _ = try requireGroup(s, gid)
            var cur = s.budgets[String(gid)] ?? [:]
            for (cat, v) in incoming {
                let limit = (v as? Int) ?? (v as? NSNumber)?.intValue ?? 0
                if limit > 0 { cur[cat] = limit } else { cur.removeValue(forKey: cat) }
            }
            s.budgets[String(gid)] = cur
        }
        return try budgets(gid)
    }

    /// A local notification once at 80% and once at 100% of a category budget each month.
    private func budgetCheck(_ gid: Int) {
        guard let rows = (try? budgets(gid))?["budgets"] as? [[String: Any]] else { return }
        let month = LocalLogic.monthBounds(nil).key
        for r in rows {
            guard let pct = r["pct"] as? Double, let cat = r["category"] as? String, let label = r["label"] as? String else { continue }
            for threshold in [100, 80] where pct >= Double(threshold) {
                let key = "\(gid):\(cat):\(month):\(threshold)"
                let fresh = (try? db.write { s -> Bool in
                    guard !s.budgetAlerts.contains(key) else { return false }
                    s.budgetAlerts.append(key); return true
                }) ?? false
                if fresh {
                    Task { await LocalNotify.post(title: "\(label) budget",
                                                  body: threshold == 100 ? "\(label) went over budget this month." : "\(label) is at \(Int(pct))% of this month's budget.") }
                }
                break
            }
        }
    }

    // MARK: - search, activity

    private func search(_ gid: Int, _ q: [String: String]) throws -> [String: Any] {
        try db.read { s in
            let g = try requireGroup(s, gid)
            var list = s.liveExpenses(gid)
            if let t = q["q"]?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty {
                list = list.filter { $0.description.lowercased().contains(t) || $0.notes.contains { $0.body.lowercased().contains(t) } }
            }
            if let c = q["category"], !c.isEmpty { list = list.filter { $0.category == c } }
            if let m = q["member"].flatMap(Int.init) { list = list.filter { $0.paidBy == m || $0.splits.contains { $0.person == m } } }
            if let mo = q["month"], !mo.isEmpty {
                let (st, en, _, _) = LocalLogic.monthBounds(mo)
                list = list.filter { $0.createdAt >= st && $0.createdAt < en }
            }
            if let v = q["min_amount"].flatMap(Int.init) { list = list.filter { $0.amount >= v } }
            if let v = q["max_amount"].flatMap(Int.init) { list = list.filter { $0.amount <= v } }
            list.sort { $0.createdAt > $1.createdAt }
            return ["total": list.reduce(0) { $0 + $1.amount }, "currency": g.currency, "expenses": list.prefix(200).map { expenseDict(s, $0) }]
        }
    }

    private func activity() -> [String: Any] {
        db.read { s in
            let me = s.me?.id ?? 0
            let since = Date().addingTimeInterval(-90 * 86400)
            var items: [(Date, [String: Any])] = []
            for e in s.expenses where e.createdAt >= since {
                guard let g = s.groups.first(where: { $0.id == e.groupId && !$0.archived }) else { continue }
                items.append((e.createdAt, ["kind": e.deleted ? "EXPENSE_DELETED" : "EXPENSE", "at": LocalLogic.iso(e.createdAt),
                    "actor_id": me, "actor_name": s.name(me), "is_you": true, "group_id": g.id, "group_name": displayName(s, g),
                    "currency": g.currency, "expense_id": e.id, "title": e.description, "amount": e.amount,
                    "my_share": e.splits.first { $0.person == me }?.share ?? 0, "paid_by": e.paidBy, "recurring": e.recurringId != nil]))
            }
            for p in s.payments where !p.deleted && p.createdAt >= since {
                guard let g = s.groups.first(where: { $0.id == p.groupId && !$0.archived }) else { continue }
                items.append((p.createdAt, ["kind": "PAYMENT", "at": LocalLogic.iso(p.createdAt), "actor_id": p.payer,
                    "actor_name": s.name(p.payer), "is_you": p.payer == me, "group_id": g.id, "group_name": displayName(s, g),
                    "currency": g.currency, "amount": p.amount, "receiver_id": p.receiver, "receiver_name": s.name(p.receiver)]))
            }
            return ["items": items.sorted { $0.0 > $1.0 }.prefix(150).map(\.1)]
        }
    }

    // MARK: - insights and reports

    private func groupInsights(_ gid: Int, _ month: String?) throws -> [String: Any] {
        try db.read { s in try insightsDict(s, try requireGroup(s, gid), month) }
    }

    private func insightsDict(_ s: LocalDB.Store, _ g: LocalDB.Group, _ month: String?) throws -> [String: Any] {
        let me = s.me?.id ?? 0
        let (start, end, key, label) = LocalLogic.monthBounds(month)
        let exps = s.liveExpenses(g.id).filter { $0.createdAt >= start && $0.createdAt < end }.sorted { $0.createdAt < $1.createdAt }
        var ids = g.members
        for e in exps { for u in [e.paidBy] + e.splits.map(\.person) where !ids.contains(u) { ids.append(u) } }
        var paid: [Int: Int] = [:], share: [Int: Int] = [:], count: [Int: Int] = [:], cats: [String: Int] = [:], settled: [Int: Int] = [:]
        var total = 0
        for e in exps {
            total += e.amount; paid[e.paidBy, default: 0] += e.amount; count[e.paidBy, default: 0] += 1
            for sp in e.splits { share[sp.person, default: 0] += sp.share }
            cats[e.category, default: 0] += e.amount
        }
        for p in s.livePayments(g.id) where p.createdAt >= start && p.createdAt < end { settled[p.payer, default: 0] += p.amount }
        var trend: [[String: Any]] = []
        let cal = Calendar.current
        for back in (0..<6).reversed() {
            let ms = cal.date(byAdding: .month, value: -back, to: start)!, me2 = cal.date(byAdding: .month, value: 1, to: ms)!
            let es = s.liveExpenses(g.id).filter { $0.createdAt >= ms && $0.createdAt < me2 }
            let f = DateFormatter(); f.dateFormat = "yyyy-MM"
            let l = DateFormatter(); l.dateFormat = "MMM"
            trend.append(["month": f.string(from: ms), "label": l.string(from: ms), "total": es.reduce(0) { $0 + $1.amount },
                          "my_share": es.reduce(0) { $0 + ($1.splits.first { $0.person == me }?.share ?? 0) }])
        }
        let isCurrent = cal.isDate(start, equalTo: Date(), toGranularity: .month)
        let days = isCurrent ? cal.component(.day, from: Date()) : cal.range(of: .day, in: .month, for: start)!.count
        let members: [[String: Any]] = ids.map { u in
            ["user_id": u, "name": s.name(u), "is_you": u == me, "paid": paid[u] ?? 0, "share": share[u] ?? 0,
             "net": (paid[u] ?? 0) - (share[u] ?? 0), "settled": settled[u] ?? 0, "expenses_added": count[u] ?? 0,
             "share_pct": total > 0 ? (1000 * Double(share[u] ?? 0) / Double(total)).rounded() / 10 : 0]
        }
        return ["group_id": g.id, "group_name": displayName(s, g), "currency": g.currency, "month": key, "month_label": label,
                "total_spend": total, "expense_count": exps.count, "daily_average": total > 0 ? total / max(days, 1) : 0,
                "members": members,
                "categories": cats.sorted { $0.value > $1.value }.map { ["category": $0.key, "label": LocalLogic.categoryLabels[$0.key] ?? $0.key.capitalized,
                                                                        "amount": $0.value, "pct": total > 0 ? (1000 * Double($0.value) / Double(total)).rounded() / 10 : 0] },
                "trend": trend,
                "top_expenses": exps.sorted { $0.amount > $1.amount }.prefix(5).map {
                    ["id": $0.id, "description": $0.description, "amount": $0.amount, "category": $0.category,
                     "paid_by_name": s.name($0.paidBy), "created_at": LocalLogic.iso($0.createdAt)] },
                "you": members.first { $0["is_you"] as? Bool == true } ?? NSNull()]
    }

    private func myInsights(_ month: String?, _ currency: String) async throws -> [String: Any] {
        let cur = currency.uppercased()
        let groups = db.read { $0.groups.filter { !$0.archived } }
        var rate: [String: Double] = [cur: 1]
        for c in Set(groups.map(\.currency)) where c != cur {
            rate[c] = try await LocalLogic.rates(base: c).rates[cur] ?? 0
        }
        return db.read { s in
            let me = s.me?.id ?? 0
            let (start, end, key, label) = LocalLogic.monthBounds(month)
            var byGroup: [[String: Any]] = [], byCat: [String: Int] = [:]
            var total = 0, paidTotal = 0
            let cal = Calendar.current
            var trend: [(String, String, Date, Int)] = (0..<6).reversed().map { back in
                let ms = cal.date(byAdding: .month, value: -back, to: start)!
                let f = DateFormatter(); f.dateFormat = "yyyy-MM"; let l = DateFormatter(); l.dateFormat = "MMM"
                return (f.string(from: ms), l.string(from: ms), ms, 0)
            }
            for g in groups {
                let r = rate[g.currency] ?? 0
                func conv(_ v: Int) -> Int { LocalLogic.convert(v, from: g.currency, to: cur, rate: r) }
                let es = s.liveExpenses(g.id).filter { $0.createdAt >= start && $0.createdAt < end }
                let mine = es.compactMap { e in e.splits.first { $0.person == me }.map { (e, $0.share) } }
                let gShare = mine.reduce(0) { $0 + $1.1 }
                let gPaid = es.filter { $0.paidBy == me }.reduce(0) { $0 + $1.amount }
                total += conv(gShare); paidTotal += conv(gPaid)
                for (e, sh) in mine { byCat[e.category, default: 0] += conv(sh) }
                if gShare > 0 || gPaid > 0 {
                    byGroup.append(["group_id": g.id, "group_name": displayName(s, g), "group_currency": g.currency,
                                    "share": conv(gShare), "share_in_group_currency": gShare, "paid": conv(gPaid)])
                }
                for i in trend.indices {
                    let ms = trend[i].2, me2 = cal.date(byAdding: .month, value: 1, to: ms)!
                    let v = s.liveExpenses(g.id).filter { $0.createdAt >= ms && $0.createdAt < me2 }
                        .reduce(0) { $0 + ($1.splits.first { $0.person == me }?.share ?? 0) }
                    trend[i].3 += conv(v)
                }
            }
            return ["currency": cur, "month": key, "month_label": label, "total_share": total, "total_paid": paidTotal,
                    "by_group": byGroup.sorted { ($0["share"] as? Int ?? 0) > ($1["share"] as? Int ?? 0) },
                    "categories": byCat.sorted { $0.value > $1.value }.map { ["category": $0.key, "label": LocalLogic.categoryLabels[$0.key] ?? $0.key.capitalized,
                                                                              "amount": $0.value, "pct": total > 0 ? (1000 * Double($0.value) / Double(total)).rounded() / 10 : 0] },
                    "trend": trend.map { ["month": $0.0, "label": $0.1, "my_share": $0.3] }]
        }
    }

    private func report(_ gid: Int, _ month: String?, _ format: String) throws -> Data {
        try db.read { s in
            let g = try requireGroup(s, gid)
            let ins = try insightsDict(s, g, month)
            let (start, end, _, label) = LocalLogic.monthBounds(month)
            let exps = s.liveExpenses(gid).filter { $0.createdAt >= start && $0.createdAt < end }.sorted { $0.createdAt < $1.createdAt }
            let pays = s.livePayments(gid).filter { $0.createdAt >= start && $0.createdAt < end }.sorted { $0.createdAt < $1.createdAt }
            let members = (ins["members"] as? [[String: Any]] ?? []).compactMap { $0["user_id"] as? Int }
            let cur = g.currency, name = displayName(s, g)
            let d = DateFormatter(); d.dateFormat = "yyyy-MM-dd"
            func major(_ v: Int) -> String { String(format: "%.\(LocalLogic.digits(cur))f", Double(v) / pow(10, Double(LocalLogic.digits(cur)))) }
            let owed = LocalLogic.debts(s, g).map { "\(s.name($0.key.debtor)) owes \(s.name($0.key.creditor)) \(LocalLogic.money($0.value, cur))" }
            if format == "pdf" {
                return ReportPDF.render(title: "\(name) statement · \(label)",
                    subtitle: "Total spent \(LocalLogic.money(ins["total_spend"] as? Int ?? 0, cur)) across \(exps.count) expenses. Amounts in \(cur).",
                    header: ["Date", "Description", "Paid by", "Amount"] + members.map { s.name($0) },
                    rows: exps.map { e in
                        [d.string(from: e.createdAt), e.description, s.name(e.paidBy), LocalLogic.money(e.amount, cur)]
                        + members.map { u in e.splits.first { $0.person == u }.map { LocalLogic.money($0.share, cur) } ?? "" } },
                    payments: pays.map { "\(d.string(from: $0.createdAt))  \(s.name($0.payer)) paid \(s.name($0.receiver)) \(LocalLogic.money($0.amount, cur))" },
                    owed: owed.isEmpty ? ["Everyone is square."] : owed)
            }
            func row(_ cells: [String]) -> String {
                cells.map { c in c.contains(",") || c.contains("\"") ? "\"\(c.replacingOccurrences(of: "\"", with: "\"\""))\"" : c }.joined(separator: ",")
            }
            var lines = [row(["\(name) statement", label, "Amounts in \(cur)"]), "",
                         row(["Date", "Description", "Category", "Paid by", "Amount (\(cur))", "Original amount", "Split"] + members.map { "\(s.name($0)) share" })]
            for e in exps {
                let orig = e.originalCurrency.map { "\($0) \(String(format: "%.2f", Double(e.originalAmount ?? 0) / 100)) @ \(String(format: "%.4f", e.fxRate ?? 0))" } ?? ""
                lines.append(row([d.string(from: e.createdAt), e.description, LocalLogic.categoryLabels[e.category] ?? e.category, s.name(e.paidBy),
                                  major(e.amount), orig, e.splitType.capitalized] + members.map { u in major(e.splits.first { $0.person == u }?.share ?? 0) }))
            }
            lines += ["", "Payments", row(["Date", "From", "To", "Amount (\(cur))"])]
            for p in pays { lines.append(row([d.string(from: p.createdAt), s.name(p.payer), s.name(p.receiver), major(p.amount)])) }
            lines += ["", row(["Summary", "Paid", "Share", "Net for the month", "Share %"])]
            for m in ins["members"] as? [[String: Any]] ?? [] {
                lines.append(row([m["name"] as? String ?? "", major(m["paid"] as? Int ?? 0), major(m["share"] as? Int ?? 0),
                                  major(m["net"] as? Int ?? 0), "\(m["share_pct"] ?? 0)%"]))
            }
            lines += [row(["Total", major(ins["total_spend"] as? Int ?? 0)]), "", "Outstanding balances today"] + owed
            return Data(lines.joined(separator: "\n").utf8)
        }
    }

    // MARK: - currency

    private func currencies() -> [String: Any] {
        ["currencies": LocalLogic.currencies.map { ["code": $0, "name": LocalLogic.currencyNames[$0] ?? $0,
                                                     "symbol": LocalLogic.symbols[$0] as Any? ?? NSNull(), "digits": LocalLogic.digits($0)] }]
    }

    private func rates(_ base: String) async throws -> [String: Any] {
        let fx = try await LocalLogic.rates(base: base)
        return ["base": base.uppercased(), "rates": fx.rates, "as_of": fx.asOf as Any? ?? NSNull(), "source": "open.er-api.com",
                "stale": Date().timeIntervalSince(fx.fetchedAt) > 3600]
    }
}
