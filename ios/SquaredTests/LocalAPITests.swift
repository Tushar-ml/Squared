import XCTest
@testable import Squared

/// The on-device engine: every test gets its own throwaway database folder.
final class LocalAPITests: XCTestCase {
    private var folder: URL!
    private var db: LocalDB!
    private var api: LocalAPI!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        db = LocalDB(folder: folder)
        api = LocalAPI(db: db)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    @discardableResult
    private func call(_ m: String, _ p: String, _ b: [String: Any]? = nil) async throws -> [String: Any] {
        let d = try await api.handle(m, p, body: b)
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    /// You, Priya and Ravi in one home group.
    private func flat() async throws -> (gid: Int, me: Int, priya: Int, ravi: Int) {
        try await call("PATCH", "/me", ["name": "Tushar"])
        let me = try await call("GET", "/me")["id"] as! Int
        let gid = try await call("POST", "/groups", ["name": "Flat 4B", "group_type": "HOME"])["id"] as! Int
        let priya = try await call("POST", "/groups/\(gid)/members", ["name": "Priya", "upi_id": "priya@upi"])["id"] as! Int
        let ravi = try await call("POST", "/groups/\(gid)/members", ["name": "Ravi"])["id"] as! Int
        return (gid, me, priya, ravi)
    }

    private func net(_ gid: Int) async throws -> Int { try await call("GET", "/groups/\(gid)")["my_net_paise"] as! Int }

    func testEqualSplitGivesTheOddPaisaToTheFirstPersonAndSetsBalances() async throws {
        let f = try await flat()
        let e = try await call("POST", "/groups/\(f.gid)/expenses", ["description": "Groceries", "amount_paise": 1000])
        let shares = (e["splits"] as! [[String: Any]]).map { $0["share_paise"] as! Int }
        XCTAssertEqual(shares, [334, 333, 333])
        XCTAssertEqual(e["category"] as? String, "groceries")                 // guessed from the description
        let net = try await net(f.gid)
        XCTAssertEqual(net, 666)                                              // you paid 10.00, your share 3.34
    }

    func testPercentAndSharesAndExactSplits() async throws {
        let f = try await flat()
        let pct = try await call("POST", "/groups/\(f.gid)/expenses", ["description": "Rent", "amount_paise": 3_000_000,
            "split_type": "PERCENT", "percents": ["\(f.me)": 50, "\(f.priya)": 30, "\(f.ravi)": 20]])
        XCTAssertEqual((pct["splits"] as! [[String: Any]]).map { $0["share_paise"] as! Int }, [1_500_000, 900_000, 600_000])
        let sh = try await call("POST", "/groups/\(f.gid)/expenses", ["description": "Cab", "amount_paise": 900,
            "split_type": "SHARES", "shares": ["\(f.me)": 2, "\(f.priya)": 1]])
        XCTAssertEqual((sh["splits"] as! [[String: Any]]).map { $0["share_paise"] as! Int }, [600, 300])
        do {
            try await call("POST", "/groups/\(f.gid)/expenses", ["description": "Bad", "amount_paise": 1000,
                "split_type": "EXACT", "exact": ["\(f.me)": 500, "\(f.priya)": 400]])
            XCTFail("exact amounts that don't add up must fail")
        } catch let e as LocalError { XCTAssertTrue(e.message.contains("short")) }
    }

    func testPaymentsSettleAndSimplifyFindsFewerTransfers() async throws {
        let f = try await flat()
        // Priya paid 900 for all three; Ravi paid 300 for all three
        try await call("POST", "/groups/\(f.gid)/expenses", ["description": "Dinner", "amount_paise": 900, "paid_by": f.priya])
        try await call("POST", "/groups/\(f.gid)/expenses", ["description": "Chai", "amount_paise": 300, "paid_by": f.ravi])
        var debts = try await call("GET", "/groups/\(f.gid)")["debts"] as! [[String: Any]]
        XCTAssertEqual(debts.filter { $0["you_owe"] as? Bool == true }.count, 2)  // you owe Priya and Ravi
        try await call("PATCH", "/groups/\(f.gid)", ["simplify_debts": true])
        debts = try await call("GET", "/groups/\(f.gid)")["debts"] as! [[String: Any]]
        let mine = debts.filter { $0["you_owe"] as? Bool == true }
        XCTAssertEqual(mine.count, 1)                                         // one transfer to Priya instead of two
        XCTAssertEqual(mine.first?["creditor_upi"] as? String, "priya@upi")
        let owed = mine.first!["amount_paise"] as! Int
        let before = try await net(f.gid)
        try await call("POST", "/groups/\(f.gid)/payments", ["receiver_id": f.priya, "amount_paise": owed])
        let after = try await net(f.gid)
        XCTAssertEqual(before, -400)
        XCTAssertEqual(after, 0)
    }

    func testCoinsFirstWinThenPerExpenseWithinTheDailyCapAndDeletingTakesThemBack() async throws {
        let f = try await flat()
        let first = try await call("POST", "/groups/\(f.gid)/expenses", ["description": "Milk", "amount_paise": 600])
        XCTAssertEqual((first["success_hint"] as? [String: Any])?["adder_coins"] as? Int, 50)
        var balance = try await call("GET", "/coins/wallet")["balance"] as! Int
        XCTAssertEqual(balance, 50)
        let second = try await call("POST", "/groups/\(f.gid)/expenses", ["description": "Bread", "amount_paise": 300])
        XCTAssertEqual((second["success_hint"] as? [String: Any])?["adder_coins"] as? Int, 5)
        for i in 0..<5 { try await call("POST", "/groups/\(f.gid)/expenses", ["description": "Item \(i)", "amount_paise": 300]) }
        balance = try await call("GET", "/coins/wallet")["balance"] as! Int
        XCTAssertEqual(balance, LocalAPI.dailyCap)                            // 50 + 5 + weekly goal, capped at 60 a day
        try await call("DELETE", "/expenses/\(second["id"] as! Int)")
        balance = try await call("GET", "/coins/wallet")["balance"] as! Int
        XCTAssertEqual(balance, LocalAPI.dailyCap - 5)
        let celebrations = try await call("GET", "/coins/celebrations")["celebrations"] as! [[String: Any]]
        XCTAssertEqual(celebrations.first?["kind"] as? String, "FIRST_WIN")
    }

    func testPeopleWithOpenBalancesCantBeRemovedAndGroupsDeleteOnlyWhenSquare() async throws {
        let f = try await flat()
        try await call("POST", "/groups/\(f.gid)/expenses", ["description": "Wifi", "amount_paise": 900])
        do { try await call("DELETE", "/groups/\(f.gid)/members/\(f.priya)"); XCTFail() } catch let e as LocalError { XCTAssertEqual(e.status, 409) }
        do { try await call("DELETE", "/groups/\(f.gid)/members/\(f.me)"); XCTFail() } catch let e as LocalError { XCTAssertEqual(e.status, 409) }
        try await call("POST", "/groups/\(f.gid)/payments", ["receiver_id": f.me, "payer_id": f.priya, "amount_paise": 300])
        try await call("POST", "/groups/\(f.gid)/payments", ["receiver_id": f.me, "payer_id": f.ravi, "amount_paise": 300])
        try await call("DELETE", "/groups/\(f.gid)/members/\(f.me)")         // square now: the group can go
        let groups = try await call("GET", "/groups")["groups"] as! [[String: Any]]
        XCTAssertTrue(groups.isEmpty)
    }

    func testFriendsAreTwoPersonGroupsNamedAfterThem() async throws {
        _ = try await flat()
        let fr = try await call("POST", "/friends", ["name": "Asha"])
        let again = try await call("POST", "/friends", ["name": "asha"])
        XCTAssertEqual(fr["group_id"] as? Int, again["group_id"] as? Int)
        let detail = try await call("GET", "/groups/\(fr["group_id"] as! Int)")
        XCTAssertEqual(detail["name"] as? String, "Asha")
        let groups = try await call("GET", "/groups")["groups"] as! [[String: Any]]
        XCTAssertFalse(groups.contains { $0["id"] as? Int == fr["group_id"] as? Int })   // not listed with groups
    }

    func testBackupRoundTripAndErase() async throws {
        let f = try await flat()
        try await call("POST", "/groups/\(f.gid)/expenses", ["description": "Gas cylinder", "amount_paise": 1100])
        let backup = try db.exportData()
        try db.eraseEverything()
        let empty = try await call("GET", "/groups")["groups"] as! [[String: Any]]
        XCTAssertTrue(empty.isEmpty)
        try db.importData(backup)
        let detail = try await call("GET", "/groups/\(f.gid)")
        XCTAssertEqual((detail["expenses"] as! [[String: Any]]).first?["description"] as? String, "Gas cylinder")
    }

    func testCsvStatementListsExpensesAndBalances() async throws {
        let f = try await flat()
        try await call("POST", "/groups/\(f.gid)/expenses", ["description": "Electricity, October", "amount_paise": 1500])
        let csv = String(decoding: try await api.handle("GET", "/groups/\(f.gid)/report?format=csv", body: nil), as: UTF8.self)
        XCTAssertTrue(csv.contains("\"Electricity, October\""))              // commas are quoted
        XCTAssertTrue(csv.contains("Priya owes Tushar"))
        let pdf = try await api.handle("GET", "/groups/\(f.gid)/report?format=pdf", body: nil)
        XCTAssertEqual(String(decoding: pdf.prefix(4), as: UTF8.self), "%PDF")
    }
}
