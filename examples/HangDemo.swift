import Foundation

// Demo helper for capturing real `busy`, `blocked`, and `responsive` main-thread samples on this Mac.
let mode = CommandLine.arguments.dropFirst().first ?? "responsive"
let lock = NSLock()

@inline(never)
func layoutLoopSpin() -> Double {
    var acc = 1.0
    let deadline = Date().addingTimeInterval(6.0)
    while Date() < deadline {
        acc = sin(acc) * cos(acc) + 1.000001
    }
    return acc
}

@inline(never)
func mainThreadDeadlock() {
    lock.lock()
    DispatchQueue.global().async {
        Thread.sleep(forTimeInterval: 6.0)
        lock.unlock()
    }
    Thread.sleep(forTimeInterval: 0.02)
    lock.lock()
    lock.unlock()
}

switch mode {
case "busy":
    DispatchQueue.main.async {
        _ = layoutLoopSpin()
        exit(0)
    }
case "blocked":
    DispatchQueue.main.async {
        mainThreadDeadlock()
        exit(0)
    }
default:
    DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
        exit(0)
    }
}

RunLoop.main.run()
