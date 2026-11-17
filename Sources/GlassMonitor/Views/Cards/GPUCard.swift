import SwiftUI
import Core

struct GPUCard: View {
    let gpus: [GPUSnapshot]
    @Binding var selection: String?
    let usageHistory: [String: [Double]]
    var tempHistory: [String: [Double]] = [:]

    /// One GPU at a time: every field and both curves come from the device
    /// selected here, never from a mixture of accelerators.
    private var gpu: GPUSnapshot {
        gpus.first { $0.id == selection } ?? gpus.first ?? GPUSnapshot()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            HStack(alignment: .center, spacing: 10) {
                UsageRing(percent: gpu.utilization ?? 0, color: Accent.gpu,
                          label: "\(Num.percent(gpu.utilization))%")
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    MetricRow(label: "温度", value: Num.celsius(gpu.temperatureC))
                    MetricRow(label: "功耗", value: Num.watts(gpu.powerW))
                    MetricRow(label: "风扇", value: fanText)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("显存").font(.mono(11)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(vramText).font(.mono(11, .medium))
                    }
                    LevelBar(fraction: vramFraction, color: Accent.gpu)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        MiniLegend(color: Accent.gpu,
                                   text: "占用 \(Num.percent(gpu.utilization))%")
                        MiniLegend(color: Accent.thermal,
                                   text: "温度 \(Num.degrees(gpu.temperatureC))")
                        Spacer(minLength: 6)
                        Text(Num.megahertz(gpu.coreClockMHz))
                            .font(.mono(9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    DualSparkline(usage: usageHistory[gpu.id] ?? [],
                                  temperature: tempHistory[gpu.id] ?? [],
                                  usageColor: Accent.gpu)
                        .frame(height: 30)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .glassCard(Accent.gpu)
    }

    /// With a second GPU the title becomes a pop-up list of devices; with one
    /// GPU it stays a plain header so the usual layout is untouched.
    @ViewBuilder private var header: some View {
        if gpus.count > 1 {
            Menu {
                ForEach(gpus) { candidate in
                    Toggle(candidate.displayName, isOn: Binding(
                        get: { candidate.id == gpu.id },
                        set: { _ in selection = candidate.id }))
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "display")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Accent.gpu)
                    Text(gpu.displayName).font(.mono(12, .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            CardHeader(title: gpu.displayName, systemImage: "display", tint: Accent.gpu)
        }
    }

    private var fanText: String {
        guard let rpm = gpu.fanRPM else { return "—" }
        return rpm > 0 ? "\(Int(rpm.rounded())) RPM" : "停转"
    }

    private var vramFraction: Double {
        guard let total = gpu.vramTotalBytes, total > 0, let used = gpu.vramUsedBytes else { return 0 }
        return used / total
    }

    private var vramText: String {
        guard let used = gpu.vramUsedBytes, let total = gpu.vramTotalBytes else { return "—" }
        return "\(ByteFormat.string(used)) / \(ByteFormat.string(total))"
    }
}