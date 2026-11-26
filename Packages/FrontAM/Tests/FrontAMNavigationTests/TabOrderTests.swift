import FrontAMNavigation
import XCTest

final class TabOrderTests: XCTestCase {
    private let order = FrontAMTabOrder(fixed: ["search"], reorderable: ["home", "library"],
                                        fallback: "home", maxVisible: 2, decode: { $0 }, encode: { $0 })

    func testOrdersKnownTabsAndKeepsSearchFixed() {
        XCTAssertEqual(order.displayed(order: "unknown,search,library,library", hidden: nil),
                       ["library", "home", "search"])
        XCTAssertEqual(order.displayed(order: "home,library", hidden: "search,library"), ["home", "search"])
        XCTAssertEqual(order.displayed(order: "", hidden: "home,library"), ["home", "search"])
        XCTAssertEqual(order.displayed(order: "mix,home", hidden: nil, additional: ["mix", "other"]),
                       ["mix", "home", "search"])
    }

    func testStorageHonorsIndependentKeys() throws {
        let suite = "frontam.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FrontAMTabStorage(orderKey: "first-order", hiddenKey: "first-hidden", defaults: defaults)
        let second = FrontAMTabStorage(orderKey: "second-order", hiddenKey: "second-hidden", defaults: defaults)

        defaults.set(order.raw(["library", "home"]), forKey: first.orderKey)
        defaults.set("home", forKey: first.hiddenKey)
        XCTAssertEqual(first.order, "library,home")
        XCTAssertEqual(first.hidden, "home")
        XCTAssertNil(second.order)
        XCTAssertNil(second.hidden)
    }
}
