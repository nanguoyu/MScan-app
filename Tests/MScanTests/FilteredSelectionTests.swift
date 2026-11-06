import XCTest
@testable import MScan

final class FilteredSelectionTests: XCTestCase {
    func testFilterTemporarilyHidesSelectionFromActionsThenRestoresIt() {
        var history = FilteredSelection()
        let inventory: Set<String> = ["a", "b", "c"]
        let selected: Set<String> = ["a", "b"]
        let partial = history.reconcile(current: selected, inventory: inventory, visible: ["b", "c"])
        XCTAssertEqual(partial, ["b"])
        XCTAssertTrue(history.reconcile(current: partial, inventory: inventory, visible: []).isEmpty)
        XCTAssertEqual(history.reconcile(current: [], inventory: inventory, visible: inventory), selected)
    }

    func testRemovedDeviceCannotBeRestoredByClearingFilter() {
        var history = FilteredSelection()
        XCTAssertTrue(history.reconcile(current: ["a"], inventory: ["a", "b"], visible: ["b"]).isEmpty)
        XCTAssertTrue(history.reconcile(current: [], inventory: [], visible: []).isEmpty)
        XCTAssertTrue(history.reconcile(current: [], inventory: ["a"], visible: ["a"]).isEmpty)
    }
}
