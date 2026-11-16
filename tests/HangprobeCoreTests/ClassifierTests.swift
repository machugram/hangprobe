import Foundation
import XCTest
import HangprobeCore

final class ClassifierTests: XCTestCase {
    func testLayoutLoop() throws {
        let report = try SampleClassifier.classify(Fixtures.layout, thresholdMS: 250)
        XCTAssertTrue(report.hung)
        XCTAssertEqual(report.kind, .busy)
        XCTAssertTrue(report.gapAtLeast)
        XCTAssertEqual(report.mainGapMS, 1000)
        XCTAssertEqual(report.eventWaitMS, 0)
        XCTAssertEqual(report.top, "SportProfileEditorView.body.getter")
        XCTAssertTrue(report.stack.contains("SportProfileEditorView.body.getter (in Awtsyde)"))
    }

    func testDeadlockInsideSource() throws {
        let report = try SampleClassifier.classify(Fixtures.deadlock, thresholdMS: 250)
        XCTAssertTrue(report.hung)
        XCTAssertEqual(report.kind, .blocked)
        XCTAssertEqual(report.blockedMS, 800)
        XCTAssertEqual(report.top, "__psynch_mutexwait")
        XCTAssertTrue(report.stack.contains { $0.contains("Store load") })
    }

    func testResponsiveWithALittleLayout() throws {
        let report = try SampleClassifier.classify(Fixtures.responsive, thresholdMS: 250)
        XCTAssertFalse(report.hung)
        XCTAssertEqual(report.kind, .responsive)
        XCTAssertEqual(report.eventWaitMS, 970)
        XCTAssertEqual(report.busyMS, 30)
        XCTAssertEqual(report.mainGapMS, 30)
        XCTAssertEqual(report.top, "mach_msg2_trap")
    }

    func testBusyFixture() throws {
        let report = try SampleClassifier.classify(Fixtures.text("busy.txt"), thresholdMS: 250)
        XCTAssertTrue(report.hung)
        XCTAssertEqual(report.kind, .busy)
        XCTAssertEqual(report.blockedMS, 0)
        XCTAssertEqual(report.eventWaitMS, 0)
        XCTAssertGreaterThanOrEqual(report.mainGapMS, 250)
        XCTAssertEqual(report.samples, 92)
    }

    func testSleepFixture() throws {
        let report = try SampleClassifier.classify(Fixtures.text("sleep.txt"), thresholdMS: 250)
        XCTAssertTrue(report.hung)
        XCTAssertEqual(report.kind, .blocked)
        XCTAssertEqual(report.top, "__semwait_signal")
        XCTAssertTrue(report.stack.contains { $0.contains("time_sleep") })
    }

    func testLockFixture() throws {
        let report = try SampleClassifier.classify(Fixtures.text("lock.txt"), thresholdMS: 250)
        XCTAssertTrue(report.hung)
        XCTAssertEqual(report.kind, .blocked)
        XCTAssertEqual(report.top, "__psynch_cvwait")
        XCTAssertTrue(report.stack.contains { $0.contains("_PyMutex_LockTimed") })
    }

    func testFinderFixture() throws {
        let report = try SampleClassifier.classify(Fixtures.text("finder.txt"), thresholdMS: 250)
        XCTAssertFalse(report.hung)
        XCTAssertEqual(report.kind, .responsive)
        XCTAssertGreaterThan(report.eventWaitMS, report.mainGapMS)
        XCTAssertEqual(report.top, "mach_msg2_trap")
    }

    func testRejectsBadWindow() {
        XCTAssertThrowsError(try SampleClassifier.classify("nope", thresholdMS: 250))
        XCTAssertThrowsError(try ProbeLimits.seconds(0))
        XCTAssertThrowsError(try ProbeLimits.seconds(4))
        XCTAssertNoThrow(try ProbeLimits.seconds(1))
        XCTAssertThrowsError(try ProbeLimits.threshold(49))
    }
}

final class ProcessListTests: XCTestCase {
    func testForegroundListingKeepsLiveApps() {
        let listing = """
        53) "Simulator" ASN:0x0-1:
            bundleID="com.apple.iphonesimulator"
            executable path="/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"
            pid = 55077 type="Foreground" flavor=3 fileType="APPL"
        56) "Finder" ASN:0x0-2:
            bundleID="com.apple.finder"
            executable path="/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
            pid = 93736 type="Foreground" flavor=3 fileType="FNDR"
        76) "Cursor Helper" ASN:0x0-3:
            bundleID="com.todesktop.helper"
            executable path="/Applications/Cursor.app/Contents/MacOS/Cursor Helper"
            pid = 20234 type="UIElement" flavor=2 fileType="APPL"
        80) "Old" ASN:0x0-4:
            bundleID="com.example.old"
            executable path="/Applications/Old.app/Contents/MacOS/Old"
            pid = 4 (terminated) type="Foreground" flavor=3 fileType="APPL"
        """
        let apps = ProcessList.foreground(from: listing)
        XCTAssertEqual(apps.map(\.app), ["Simulator", "Finder"])
        XCTAssertEqual(apps.map(\.pid), [55077, 93736])
        XCTAssertEqual(apps.map(\.bundleID), ["com.apple.iphonesimulator", "com.apple.finder"])
    }

