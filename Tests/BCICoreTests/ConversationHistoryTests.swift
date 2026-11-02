import XCTest
@testable import BCICore

final class ConversationHistoryTests: XCTestCase {
    func testRecentIsOldestFirstAndBounded() {
        let h = ConversationHistory()
        h.append(heard: "a", spoken: "1")
        h.append(heard: "b", spoken: nil)
        h.append(heard: "c", spoken: "3")
        XCTAssertEqual(h.recent(2), [.init(heard: "b", spoken: nil), .init(heard: "c", spoken: "3")])
        XCTAssertEqual(h.recent(10).map(\.heard), ["a", "b", "c"])
        XCTAssertEqual(h.recent(0), [])
    }

    func testCapacityDropsTheOldest() {
        let h = ConversationHistory(capacity: 2)
        for word in ["a", "b", "c"] { h.append(heard: word, spoken: nil) }
        XCTAssertEqual(h.recent(10).map(\.heard), ["b", "c"])
    }

    func testClearEmptiesIt() {
        let h = ConversationHistory()
        h.append(heard: "a", spoken: "1")
        h.clear()
        XCTAssertEqual(h.recent(10), [])
    }
}
