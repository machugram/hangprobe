import Foundation
import XCTest
import HangprobeCore
import HangprobeKit

final class PhoneAPMTests: XCTestCase {
    func testMetricKitHangImportClassifiesBusyAndExtractsContext() throws {
        let json = """
        {
          "timeStampEnd": "2026-11-12T23:30:00Z",
          "hangDiagnostics": [
            {
              "hangDuration": "640 ms",
              "diagnosticMetaData": {
                "bundleIdentifier": "com.awtsyde.mobile",
                "appBuildVersion": "8f3c12a",
                "deviceType": "iPhone17,1",
                "osVersion": "iOS 20.1",
                "platformArchitecture": "arm64e",
                "regionFormat": "SportProfileEditor"
              },
              "callStackTree": {
                "callStacks": [
                  {
                    "threadAttributed": true,
                    "callStackRootFrames": [
                      {
                        "binaryName": "dyld",
                        "symbol": "start",
                        "sampleCount": 64,
                        "subFrames": [
                          {
                            "binaryName": "UIKitCore",
                            "symbol": "-[UIView layoutSubviews]",
                            "sampleCount": 64,
                            "subFrames": [
                              {
                                "binaryName": "mobile",
                                "address": 4362109440,
                                "offsetIntoBinaryTextSegment": 33280,
                                "binaryUUID": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
                                "sampleCount": 64
                              }
                            ]
                          }
                        ]
                      }
                    ]
                  }
                ]
              }
            }
          ]
        }
        """
        let reports = try MetricKitHangImporter.parse(Data(json.utf8), thresholdMS: 250)
        XCTAssertEqual(reports.count, 1)
        let report = reports[0]
        XCTAssertTrue(report.hung)
        XCTAssertEqual(report.kind, .busy)
        XCTAssertEqual(report.mainGapMS, 640)
        XCTAssertEqual(report.place, .ios)
        XCTAssertEqual(report.bundleID, "com.awtsyde.mobile")
        XCTAssertEqual(report.context?.commit, "8f3c12a")
        XCTAssertEqual(report.context?.device, "iPhone17,1")
        XCTAssertEqual(report.context?.loadAddress, "0x104000000")
        XCTAssertTrue(report.stack.last?.contains("0x104008200 (in mobile)") == true)
    }

