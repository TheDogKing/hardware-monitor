import Foundation
import Darwin
import IOKit

/// Per-core and aggregate CPU utilisation from `host_processor_info`.
///
/// The Mach counters are monotonically increasing ticks, so utilisation is a
/// delta between samples. The first call seeds the baseline and reports 0.
public final class CPUSampler {
    private struct Tick {
        var user: UInt32 = 0
        var nice: UInt32 = 0
        var system: UInt32 = 0
        var idle: UInt32 = 0
    }

    private let host = mach_host_self()
    private var previous: [Tick] = []

    public init() {}

    public func read() -> CPUSnapshot {
        var snapshot = CPUSnapshot()
        snapshot.physicalCount = Self.intSysctl("hw.physicalcpu") ?? 0
        snapshot.logicalCount = Self.intSysctl("hw.logicalcpu") ?? 0
        snapshot.frequencyGHz = Self.baseFrequencyGHz()
        snapshot.turboGHz = Self.turboGHz
        snapshot.loadAverage = Self.loadAverage()

        guard let ticks = sampleTicks() else { return snapshot }

        var totals: [Double] = [0, 0, 0]
        var cores: [CoreLoad] = []

        if previous.count == ticks.count {
            for index in 0..<ticks.count {
                let current = ticks[index]
                let last = previous[index]

                let userDelta = Double(current.user &- last.user) + Double(current.nice &- last.nice)
                let systemDelta = Double(current.system &- last.system)
                let idleDelta = Double(current.idle &- last.idle)
                let busy = userDelta + systemDelta
                let elapsed = max(busy + idleDelta, 1)

                let usage = busy / elapsed * 100
                cores.append(CoreLoad(id: index,
                                      usage: usage,
                                      user: userDelta / elapsed * 100,
                                      system: systemDelta / elapsed * 100))
                totals[0] += userDelta / elapsed * 100
                totals[1] += systemDelta / elapsed * 100
                totals[2] += usage
            }
        }

        previous = ticks

        let divisor = Double(max(cores.count, 1))
        snapshot.cores = cores
        if !cores.isEmpty {
            snapshot.totalUsage = totals[2] / divisor
            snapshot.user = totals[0] / divisor
            snapshot.system = totals[1] / divisor
            snapshot.idle = max(0, 100 - snapshot.totalUsage)
        }

        return snapshot
    }

    private func sampleTicks() -> [Tick]? {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO,
                                         &processorCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<Int32>.stride))
        }

        let values = UnsafeMutableRawPointer(info).assumingMemoryBound(to: Int32.self)
        let states = Int(CPU_STATE_MAX)

        var ticks: [Tick] = []
        ticks.reserveCapacity(Int(processorCount))
        for processor in 0..<Int(processorCount) {
            let base = processor * states
            guard base + states <= Int(infoCount) else { break }
            var tick = Tick()
            tick.user = UInt32(bitPattern: values[base + Int(CPU_STATE_USER)])
            tick.nice = UInt32(bitPattern: values[base + Int(CPU_STATE_NICE)])
            tick.system = UInt32(bitPattern: values[base + Int(CPU_STATE_SYSTEM)])
            tick.idle = UInt32(bitPattern: values[base + Int(CPU_STATE_IDLE)])
            ticks.append(tick)
        }
        return ticks
    }

    // MARK: - Helpers

    static func intSysctl(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            var value32: Int32 = 0
            var size32 = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &value32, &size32, nil, 0) == 0 else { return nil }
            return Int(value32)
        }
        return Int(value)
    }

    static func stringSysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// `hw.cpufrequency` is the platform's nominal base clock. The live core
    /// clock lives in an MSR and needs a privileged driver, so user space has
    /// no real-time reading (Windows tools run in the kernel to get one).
    private static func baseFrequencyGHz() -> Double? {
        guard let hz = intSysctl("hw.cpufrequency") else { return nil }
        return hz > 0 ? Double(hz) / 1_000_000_000 : nil
    }

    /// The firmware P-state table's first entry is the maximum turbo ratio the
    /// platform will ever grant — a ceiling, not a live clock.
    private static let turboGHz: Double? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("X86PlatformPlugin"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dictionary = properties?.takeRetainedValue() as? [String: Any],
              let states = dictionary["CPUPStates"] as? [[String: Any]],
              let first = states.first?["Frequency"] as? NSNumber
        else { return nil }
        let mhz = first.doubleValue
        return mhz > 0 ? mhz / 1000 : nil
    }()

    private static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return [] }
        return loads
    }
}
