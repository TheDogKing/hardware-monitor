import SwiftUI
import Core

struct MemoryCard: View {
    let snapshot: SystemSnapshot
    let history: [Double]

    private var memory: MemorySnapshot { snapshot.memory }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: "内存", systemImage: "memorychip", tint: Accent.memory)

            HStack(alignment: .center, spacing: 10) {
                UsageRing(percent: memory.pressurePercent, color: Accent.memory,
                          label: "\(Num.percent(memory.pressurePercent))%")
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    MetricRow(label: "已用", value: ByteFormat.string(memory.usedBytes))
                    MetricRow(label: "总量", value: ByteFormat.string(memory.totalBytes))
                    MetricRow(label: "压缩", value: compressionText)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                SegmentedBar(segments: [
                    (memory.appBytes, Color(red: 0.98, green: 0.76, blue: 0.44)),
                    (memory.wiredBytes, Color(red: 0.94, green: 0.56, blue: 0.42)),
                    (memory.compressedBytes, Color(red: 0.78, green: 0.44, blue: 0.72)),
                    (memory.cachedBytes, Color(red: 0.55, green: 0.72, blue: 0.55)),
                ])
                .frame(height: 6)

                HStack(spacing: 8) {
                    Legend(color: Color(red: 0.98, green: 0.76, blue: 0.44), text: "应用")
                    Legend(color: Color(red: 0.94, green: 0.56, blue: 0.42), text: "联动")
                    Legend(color: Color(red: 0.78, green: 0.44, blue: 0.72), text: "已压缩")
                    Legend(color: Color(red: 0.55, green: 0.72, blue: 0.55), text: "缓存")
                }
                .font(.mono(9))
                .foregroundStyle(.secondary)

                Sparkline(values: history, color: Accent.memory, ceiling: 100)
                    .frame(height: 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .glassCard(Accent.memory)
    }

    private var compressionText: String {
        guard let ratio = memory.compressionRatio, ratio > 1.01 else {
            return ByteFormat.string(memory.compressedBytes)
        }
        return String(format: "%.1f× · ", ratio) + ByteFormat.string(memory.compressedBytes)
    }
}

/// A proportional strip, the way Activity Monitor draws memory pressure.
struct SegmentedBar: View {
    let segments: [(Double, Color)]

    var body: some View {
        GeometryReader { proxy in
            let total = segments.reduce(0) { $0 + $1.0 }
            HStack(spacing: 1.5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    if segment.0 > 0 {
                        Capsule()
                            .fill(segment.1)
                            .frame(width: max(2, proxy.size.width * CGFloat(segment.0 / max(total, 1))))
                    }
                    if index == segments.count - 1 {
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Legend: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
        }
    }
}
