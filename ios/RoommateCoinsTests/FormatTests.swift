import XCTest
@testable import RoommateCoins

final class FormatTests: XCTestCase {
    func testINRUsesIndianGrouping() {
        XCTAssertEqual(Format.inr(paise: 79900), "INR 799")
        XCTAssertEqual(Format.inr(paise: 10_000_000), "INR 1,00,000")
        XCTAssertEqual(Format.inr(paise: 26650), "INR 266.50")
    }

    func testParsePaise() {
        XCTAssertEqual(Format.paise(from: "799"), 79900)
        XCTAssertEqual(Format.paise(from: "1,200.5"), 120050)
        XCTAssertNil(Format.paise(from: "0"))
        XCTAssertNil(Format.paise(from: "abc"))
    }

    func testNamesJoin() {
        XCTAssertEqual(Format.names(["Priya"]), "Priya")
        XCTAssertEqual(Format.names(["Priya", "Aman"]), "Priya or Aman")
        XCTAssertEqual(Format.names(["A", "B", "C"]), "A, B or C")
    }

    func testCoinValueText() {
        XCTAssertEqual(Format.coinsInr(340, coinValue: 0.25), "about INR 85")
    }

    func testDecodesWalletWithSnakeCase() throws {
        let json = """
        {"balance":340,"inr_value":85.0,"coins_per_inr":4,"expiring_soon":{"coins":40,"date":"2026-11-12T00:00:00+00:00"},
         "pending":0,"deficit":0,"redemption_frozen":false,"household_pots":[{"group_id":1,"group_name":"Flat 4B","coins":560}],
         "cap_notice":null,"config_version":3}
        """.data(using: .utf8)!
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let w = try d.decode(Wallet.self, from: json)
        XCTAssertEqual(w.balance, 340)
        XCTAssertEqual(w.householdPots.first?.coins, 560)
        XCTAssertEqual(w.expiringSoon.coins, 40)
    }
}

final class ConfigDecodeTests: XCTestCase {
    func testDecodesClientConfig() throws {
        let json = """
        {"version":3,"enabled":true,"kill_switch":false,"coin_value_inr":0.25,"coins_per_inr":4,
         "surprise":{"p_any":0.2,"p_3x":0.05,"p_2x":0.15},
         "earn":{"first_win":50,"expense_adder":5,"expense_confirmer":2,"settle_payer":20,"settle_quick_bonus":10,
                 "settle_receiver":10,"invite_each":50,"household_goal":120,"household_goal_target":5,"quick_window_hours":48}}
        """.data(using: .utf8)!
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let c = try d.decode(CoinConfig.self, from: json)
        XCTAssertEqual(c.surprise.p3x, 0.05)
        XCTAssertEqual(c.earn.householdGoal, 120)
    }
}
