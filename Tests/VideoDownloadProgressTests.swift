import XCTest

@testable import chahua_apple

final class VideoDownloadProgressTests: XCTestCase {
    func testKnownByteCountsDriveRingAndPercentage() {
        let starting = VideoDownloadProgress(receivedBytes: 0, expectedBytes: 1_024)
        XCTAssertEqual(starting.fraction, 0)
        XCTAssertEqual(starting.percentage, 0)
        let downloading = VideoDownloadProgress(receivedBytes: 256, expectedBytes: 1_024)
        XCTAssertEqual(downloading.fraction, 0.25)
        XCTAssertEqual(downloading.percentage, 25)
        let complete = VideoDownloadProgress(receivedBytes: 1_024, expectedBytes: 1_024)
        XCTAssertEqual(complete.fraction, 1)
        XCTAssertEqual(complete.percentage, 100)
    }

    func testUnknownOrInconsistentByteCountsNeverInventPercentage() {
        let counts: [(Int64, Int64)] = [(256, -1), (256, 0), (-1, 1_024), (1_025, 1_024)]
        for (received, expected) in counts {
            let progress = VideoDownloadProgress(receivedBytes: received, expectedBytes: expected)
            XCTAssertNil(progress.fraction)
            XCTAssertNil(progress.percentage)
        }
    }
}