    func testLiveListHasAPlace() {
        for app in ProcessList.current() {
            XCTAssertFalse(app.app.isEmpty)
            XCTAssertTrue([ProbePlace.mac, .simulator, .android].contains(app.place))
        }
    }
}

final class AndroidTraceTests: XCTestCase {
    func testDebuggerdBacktraceParkedInLooperIsResponsive() throws {
        let report = try AndroidTrace.classify(Fixtures.debuggerd, thresholdMS: 250, package: "com.example.app")
        XCTAssertFalse(report.hung)
        XCTAssertEqual(report.kind, .responsive)
        XCTAssertTrue(report.top.contains("epoll_wait"))
    }

    func testLooperIsResponsive() throws {
        let report = try AndroidTrace.classify(Fixtures.looper, thresholdMS: 250, package: "com.example.app")
        XCTAssertFalse(report.hung)
        XCTAssertEqual(report.kind, .responsive)
        XCTAssertEqual(report.place, .android)
        XCTAssertEqual(report.top, "android.os.MessageQueue.nativePollOnce")
    }

    func testLockOffTheLoopIsBlocked() throws {
        let report = try AndroidTrace.classify(Fixtures.androidLock, thresholdMS: 250, package: "com.example.app")
        XCTAssertTrue(report.hung)
        XCTAssertEqual(report.kind, .blocked)
        XCTAssertTrue(report.gapAtLeast)
        XCTAssertEqual(report.mainGapMS, 250)
        XCTAssertTrue(report.stack.contains { $0.contains("App.freeze") })
    }

    func testAppFramesOnTheCPUAreBusy() throws {
        let report = try AndroidTrace.classify(Fixtures.androidBusy, thresholdMS: 250, package: "com.example.app")
        XCTAssertEqual(report.kind, .busy)
        XCTAssertEqual(report.top, "com.example.Heavy.layout")
    }

    func testANRIsLabeledAtFiveSeconds() throws {
        let report = try AndroidTrace.classify(Fixtures.anr, thresholdMS: 250, package: "com.example.app")
        XCTAssertEqual(report.kind, .blocked)
        XCTAssertEqual(report.mainGapMS, 5000)
        XCTAssertEqual(report.windowMS, 5000)
        XCTAssertEqual(report.note, AndroidTrace.anrNote)
        XCTAssertTrue(report.hung)
    }

    func testPackageListIntersectsRunningPids() {
        let processes = """
        USER PID PPID NAME
        u0_a1 42 1 com.example.app
        u0_a2 99 1 com.android.systemui
        """
        let hits = AndroidDevices.runningPackages(packages: ["com.example.app"], processList: processes)
        XCTAssertEqual(hits.map(\.pid), [42])
        XCTAssertEqual(hits.map(\.package), ["com.example.app"])
    }

    func testDeviceLines() {
        let text = """
        List of devices attached
        emulator-5554          device product:sdk model:sdk
        ZZZ                unauthorized
        """
        XCTAssertEqual(AndroidDevices.serials(in: text), ["emulator-5554"])
    }
}

final class HistoryAndWatchTests: XCTestCase {
    func testDiffShowsGapAndFrames() {
        let before = makeReport(gap: 800, stack: ["a", "b"])
        let after = makeReport(gap: 40, stack: ["b", "c"])
        let diff = ProbeDiff.compare(before, after)
        XCTAssertEqual(diff.gapDeltaMS, -760)
        XCTAssertEqual(diff.framesAdded, ["c"])
        XCTAssertEqual(diff.framesRemoved, ["a"])
    }