    func testMetricKitBlockedHangUnderRunLoopSource() throws {
        let json = """
        {
          "hangDuration": "1.2 s",
          "diagnosticMetaData": {
            "bundleIdentifier": "com.example.shop",
            "appBuildVersion": "42",
            "deviceType": "iPhone16,2",
            "osVersion": "iOS 19.4"
          },
          "callStackTree": {
            "callStacks": [
              {
                "threadAttributed": true,
                "callStackRootFrames": [
                  {
                    "binaryName": "CoreFoundation",
                    "symbol": "__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__",
                    "sampleCount": 120,
                    "subFrames": [
                      {
                        "binaryName": "shop",
                        "symbol": "-[CatalogStore syncMainThread]",
                        "sampleCount": 120,
                        "subFrames": [
                          {
                            "binaryName": "libsystem_kernel.dylib",
                            "symbol": "__psynch_mutexwait",
                            "sampleCount": 120
                          }
                        ]
                      }
                    ]
                  }
                ]
              }
            ]
          }
        }
        """
        let reports = try MetricKitHangImporter.parse(Data(json.utf8), thresholdMS: 250)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].kind, .blocked)
        XCTAssertEqual(reports[0].mainGapMS, 1200)
        XCTAssertEqual(reports[0].top, "__psynch_mutexwait")
        XCTAssertEqual(Symbolicator.leadingAppFrame(stack: reports[0].stack, app: "shop"), "-[CatalogStore syncMainThread] (in shop)")
    }

    func testPhoneInboxIngestsWatchdogPayloadAndSavesToDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hangprobe-inbox-\(UUID().uuidString)")
        let store = PhoneInboxStore(root: dir)
        let server = PhoneInboxServer(port: 19481, store: store)

        let config = HangprobeWatchdogConfig(
            appName: "Awtsyde",
            bundleID: "com.awtsyde.mobile",
            commit: "91ab44e",
            currentScreen: { "SportProfileEditorView" }
        )
        let payload = HangprobeWatchdog.buildPayload(
            gapMS: 410,
            gapAtLeast: true,
            frames: ["SportProfileEditorView.body.getter (in Awtsyde)"],
            config: config
        )
        let encoded = try JSONEncoder().encode(payload)
        let ingested = try server.ingestPayload(encoded)
        XCTAssertEqual(ingested.count, 1)
        XCTAssertEqual(ingested[0].app, "Awtsyde")
        XCTAssertEqual(ingested[0].mainGapMS, 410)
        XCTAssertEqual(ingested[0].context?.screen, "SportProfileEditorView")
        XCTAssertEqual(store.allReports().count, 1)
    }

    func testRegressionGateFailsOnHangOrDeltaRegression() {
        let base = HangReport(
            hung: false, kind: .responsive, mainGapMS: 20, gapAtLeast: false,
            busyMS: 20, blockedMS: 0, eventWaitMS: 890, windowMS: 910,
            thresholdMS: 250, samples: 91, top: "mach_msg2_trap", stack: []
        )
        let regressed = HangReport(
            hung: false, kind: .responsive, mainGapMS: 110, gapAtLeast: false,
            busyMS: 110, blockedMS: 0, eventWaitMS: 800, windowMS: 910,
            thresholdMS: 250, samples: 91, top: "layoutSubviews", stack: []
        )
        let failedDelta = RegressionGate.evaluate(baseline: base, candidate: regressed, maxGapMS: 250, maxRegressionMS: 50)
        XCTAssertFalse(failedDelta.passed)
        XCTAssertEqual(failedDelta.deltaMS, 90)

        let ok = RegressionGate.evaluate(baseline: base, candidate: base, maxGapMS: 250, maxRegressionMS: 50)
        XCTAssertTrue(ok.passed)
    }

    func testReportExporterRendersMarkdownAndPrettyJSON() throws {
        let report = HangReport(
            hung: true, kind: .busy, mainGapMS: 520, gapAtLeast: true,
            busyMS: 520, blockedMS: 0, eventWaitMS: 0, windowMS: 520,
            thresholdMS: 250, samples: 52, top: "SportProfileEditorView.body.getter",
            stack: ["SportProfileEditorView.body.getter (in Awtsyde)"],
            app: "Awtsyde", bundleID: "com.awtsyde.mobile", place: .ios
        )
        let md = ReportExporter.markdown(report)
        XCTAssertTrue(md.contains("SportProfileEditorView.body.getter"))
        let json = try ReportExporter.prettyJSON(report)
        XCTAssertFalse(json.isEmpty)
    }

    func testAndroidMultiBurstAggregatesTimeAndHotspots() throws {
        let looperDump = """
        "main" prio=5 tid=1 Native
          at android.os.MessageQueue.nativePollOnce(Native method)
          at android.os.MessageQueue.next(MessageQueue.java:335)
          at android.os.Looper.loop(Looper.java:183)
        """
        let busyDump = """
        "main" prio=5 tid=1 Runnable
          at com.example.shop.CatalogParser.decode(CatalogParser.kt:88)
          at com.example.shop.HomeFragment.onResume(HomeFragment.kt:41)
          at android.os.Looper.loop(Looper.java:183)
        """
        // 3 of 4 samples busy over 1000 ms => 750 ms busy, 250 ms event wait => hung (.busy)
        let burst = try AndroidTrace.classifyBurst(
            [looperDump, busyDump, busyDump, busyDump],
            windowMS: 1000,
            thresholdMS: 250,
            package: "com.example.shop"
        )
        XCTAssertTrue(burst.hung)
        XCTAssertEqual(burst.kind, .busy)
        XCTAssertEqual(burst.busyMS, 750)
        XCTAssertEqual(burst.eventWaitMS, 250)
        XCTAssertEqual(burst.mainGapMS, 750)
        XCTAssertEqual(burst.samples, 4)
        XCTAssertEqual(burst.top, "com.example.shop.CatalogParser.decode")
        XCTAssertTrue(burst.hotspots?.contains(where: { $0.frame.contains("CatalogParser.decode") && $0.hits == 3 }) == true)
    }

    func testAndroidApplicationExitInfoParserExtractsPlayVitalsANR() {
        let dumpsys = """
        Current Process Exit Info:
          package: com.example.shop
            ApplicationExitInfo #0:
              timestamp=2026-11-12 23:40:12.104
              pid=14420
              realUid=10244
              packageUid=10244
              definingUid=10244
              user=0
              process=com.example.shop
              reason=6 (ANR)
              subreason=0 (UNKNOWN)
              status=0
              importance=100
              pss=142MB
              rss=298MB
              description=Input dispatching timed out (Waiting to send non-key event because the touched window has not finished processing)
            ApplicationExitInfo #1:
              timestamp=2026-11-11 10:12:00.000
              pid=9981
              process=com.example.shop
              reason=10 (USER REQUESTED)
              description=stop com.example.shop
        """
        let parsed = AndroidExitInfoParser.parse(dumpsys, thresholdMS: 250)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].app, "com.example.shop")
        XCTAssertEqual(parsed[0].pid, 14420)
        XCTAssertEqual(parsed[0].mainGapMS, 5000)
        XCTAssertEqual(parsed[0].severity, .androidANR)
        XCTAssertTrue(parsed[0].top.contains("Input dispatching timed out"))
    }

    func testFrameInspectorFoldsSystemFramesAndHighlightsAppAndLocks() {
        let stack = [
            "NSApplicationMain (in AppKit)",
            "-[NSApplication run] (in AppKit)",
            "__CFRunLoopRun (in CoreFoundation)",
            "__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__ (in CoreFoundation)",
            "-[CatalogStore syncMainThread] (in Awtsyde)",
            "pthread_mutex_lock (in libsystem_pthread.dylib)",
            "__psynch_mutexwait (in libsystem_kernel.dylib)",
        ]
        let groups = FrameInspector.grouped(stack: stack, app: "Awtsyde")
        // First 4 AppKit/CoreFoundation frames fold into 1 collapsedSystem group, then app + lock frames stay focused
        XCTAssertEqual(groups.count, 4)
        if case .collapsedSystem(_, let folded) = groups[0] {
            XCTAssertEqual(folded.count, 4)
        } else {
            XCTFail("Expected leading system frames to fold")
        }
        if case .focus(let appFrame) = groups[1] {
            XCTAssertEqual(appFrame.layer, .app)
            XCTAssertEqual(appFrame.module, "Awtsyde")
        } else {
            XCTFail("Expected Awtsyde frame to stay focused")
        }
        if case .focus(let lockLeaf) = groups[3] {
            XCTAssertEqual(lockLeaf.layer, .lock)
            XCTAssertNotNil(lockLeaf.hint)
        } else {
            XCTFail("Expected __psynch_mutexwait leaf to classify as .lock")
        }
    }
}
