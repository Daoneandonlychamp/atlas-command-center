import Foundation

public final class ProcessRegistry {
    public static let shared = ProcessRegistry()

    private var activeProcesses: Set<Process> = []
    private let lock = NSLock()

    public init() {}

    public func register(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        activeProcesses.insert(process)
    }

    public func unregister(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        activeProcesses.remove(process)
    }

    public func terminateAll() -> Int {
        lock.lock()
        let processesToKill = Array(activeProcesses)
        activeProcesses.removeAll()
        lock.unlock()

        var killedCount = 0

        for process in processesToKill {
            if process.isRunning {
                process.terminate()
                killedCount += 1
            }
        }

        // Wait up to 500ms for graceful shutdown, then SIGKILL if still running
        Thread.sleep(forTimeInterval: 0.1)

        for process in processesToKill {
            if process.isRunning {
                let pid = process.processIdentifier
                if pid > 0 {
                    kill(pid, SIGKILL)
                }
            }
        }

        return killedCount
    }
}