    func testHistoryRoundTrip() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = ProbeStore(root: root)
        var first = makeReport(gap: 10, stack: ["one"])
        first.app = "Finder"
        var second = makeReport(gap: 20, stack: ["two"])
        second.app = "Finder"
        try store.append(first)
        Thread.sleep(forTimeInterval: 0.01)
        try store.append(second)
        let pair = try store.latestPair(app: "Finder")
        XCTAssertEqual(pair?.0.mainGapMS, 10)
        XCTAssertEqual(pair?.1.mainGapMS, 20)
    }

    func testWatchStopsOnTheFirstHang() throws {
        var calls = 0
        let report = try WatchRun.firstHang(attempts: 5) {
            calls += 1
            return calls < 3 ? makeReport(gap: 10, stack: ["wait"]) : makeReport(gap: 400, stack: ["stuck"], hung: true, kind: .busy)
        }
        XCTAssertEqual(calls, 3)
        XCTAssertTrue(report.hung)
        XCTAssertEqual(report.top, "stuck")
    }

    func testHungProbeExitsNonZero() {
        XCTAssertEqual(ProbeExit.code(for: makeReport(gap: 400, stack: ["stuck"], hung: true, kind: .busy)), 1)
        XCTAssertEqual(ProbeExit.code(for: makeReport(gap: 10, stack: ["wait"])), 0)
    }

    func testSymbolicationRewritesTheAppFrame() {
        let stack = Symbolicator.apply(
            stack: ["0x1abc (in Awtsyde)", "mach_msg2_trap (in libsystem_kernel.dylib)"],
            symbols: ["0x1abc": "SportProfileEditorView.body.getter"]
        )
        XCTAssertEqual(stack[0], "SportProfileEditorView.body.getter (in Awtsyde)")
        XCTAssertEqual(Symbolicator.leadingAppFrame(stack: stack, app: "Awtsyde"), stack[0])
    }

    func testMarkdownCarriesKindGapAndStack() {
        let text = ReportMarkdown.render(makeReport(gap: 30, stack: ["mach_msg2_trap (in libsystem_kernel.dylib)"]))
        XCTAssertTrue(text.contains("responsive"))
        XCTAssertTrue(text.contains("30 ms"))
        XCTAssertTrue(text.contains("mach_msg2_trap"))
    }

    private func makeReport(gap: Int, stack: [String], hung: Bool = false, kind: HangKind = .responsive) -> HangReport {
        HangReport(
            hung: hung,
            kind: kind,
            mainGapMS: gap,
            gapAtLeast: hung,
            busyMS: kind == .busy ? gap : 0,
            blockedMS: kind == .blocked ? gap : 0,
            eventWaitMS: hung ? 0 : gap,
            windowMS: max(gap, 1),
            thresholdMS: 250,
            samples: 1,
            top: stack.last ?? "",
            stack: stack
        )
    }
}

final class MCPTests: XCTestCase {
    func testNewlineFraming() throws {
        let raw = Data("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        {"jsonrpc":"2.0","id":2,"method":"tools/list"}
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"probe_hang","arguments":{"app":"Finder"}}}

        """.utf8)
        let replies = try roundtrip(raw)
        XCTAssertEqual(replies[0]["result"] as? [String: Any] == nil, false)
        let first = replies[0]["result"] as? [String: Any]
        let info = first?["serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "hangprobe")
        let tools = (replies[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.first?["name"] as? String, "probe_hang")
        let content = ((replies[2]["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
        let body = try JSONSerialization.jsonObject(with: Data(content!.utf8)) as? [String: Any]
        XCTAssertEqual(body?["hung"] as? Bool, false)
        XCTAssertEqual(body?["kind"] as? String, "responsive")
        XCTAssertEqual(body?["app"] as? String, "Finder")
    }

    func testContentLengthFraming() throws {
        let payload = Data(#"{"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#.utf8)
        var buffer = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        buffer.append(payload)
        let message = try MCPSession.readMessage(&buffer) { nil }
        let encoded = MCPSession.encode(["jsonrpc": "2.0", "id": 7, "result": ["protocolVersion": message!.0["params"] as? [String: Any] == nil ? "" : ((message!.0["params"] as? [String: Any])?["protocolVersion"] as? String ?? "")]], framing: message!.1)
        XCTAssertTrue(encoded.starts(with: Data("Content-Length:".utf8)))
        var initialized = false
        let response = MCPSession.handle(message!.0, initialized: &initialized, probe: { _, _, _ in fatalError() })
        let result = response?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2024-11-05")
    }

    func testUnknownField() throws {
        let raw = Data("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"probe_hang","arguments":{"nope":1}}}

        """.utf8)
        let replies = try roundtrip(raw)
        let result = replies[1]["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
    }

    private func roundtrip(_ raw: Data) throws -> [[String: Any]] {
        var buffer = raw
        var initialized = false
        var replies: [[String: Any]] = []
        while true {
            let next = try MCPSession.readMessage(&buffer) { nil }
            guard let next else { break }
            if let response = MCPSession.handle(next.0, initialized: &initialized, probe: { app, _, _ in
                HangReport(hung: false, kind: .responsive, mainGapMS: 0, gapAtLeast: false, busyMS: 0, blockedMS: 0, eventWaitMS: 0, windowMS: 0, thresholdMS: 250, samples: 1, top: "", stack: [], app: app)
            }) {
                replies.append(response)
            }
        }
        return replies
    }
}

