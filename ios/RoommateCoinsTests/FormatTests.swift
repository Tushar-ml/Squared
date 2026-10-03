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
