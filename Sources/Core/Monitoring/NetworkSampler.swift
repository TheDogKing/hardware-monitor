import Foundation
import Darwin
import SystemConfiguration

/// Throughput from `getifaddrs` link-layer byte counters.
///
/// The counters are cumulative since boot, so rates need a delta. They are
/// 32-bit on Intel Darwin, which wraps roughly every 34 s at gigabit — wrap is
/// detected and corrected so a busy interface cannot report a negative rate.
/// Because the raw counters themselves saturate, the totals this sampler
/// reports are accumulated from the corrected deltas rather than read out.
public final class NetworkSampler {
    private struct Counter {
        var received: UInt64
        var sent: UInt64
    }

    private var previous: [String: Counter] = [:]
    private var session: [String: Counter] = [:]
    private var lastSampleTime: Date?

    /// Tunnels and link-local adapters whose bytes already travelled over a
    /// physical NIC we also measure, so counting them would double the total.
    private static let doubleCountedPrefixes = ["utun", "ipsec", "ppp", "awdl", "llw", "bridge", "vlan", "gif", "stf", "anpi", "tun", "tap"]
    private static let ignoredPrefixes = ["lo", "pktap", "fwip", "ap1"]

    public init() {}

    public func read() -> NetworkSnapshot {
        var snapshot = NetworkSnapshot()
        let now = Date()
        let elapsed = lastSampleTime.map { now.timeIntervalSince($0) } ?? 0
        let counters = collectCounters()
        snapshot.activeInterface = Self.primaryInterfaceName()

        var interfaces: [NetworkInterfaceSample] = []
        var aggregateDownload = 0.0
        var aggregateUpload = 0.0
        var sessionIn = 0.0
        var sessionOut = 0.0

        for (name, counter) in counters.sorted(by: { $0.key < $1.key }) {
            if Self.ignoredPrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            let isDoubleCounted = Self.doubleCountedPrefixes.contains(where: { name.hasPrefix($0) })

            var download = 0.0
            var upload = 0.0
            var received = UInt64(0)
            var sent = UInt64(0)

            if let last = previous[name], elapsed > 0.05, !isDoubleCounted {
                received = delta(current: counter.received, previous: last.received)
                sent = delta(current: counter.sent, previous: last.sent)
                download = Double(received) / elapsed * 8
                upload = Double(sent) / elapsed * 8
                download = max(0, download)
                upload = max(0, upload)
                aggregateDownload += download
                aggregateUpload += upload

                let total = session[name] ?? Counter(received: 0, sent: 0)
                session[name] = Counter(received: total.received + received, sent: total.sent + sent)
            }

            let accumulated = session[name] ?? Counter(received: 0, sent: 0)
            sessionIn += Double(accumulated.received)
            sessionOut += Double(accumulated.sent)

            interfaces.append(NetworkInterfaceSample(
                name: name,
                downloadBps: download,
                uploadBps: upload,
                sessionInBytes: Double(accumulated.received),
                sessionOutBytes: Double(accumulated.sent),
                isActive: download > 8_000 || upload > 8_000
            ))
        }

        previous = counters
        lastSampleTime = now

        snapshot.downloadBps = aggregateDownload
        snapshot.uploadBps = aggregateUpload
        snapshot.interfaces = interfaces
        snapshot.sessionInBytes = sessionIn
        snapshot.sessionOutBytes = sessionOut

        return snapshot
    }

    private func delta(current: UInt64, previous: UInt64) -> UInt64 {
        guard current < previous else { return current - previous }
        // 32-bit rollover between samples.
        let wrap: UInt64 = 1 << 32
        return (wrap - previous) + current
    }

    private func collectCounters() -> [String: Counter] {
        var result: [String: Counter] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(first) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }

            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data else { continue }

            let name = String(cString: entry.pointee.ifa_name)
            let link = UnsafeRawPointer(data).assumingMemoryBound(to: if_data.self)
            let counter = Counter(received: UInt64(link.pointee.ifi_ibytes),
                                  sent: UInt64(link.pointee.ifi_obytes))

            // An interface can appear in more than one scan row; keep the largest.
            if let existing = result[name], existing.received >= counter.received { continue }
            result[name] = counter
        }
        return result
    }

    // MARK: - Default route

    /// The interface holding the primary IPv4 configuration, e.g. `en0`.
    static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "GlassMonitor.Network" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primary = value["PrimaryInterface"] as? String, !primary.isEmpty
        else { return nil }
        return primary
    }
}
