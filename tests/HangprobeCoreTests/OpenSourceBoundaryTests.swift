import Foundation
import XCTest
import HangprobeCore
import HangprobeKit

final class OpenSourceBoundaryTests: XCTestCase {
    func testRepoAndDeviceSDKAreMIT() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let rootLicense = try String(contentsOf: repoRoot.appendingPathComponent("LICENSE"), encoding: .utf8)
        XCTAssertTrue(rootLicense.contains("MIT License"))

        let ossRoot = repoRoot.appendingPathComponent("oss", isDirectory: true)
        let ossLicense = try String(contentsOf: ossRoot.appendingPathComponent("LICENSE"), encoding: .utf8)
        XCTAssertTrue(ossLicense.contains("MIT License"))

        let enumerator = FileManager.default.enumerator(at: ossRoot, includingPropertiesForKeys: nil)
        var checkedFiles = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            let ext = fileURL.pathExtension
            guard ext == "swift" || ext == "kt" else { continue }
            checkedFiles += 1
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertTrue(source.contains("SPDX-License-Identifier: MIT"), "\(fileURL.lastPathComponent) must carry MIT SPDX header")
            XCTAssertFalse(source.contains("import HangprobeCore"), "\(fileURL.lastPathComponent) must not import HangprobeCore")
            XCTAssertFalse(source.contains("import HangprobeApp"), "\(fileURL.lastPathComponent) must not import HangprobeApp")
        }
        XCTAssertGreaterThanOrEqual(checkedFiles, 2)
    }

    func testMarketingVersionIsPresent() {
        XCTAssertFalse(HangprobeVersion.marketing.isEmpty)
        XCTAssertTrue(HangprobeVersion.marketing.contains("."))
    }
}
