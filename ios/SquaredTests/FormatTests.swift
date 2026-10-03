import XCTest
@testable import Squared

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

final class SplitMathTests: XCTestCase {
    func testAllocateMatchesServerRounding() {
        XCTAssertEqual(SplitMath.allocate(10000, [1, 1, 1]), [3334, 3333, 3333])
        XCTAssertEqual(SplitMath.allocate(120000, [2, 1, 1]), [60000, 30000, 30000])
        for total in [1, 7, 99, 100, 101, 123457] {
            XCTAssertEqual(SplitMath.allocate(total, [33.33, 33.33, 33.34]).reduce(0, +), total)
        }
    }

    func testModes() {
        let people = [1, 2, 3]
        let eq = SplitMath.compute(total: 79900, mode: .equal, people: people, included: [2, 3], values: [:])
        XCTAssertEqual(eq.shares, [2: 39950, 3: 39950])
        let ex = SplitMath.compute(total: 1000, mode: .exact, people: people, included: [], values: [1: 600, 2: 300])
        XCTAssertEqual(ex.remaining, 100)
        XCTAssertNotNil(ex.error)
        let pc = SplitMath.compute(total: 100000, mode: .percent, people: people, included: [], values: [1: 50, 2: 30, 3: 20])
        XCTAssertNil(pc.error)
        XCTAssertEqual(pc.shares[1], 50000)
        let bad = SplitMath.compute(total: 1000, mode: .percent, people: people, included: [], values: [1: 60, 2: 30])
        XCTAssertEqual(bad.error, "Percentages add up to 90%")
    }

    func testMoneyFormatting() {
        XCTAssertEqual(Format.money(96320, "INR"), "INR 963.20")
        XCTAssertEqual(Format.money(1505, "JPY"), "JPY 1,505")
        XCTAssertEqual(Format.money(250000, "USD"), "USD 2,500")
        XCTAssertEqual(Format.minor(from: "10.01", currency: "USD"), 1001)
        XCTAssertEqual(Format.minor(from: "1000", currency: "JPY"), 1000)
    }
}

final class ReceiptParseTests: XCTestCase {
    func testPrefersTotalLine() {
        let r = ReceiptScanner.parse(["FRESH MART", "Milk 2 x 30.00   60.00", "Bread 45.00", "Subtotal 105.00", "GST 5.25", "Grand Total ₹110.25"])
        XCTAssertEqual(r.amount, "110.25")
        XCTAssertEqual(r.merchant, "FRESH MART")
    }

    func testFallsBackToLargestNumberAndIndianGrouping() {
        let r = ReceiptScanner.parse(["Airtel Xstream", "Plan 799", "Paid Rs. 1,178.82"])
        XCTAssertEqual(r.amount, "1178.82")
    }
}
