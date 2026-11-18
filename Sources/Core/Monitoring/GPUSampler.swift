import Foundation
import IOKit

/// GPU telemetry read straight out of the IORegistry.
///
/// Apple's accelerator drivers publish a `PerformanceStatistics` dictionary on
/// every `IOAccelerator` — utilisation, temperature, power, clocks and VRAM
/// counters — which is readable without root. That covers Intel, AMD and
/// Apple Silicon GPUs, including the `AMDRadeonX6000` driver most
/// Hackintoshes rely on, so no `powermetrics` helper or privileged listener is
/// needed.
///
/// Each accelerator belongs to exactly one physical GPU, and a machine can
/// expose several (an iGPU next to a dGPU). Readings are therefore taken per
/// device and never merged; the panel lets the user pick which GPU a card
/// shows, one at a time.
public final class GPUSampler {
    public init() {}

    /// All detected GPUs, discrete first, so index 0 is the sensible default.
    public func readAll() -> [GPUSnapshot] {
        let devices = Self.devices()
        guard !devices.isEmpty else {
            var snapshot = GPUSnapshot()
            snapshot.name = Self.fallbackName
            snapshot.vendor = Self.fallbackVendor
            return [snapshot]
        }
        return devices.sorted {
            let left = Self.priority($0), right = Self.priority($1)
            return left == right ? $0.id < $1.id : left > right
        }
    }

    public func read() -> GPUSnapshot {
        readAll().first ?? GPUSnapshot()
    }

    // MARK: - Per-device sampling

