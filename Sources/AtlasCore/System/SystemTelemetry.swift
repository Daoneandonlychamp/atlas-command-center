import Foundation
import Darwin
import IOKit.ps

/// Live machine vitals for the HUD.
///
/// Everything here comes from the kernel directly rather than by shelling out
/// to `top` or `vm_stat` — a HUD refreshes every couple of seconds and
/// spawning two processes that often is pure waste.
public struct SystemVitals: Codable, Hashable {
    public var cpuPercent: Double = 0
    public var memoryUsedBytes: Int64 = 0
    public var memoryTotalBytes: Int64 = 0
    public var diskUsedBytes: Int64 = 0
    public var diskTotalBytes: Int64 = 0
    public var uptimeSeconds: Double = 0
    public var processorCount: Int = 0
    public var thermalState: String = "nominal"
    public var batteryPercent: Double? = nil
    public var isCharging: Bool = false
    /// Bytes per second across physical interfaces, averaged since the last
    /// sample. Nil on the first sample, which has nothing to difference against.
    public var networkInBytesPerSecond: Double? = nil
    public var networkOutBytesPerSecond: Double? = nil

    /// Not encoded — `Codable` skips computed properties, so any consumer
    /// reading this struct as JSON must derive these from the byte counts.
    public var memoryPercent: Double {
        memoryTotalBytes > 0 ? Double(memoryUsedBytes) / Double(memoryTotalBytes) * 100 : 0
    }
    public var diskPercent: Double {
        diskTotalBytes > 0 ? Double(diskUsedBytes) / Double(diskTotalBytes) * 100 : 0
    }
}

public final class SystemTelemetry {
    public static let shared = SystemTelemetry()

    /// CPU load is a delta between two samples, so the previous tick counts
    /// have to be carried between reads. The first read has nothing to compare
    /// against and honestly reports zero rather than a fabricated number.
    private var previousTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var cachedDisk: (used: Int64, total: Int64, at: Date)?
    private var previousNetwork: (inBytes: UInt64, outBytes: UInt64, at: Date)?
    private let diskCacheSeconds: TimeInterval = 60
    private let lock = NSLock()

    public func sample() -> SystemVitals {
        var vitals = SystemVitals()
        vitals.processorCount = ProcessInfo.processInfo.processorCount
        vitals.uptimeSeconds = ProcessInfo.processInfo.systemUptime
        vitals.memoryTotalBytes = Int64(ProcessInfo.processInfo.physicalMemory)
        vitals.cpuPercent = cpuUsagePercent()
        vitals.memoryUsedBytes = memoryUsedBytes()

        let battery = batteryState()
        vitals.batteryPercent = battery.percent
        vitals.isCharging = battery.charging

        let throughput = networkThroughput()
        vitals.networkInBytesPerSecond = throughput.inBps
        vitals.networkOutBytesPerSecond = throughput.outBps

        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  vitals.thermalState = "nominal"
        case .fair:     vitals.thermalState = "fair"
        case .serious:  vitals.thermalState = "serious"
        case .critical: vitals.thermalState = "critical"
        @unknown default: vitals.thermalState = "unknown"
        }

        let disk = diskUsage()
        vitals.diskTotalBytes = disk.total
        vitals.diskUsedBytes = disk.used


        return vitals
    }

    /// Nil on a desktop with no battery, which is a real answer rather than 0%.
    private func batteryState() -> (percent: Double?, charging: Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, false) }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            return (Double(current) / Double(max) * 100, charging)
        }
        return (nil, false)
    }

    /// Sums the byte counters of physical interfaces and differences them
    /// against the previous sample. Counters are cumulative since boot, so the
    /// rate is only meaningful once there are two readings.
    private func networkThroughput() -> (inBps: Double?, outBps: Double?) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (nil, nil) }
        defer { freeifaddrs(head) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: interface.ifa_name)
            // Skip loopback and virtual interfaces; they double-count traffic.
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            guard let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            totalIn += UInt64(data.pointee.ifi_ibytes)
            totalOut += UInt64(data.pointee.ifi_obytes)
        }

        let now = Date()
        lock.lock()
        defer {
            previousNetwork = (totalIn, totalOut, now)
            lock.unlock()
        }
        guard let previous = previousNetwork else { return (nil, nil) }
        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed > 0.2 else { return (nil, nil) }
        // Counters wrap and interfaces come and go, so a negative delta is
        // reported as no reading rather than a nonsense spike.
        guard totalIn >= previous.inBytes, totalOut >= previous.outBytes else { return (nil, nil) }
        return (Double(totalIn - previous.inBytes) / elapsed,
                Double(totalOut - previous.outBytes) / elapsed)
    }

    /// Cached because it is far more expensive than it looks:
    /// `volumeAvailableCapacityForImportantUsage` asks the system to compute
    /// purgeable space, which goes out to the CacheDelete service and can take
    /// most of a second. Called once a frame it pins the main thread and
    /// starves everything else the app is trying to do. Free space does not
    /// meaningfully change second to second, so it is read on a slow interval.
    private func diskUsage() -> (used: Int64, total: Int64) {
        lock.lock()
        if let cached = cachedDisk, Date().timeIntervalSince(cached.at) < diskCacheSeconds {
            lock.unlock()
            return (cached.used, cached.total)
        }
        lock.unlock()

        var used: Int64 = 0
        var total: Int64 = 0
        if let usage = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        ) {
            total = Int64(usage.volumeTotalCapacity ?? 0)
            used = max(0, total - (usage.volumeAvailableCapacityForImportantUsage ?? 0))
        }

        lock.lock()
        cachedDisk = (used, total, Date())
        lock.unlock()
        return (used, total)
    }

    private func cpuUsagePercent() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let user = info.cpu_ticks.0, system = info.cpu_ticks.1
        let idle = info.cpu_ticks.2, nice = info.cpu_ticks.3

        lock.lock()
        defer {
            previousTicks = (user, system, idle, nice)
            lock.unlock()
        }
        guard let previous = previousTicks else { return 0 }

        let busyDelta = Double((user &- previous.user) + (system &- previous.system) + (nice &- previous.nice))
        let idleDelta = Double(idle &- previous.idle)
        let total = busyDelta + idleDelta
        guard total > 0 else { return 0 }
        return min(100, busyDelta / total * 100)
    }

    /// Matches what Activity Monitor calls memory pressure: everything the
    /// kernel cannot hand back on demand. Purgeable and file-backed pages are
    /// excluded, so this does not read as "16 GB used" the moment you open a
    /// browser the way a naive wired+active sum does.
    private func memoryUsedBytes() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = Int64(vm_kernel_page_size)
        let active = Int64(stats.active_count)
        let wired = Int64(stats.wire_count)
        let compressed = Int64(stats.compressor_page_count)
        return (active + wired + compressed) * pageSize
    }
}