private enum Fixtures {
    static let layout = """
    Analysis of sampling Awtsyde every 10 milliseconds
    Call graph:
        100 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
        + 100 start  (in dyld) + 1  [0x1]
        +   100 main  (in Awtsyde) + 1  [0x1]
        +     100 UIApplicationMain  (in UIKitCore) + 1  [0x1]
        +       100 GSEventRunModal  (in GraphicsServices) + 1  [0x1]
        +         100 CFRunLoopRunSpecific  (in CoreFoundation) + 1  [0x1]
        +           100 __CFRunLoopRun  (in CoreFoundation) + 1  [0x1]
        +             100 __CFRunLoopDoObservers  (in CoreFoundation) + 1  [0x1]
        +               100 CA::Transaction::commit()  (in QuartzCore) + 1  [0x1]
        +                 100 -[UIView layoutSubviews]  (in UIKitCore) + 1  [0x1]
        +                   100 SportProfileEditorView.body.getter  (in Awtsyde) + 1  [0x1]
    Total number in stack (recursive counted multiple, when >=5):
    """

    static let deadlock = """
    Analysis of sampling Awtsyde every 10 milliseconds
    Call graph:
        80 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
        + 80 start  (in dyld) + 1  [0x1]
        +   80 __CFRunLoopRun  (in CoreFoundation) + 1  [0x1]
        +     80 __CFRunLoopDoSources0  (in CoreFoundation) + 1  [0x1]
        +       80 __CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__  (in CoreFoundation) + 1  [0x1]
        +         80 -[Store load]  (in Awtsyde) + 1  [0x1]
        +           80 pthread_mutex_lock  (in libsystem_pthread.dylib) + 1  [0x1]
        +             80 __psynch_mutexwait  (in libsystem_kernel.dylib) + 1  [0x1]
    Total number in stack (recursive counted multiple, when >=5):
    """

    static let responsive = """
    Analysis of sampling Awtsyde every 10 milliseconds
    Call graph:
        100 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
        + 100 start  (in dyld) + 1  [0x1]
        +   100 UIApplicationMain  (in UIKitCore) + 1  [0x1]
        +     97 __CFRunLoopServiceMachPort  (in CoreFoundation) + 1  [0x1]
        +     ! 97 mach_msg2_trap  (in libsystem_kernel.dylib) + 1  [0x1]
        +     3 __CFRunLoopDoObservers  (in CoreFoundation) + 1  [0x1]
        +       3 -[UIView layoutSubviews]  (in UIKitCore) + 1  [0x1]
    Total number in stack (recursive counted multiple, when >=5):
    """

    static let debuggerd = """
    pid: 4321, tid: 4321, name: main  >>> com.example.app <<<
    backtrace:
          #00 pc 0000000000049a24  /apex/com.android.runtime/lib64/bionic/libc.so (epoll_wait+20)
          #01 pc 00000000001a2c10  /system/lib64/libandroid_runtime.so (android::android_os_MessageQueue_nativePollOnce+120)
          #02 pc 00000000000aa100  /system/lib64/libandroid_runtime.so (android::Looper::pollInner+80)
    """

    static let looper = """
    "main" prio=5 tid=1 Native
      | state=S
      at android.os.MessageQueue.nativePollOnce(Native method)
      at android.os.MessageQueue.next(MessageQueue.java:335)
      at android.os.Looper.loop(Looper.java:183)
      at android.app.ActivityThread.main(ActivityThread.java:7656)
    """

    static let androidLock = """
    "main" prio=5 tid=1 Blocked
      | state=S
      at com.example.App.freeze(App.java:10)
      - waiting to lock <0x123> (a java.lang.Object) held by thread 12
      at android.os.Looper.loop(Looper.java:174)
    """

    static let androidBusy = """
    "main" prio=5 tid=1 Runnable
      | state=R
      at com.example.Heavy.layout(Heavy.java:40)
      at android.view.View.layout(View.java:1)
    """

    static let anr = """
    Subject: Input dispatching timed out
    ANR in com.example.app
    "main" prio=5 tid=1 Blocked
      at com.example.App.freeze(App.java:10)
      - waiting to lock <0x123> (a java.lang.Object) held by thread 12
    """

    static func text(_ name: String) -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/\(name)")
        return (try? String(contentsOf: root, encoding: .utf8)) ?? ""
    }
}
