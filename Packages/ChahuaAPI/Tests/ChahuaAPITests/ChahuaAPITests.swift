import XCTest
@testable import ChahuaAPI

final class ChahuaAPITests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertFalse(ChahuaAPI.version.isEmpty)
    }
}
