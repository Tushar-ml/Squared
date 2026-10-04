import XCTest
@testable import Squared

/// Two phones, two databases: Tushar's (A) and Shivam's (B).
final class SyncEngineTests: XCTestCase {
    private var folders: [URL] = []
    private var dbA: LocalDB!, dbB: LocalDB!
    private var A: LocalAPI!, B: LocalAPI!

    override func setUp() {
        folders = [UUID(), UUID()].map { FileManager.default.temporaryDirectory.appendingPathComponent($0.uuidString) }
        dbA = LocalDB(folder: folders[0]); dbB = LocalDB(folder: folders[1])
        A = LocalAPI(db: dbA); B = LocalAPI(db: dbB)
    }

    override func tearDown() { folders.forEach { try? FileManager.default.removeItem(at: $0) } }

    @discardableResult
    private func call(_ api: LocalAPI, _ m: String, _ p: String, _ b: [String: Any]? = nil) async throws -> [String: Any] {
        let d = try await api.handle(m, p, body: b)
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    /// Send group `gid` from one phone to the other; returns the receiver's local group id.
    @discardableResult
    private func send(_ from: LocalDB, _ gid: Int, to: LocalDB, claim: String? = nil) throws -> (Int, SyncEngine.Result) {
        let bundle = try XCTUnwrap(from.read { SyncEngine.bundle($0, groupId: gid) })
        let data = try JSONEncoder().encode(bundle)                  // what actually goes over the air
        let decoded = try JSONDecoder().decode(SyncEngine.Bundle.self, from: data)
        let r = try to.write { try SyncEngine.merge(&$0, decoded, claim: claim) }
        let local = to.read { s in s.groups.first { $0.uid == bundle.group.uid }!.id }
        return (local, r)
    }

    private func net(_ api: LocalAPI, _ gid: Int) async throws -> Int { try await call(api, "GET", "/groups/\(gid)")["my_net_paise"] as! Int }

    private func shared() async throws -> (a: Int, b: Int, shivamUid: String) {
        try await call(A, "PATCH", "/me", ["name": "Tushar"])
        try await call(B, "PATCH", "/me", ["name": "Shivam"])
        let ga = try await call(A, "POST", "/groups", ["name": "College friends", "group_type": "FRIENDS"])["id"] as! Int
        let shivam = try await call(A, "POST", "/groups/\(ga)/members", ["name": "Shivam"])["id"] as! Int
        try await call(A, "POST", "/groups/\(ga)/expenses", ["description": "Gift", "amount_paise": 265_600])
        let uid = dbA.read { $0.person(shivam)!.uid! }
        let (gb, r) = try send(dbA, ga, to: dbB, claim: uid)
        XCTAssertEqual(r.newExpenses, 1)
        return (ga, gb, uid)
    }

    func testJoiningMapsTheClaimedMemberToYou() async throws {
        let g = try await shared()
        let detail = try await call(B, "GET", "/groups/\(g.b)")
        let members = detail["members"] as! [[String: Any]]
        XCTAssertEqual(members.first { $0["is_you"] as? Bool == true }?["name"] as? String, "Shivam")
        XCTAssertTrue(members.contains { $0["name"] as? String == "Tushar" })
        let netA = try await net(A, g.a), netB = try await net(B, g.b)
        XCTAssertEqual(netA, 132_800)
        XCTAssertEqual(netB, -132_800)                                  // Shivam owes Tushar, on Shivam's phone
        let coins = try await call(B, "GET", "/coins/wallet")["balance"] as! Int
        XCTAssertEqual(coins, 0)                                        // synced expenses don't earn
    }

    func testChangesFlowBothWaysAndBalancesAgree() async throws {
        let g = try await shared()
        let tusharOnB = dbB.read { s in s.groups.first { $0.id == g.b }!.members.first { $0 != s.me!.id }! }
        try await call(B, "POST", "/groups/\(g.b)/expenses", ["description": "Pizza", "amount_paise": 80_000])
        try await call(B, "POST", "/groups/\(g.b)/payments", ["receiver_id": tusharOnB, "amount_paise": 50_000])
        try send(dbB, g.b, to: dbA)
        let netA = try await net(A, g.a), netB = try await net(B, g.b)
        XCTAssertEqual(netA, 132_800 - 40_000 - 50_000)
        XCTAssertEqual(netA, -netB)
        let expensesOnA = try await call(A, "GET", "/groups/\(g.a)")["expenses"] as! [[String: Any]]
        XCTAssertEqual(Set(expensesOnA.map { $0["description"] as! String }), ["Gift", "Pizza"])
        XCTAssertEqual(expensesOnA.first { $0["description"] as? String == "Pizza" }?["paid_by_name"] as? String, "Shivam")
    }

    func testConflictingEditsConvergeWhicheverWaySyncRuns() async throws {
        let g = try await shared()
        let eA = try await call(A, "GET", "/groups/\(g.a)")["expenses"] as! [[String: Any]]
        let eB = try await call(B, "GET", "/groups/\(g.b)")["expenses"] as! [[String: Any]]
        try await call(A, "PATCH", "/expenses/\(eA[0]["id"] as! Int)", ["amount_paise": 300_000])
        try await Task.sleep(for: .milliseconds(20))
        try await call(B, "PATCH", "/expenses/\(eB[0]["id"] as! Int)", ["description": "Birthday gift"])
        try send(dbA, g.a, to: dbB)
        try send(dbB, g.b, to: dbA)
        let a = try await call(A, "GET", "/groups/\(g.a)")["expenses"] as! [[String: Any]]
        let b = try await call(B, "GET", "/groups/\(g.b)")["expenses"] as! [[String: Any]]
        XCTAssertEqual(a[0]["description"] as? String, "Birthday gift")  // the later edit wins on both phones
        XCTAssertEqual(a[0]["amount_paise"] as? Int, b[0]["amount_paise"] as? Int)
        XCTAssertEqual(a[0]["description"] as? String, b[0]["description"] as? String)
    }

    func testDeletesSpreadAndMergingTwiceChangesNothing() async throws {
        let g = try await shared()
        let eA = try await call(A, "GET", "/groups/\(g.a)")["expenses"] as! [[String: Any]]
        try await call(A, "DELETE", "/expenses/\(eA[0]["id"] as! Int)")
        try send(dbA, g.a, to: dbB)
        let (_, again) = try send(dbA, g.a, to: dbB)
        XCTAssertEqual(again, SyncEngine.Result())
        let left = try await call(B, "GET", "/groups/\(g.b)")["expenses"] as! [[String: Any]]
        XCTAssertTrue(left.isEmpty)
        let netB = try await net(B, g.b)
        XCTAssertEqual(netB, 0)
    }

    func testPeopleAddedOnEitherPhoneEndUpOnBoth() async throws {
        let g = try await shared()
        try await call(A, "POST", "/groups/\(g.a)/members", ["name": "Riya"])
        try await call(B, "POST", "/groups/\(g.b)/members", ["name": "Kabir"])
        try send(dbA, g.a, to: dbB)
        try send(dbB, g.b, to: dbA)
        for (api, gid) in [(A!, g.a), (B!, g.b)] {
            let names = Set((try await call(api, "GET", "/groups/\(gid)")["members"] as! [[String: Any]]).map { $0["name"] as! String })
            XCTAssertEqual(names, ["Tushar", "Shivam", "Riya", "Kabir"])
        }
    }

    func testAnUnknownGroupNeedsYouToPickYourself() async throws {
        try await call(A, "PATCH", "/me", ["name": "Tushar"])
        try await call(B, "PATCH", "/me", ["name": "Shivam"])
        let ga = try await call(A, "POST", "/groups", ["name": "Trip", "group_type": "TRIP"])["id"] as! Int
        let bundle = try XCTUnwrap(dbA.read { SyncEngine.bundle($0, groupId: ga) })
        XCTAssertFalse(dbB.read { SyncEngine.knows($0, bundle) })
        XCTAssertThrowsError(try dbB.write { try SyncEngine.merge(&$0, bundle) })
    }
}