    private static func devices() -> [GPUSnapshot] {
        var result: [GPUSnapshot] = []
        var iterator: io_iterator_t = 0

        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == kIOReturnSuccess else { return result }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let statistics = dictionary["PerformanceStatistics"] as? [String: Any]
            else { continue }

            var snapshot = GPUSnapshot()
            let identity = deviceIdentity(for: service)
            snapshot.id = identity.id
            snapshot.name = identity.name
            snapshot.vendor = identity.vendor
            snapshot.isIntegrated = identity.isIntegrated

            let mainUtil = number(statistics["Device Utilization %"])
                ?? number(statistics["GPU Activity(%)"])
            let unitUtils = (0...3).compactMap { number(statistics["Device Unit \($0) Utilization %"]) }
            let maxUnit = unitUtils.max()
            if let mainUtil, let maxUnit {
                snapshot.utilization = max(mainUtil, maxUnit)
            } else {
                snapshot.utilization = mainUtil ?? maxUnit
            }

            snapshot.temperatureC = number(statistics["Temperature(C)"])
            snapshot.powerW = number(statistics["Total Power(W)"])
            snapshot.coreClockMHz = number(statistics["Core Clock(MHz)"])
            snapshot.memoryClockMHz = number(statistics["Memory Clock(MHz)"])
            // >= 0: the keys stay published at zero-RPM idle, and their presence
            // is what proves the fan is populated.
            snapshot.fanPercent = number(statistics["Fan Speed(%)"]).flatMap { $0 >= 0 ? $0 : nil }
            snapshot.fanRPM = number(statistics["Fan Speed(RPM)"]).flatMap { $0 >= 0 ? $0 : nil }

            let used = number(statistics["inUseVidMemoryBytes"]) ?? 0
            let cached = number(statistics["orphanedReusableVidMemoryBytes"]) ?? 0
            let free = number(statistics["vramFreeBytes"]) ?? 0
            if used > 0 || free > 0 {
                snapshot.vramUsedBytes = used
                snapshot.vramCachedBytes = cached
                snapshot.vramFreeBytes = free
                let total = used + cached + free
                snapshot.vramTotalBytes = total
                snapshot.memoryUtilization = total > 0 ? (used / total) * 100 : 0
            } else {
                // Integrated GPU (Intel UHD/HD or unified memory)
                let sysUsed = number(statistics["inUseSysMemoryBytes"])
                    ?? number(statistics["gartUsedBytes"])
                    ?? 0
                let sysCached = number(statistics["orphanedReusableSysMemoryBytes"]) ?? 0

                let totalMB = number(dictionary["VRAM,totalMB"])
                    ?? number(property(service, "VRAM,totalMB"))
                    ?? identity.vramTotalMB

                if let totalMB, totalMB > 0 {
                    let totalBytes = totalMB * 1024 * 1024
                    snapshot.vramTotalBytes = totalBytes
                    snapshot.vramUsedBytes = sysUsed
                    snapshot.vramCachedBytes = sysCached
                    snapshot.vramFreeBytes = max(0, totalBytes - sysUsed)
                    snapshot.memoryUtilization = totalBytes > 0 ? (sysUsed / totalBytes * 100) : 0
                } else if let gartTotal = number(statistics["gartSizeBytes"]), gartTotal > 0 {
                    snapshot.vramTotalBytes = gartTotal
                    snapshot.vramUsedBytes = sysUsed
                    snapshot.vramCachedBytes = sysCached
                    snapshot.vramFreeBytes = max(0, gartTotal - sysUsed)
                    snapshot.memoryUtilization = (sysUsed / gartTotal) * 100
                } else if sysUsed > 0 {
                    snapshot.vramUsedBytes = sysUsed
                }
            }

            // Fallback telemetry from AppleSMC for integrated GPUs or drivers without IORegistry stats
            if snapshot.isIntegrated || snapshot.vendor == "Intel" {
                _ = SMCClient.shared.open()
                // Power: Intel Processor Graphics Core (PCGC) or Measured (PCGM)
                if snapshot.powerW == nil {
                    if let power = SMCClient.shared.read("PCGC")?.number, power >= 0 {
                        snapshot.powerW = power
                    } else if let power = SMCClient.shared.read("PCGM")?.number, power >= 0 {
                        snapshot.powerW = power
                    }
                }
                // Temperature: Intel iGPU shares thermal package with CPU die.
                // Check TC0G first (dedicated iGPU sensor), then TC0P (package) or TC0D (die).
                if snapshot.temperatureC == nil {
                    if let igpuTemp = SMCClient.shared.read("TC0G")?.number, igpuTemp >= 20, igpuTemp <= 120 {
                        snapshot.temperatureC = igpuTemp
                    } else if let pkgTemp = SMCClient.shared.read("TC0P")?.number, pkgTemp >= 20, pkgTemp <= 120 {
                        snapshot.temperatureC = pkgTemp
                    } else if let dieTemp = SMCClient.shared.read("TC0D")?.number, dieTemp >= 20, dieTemp <= 120 {
                        snapshot.temperatureC = dieTemp
                    }
                }
            }

            snapshot.isSupported = true
            result.append(snapshot)
        }
        return result
    }

    /// Discrete GPUs beat integrated ones, then breadth of telemetry breaks
    /// ties, so an enabled iGPU never displaces the card that is actually
    /// driving the display.
    private static func priority(_ gpu: GPUSnapshot) -> Int {
        var score = (gpu.isIntegrated || gpu.vendor == "Intel") ? 0 : 2
        if gpu.temperatureC != nil { score += 1 }
        if gpu.fanRPM != nil { score += 1 }
        if gpu.vramTotalBytes != nil { score += 1 }
        return score
    }

    // MARK: - Naming

    /// The accelerator node itself carries no marketing name; its PCI parent
    /// does. PCI class `03.00.00` marks a display controller. The registry
    /// entry ID of that parent identifies the device across samples.
    private static func deviceIdentity(for service: io_registry_entry_t)
        -> (id: String, name: String, vendor: String?, vramTotalMB: Double?, isIntegrated: Bool) {
        var serviceID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &serviceID)
        let fallbackID = "gpu-\(serviceID)"

        var entry = service
        IOObjectRetain(entry)
        defer { IOObjectRelease(entry) }

        for _ in 0..<10 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == kIOReturnSuccess,
                  parent != 0 else { return (fallbackID, "GPU", nil, nil, false) }
            IOObjectRelease(entry)
            entry = parent

            guard let classCode = property(entry, "class-code") as? Data,
                  classCode.count >= 3,
                  // Stored little-endian: prog-if, subclass, then base class 0x03.
                  classCode[2] == 0x03
            else { continue }

            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &registryID)
            let id = "gpu-\(registryID)"
            let vendor = vendorName(property(entry, "vendor-id"))
            let totalMB = number(property(entry, "VRAM,totalMB"))
                ?? number(property(entry, "VRAM,totalsize"))
            let hasPlatformID = property(entry, "AAPL,ig-platform-id") != nil
                || property(service, "AAPL,ig-platform-id") != nil

            var modelName: String?
            if let string = property(entry, "model") as? String {
                modelName = string
            } else if let data = property(entry, "model") as? Data,
               let decoded = String(data: data, encoding: .ascii), !decoded.isEmpty {
                modelName = decoded.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            }
            let name = modelName ?? "GPU"
            let isIntegrated = vendor == "Intel"
                || hasPlatformID
                || name.contains("Intel")
                || name.contains("UHD")
                || name.contains("HD Graphics")
                || name.contains("Iris")

            return (id, name, vendor, totalMB, isIntegrated)
        }
        return (fallbackID, "GPU", nil, nil, false)
    }

    private static func vendorName(_ value: Any?) -> String? {
        guard let data = value as? Data, data.count >= 2 else { return nil }
        let id = Int(data.withUnsafeBytes { UInt32($0.loadUnaligned(as: UInt32.self)) & 0xffff })
        switch id {
        case 0x1002: return "AMD"
        case 0x10de: return "NVIDIA"
        case 0x8086: return "Intel"
        case 0x106b: return "Apple"
        default: return String(format: "Vendor 0x%04x", id)
        }
    }

    /// No accelerator at all (driver missing or unsupported GPU): fall back to
    /// the firmware's name on the first display-controller PCI function.
    private static let fallbackInfo: (model: String?, vendor: String?) = {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOPCIDevice"),
                                           &iterator) == kIOReturnSuccess else { return (nil, nil) }
        defer { IOObjectRelease(iterator) }

        var model: String?
        var vendor: String?

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }

            guard let classCode = property(service, "class-code") as? Data,
                  classCode.count >= 3,
                  classCode[2] == 0x03
            else { continue }

            // A function without an injected `model` is an HD-audio endpoint or
            // a spare port on the same card, not the GPU itself.
            guard property(service, "model") != nil else { continue }

            if model == nil {
                if let string = property(service, "model") as? String { model = string }
                else if let data = property(service, "model") as? Data, let decoded = String(data: data, encoding: .ascii) {
                    model = decoded
                }
            }
            if vendor == nil { vendor = vendorName(property(service, "vendor-id")) }
        }
        return (model, vendor)
    }()

    private static var fallbackName: String { fallbackInfo.model ?? "GPU" }
    private static var fallbackVendor: String? { fallbackInfo.vendor }

    private static func property(_ service: io_registry_entry_t, _ name: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return Double(truncating: number) }
        if let string = value as? String, let parsed = Double(string) { return parsed }
        if let data = value as? Data {
            if data.count == 4 {
                let val = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                return Double(val)
            } else if data.count == 8 {
                let val = data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                return Double(val)
            }
        }
        return nil
    }
}