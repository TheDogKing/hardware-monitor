import SwiftUI
import AppKit
import Core

/// The card stack shown inside the menu bar popover.
struct PanelBody: View {
    let snapshot: SystemSnapshot
    var histories = PanelBody.Histories()
    var interval: TimeInterval = 2
    @EnvironmentObject private var settings: AppSettings

    struct Histories {
        var cpu: [Double] = []
        var gpu: [String: [Double]] = [:]
        var memory: [Double] = []
        var download: [Double] = []
        var upload: [Double] = []
        var cpuTemp: [Double] = []
        var gpuTemp: [String: [Double]] = [:]
    }

    var body: some View {
        GlassEffectContainer(spacing: Panel.spacing) { cards }
    }

    @ViewBuilder private var cards: some View {
        let histories = windowed
        VStack(alignment: .leading, spacing: Panel.spacing) {
            header
            EqualHeightRow(spacing: Panel.spacing, cardWidth: Panel.cardWidth) {
                CPUCard(snapshot: snapshot, history: histories.cpu,
                        tempHistory: histories.cpuTemp,
                        showsPerCore: settings.showsPerCore)
                GPUCard(gpus: displayedGPUs, selection: $settings.selectedGPU,
                        usageHistory: histories.gpu, tempHistory: histories.gpuTemp)
            }
            EqualHeightRow(spacing: Panel.spacing, cardWidth: Panel.cardWidth) {
                MemoryCard(snapshot: snapshot, history: histories.memory)
                NetworkCard(snapshot: snapshot.network,
                            download: histories.download, upload: histories.upload)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(DeviceInfo.shared.shortCPUName)
                    .font(.mono(12, .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.mono(9))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Text(Num.celsius(snapshot.hottest))
                .font(.mono(12, .medium))
                .foregroundStyle(Accent.thermal)

            Menu {
                Section("菜单栏显示（可多选）") {
                    ForEach(MenuBarItem.allCases) { item in
                        Toggle(item.title, isOn: Binding(
                            get: { settings.menuBarItems.contains(item) },
                            set: { on in
                                if on { settings.menuBarItems.insert(item) }
                                else { settings.menuBarItems.remove(item) }
                            }))
                    }
                }

                Picker("曲线窗口", selection: $settings.curveMinutes) {
                    Text("最近 1 分钟").tag(1.0)
                    Text("最近 3 分钟").tag(3.0)
                    Text("最近 5 分钟").tag(5.0)
                }
                .pickerStyle(.inline)

                Picker("刷新间隔", selection: $settings.interval) {
                    Text("每 1 秒").tag(1.0)
                    Text("每 2 秒").tag(2.0)
                    Text("每 3 秒").tag(3.0)
                    Text("每 5 秒").tag(5.0)
                }
                .pickerStyle(.inline)

                Toggle("显示每核心负载", isOn: $settings.showsPerCore)

                Toggle("开机自启", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))

                Divider()

                Button("退出玻璃监控") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .controlSize(.small)
        .buttonStyle(.glass)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
    }

    private var subtitle: String {
        let info = DeviceInfo.shared
        return [info.macModel,
                ByteFormat.string(info.memoryBytes),
                info.isHackintosh ? "Hackintosh" : "Mac",
                snapshot.network.activeInterface ?? "—"]
            .joined(separator: " · ")
    }

    /// One card per GPU, not per accelerator: when no accelerator answered, the
/// fallback identity is still shown as the only card.
    private var displayedGPUs: [GPUSnapshot] {
        snapshot.gpus.isEmpty ? [snapshot.gpu] : snapshot.gpus
    }

    /// Every strip chart shows the same recent window, chosen in the header menu.
    private var windowed: Histories {
        let count = max(2, Int((settings.curveMinutes * 60 / max(0.5, interval)).rounded()))
        func window(_ series: [Double]) -> [Double] { Array(series.suffix(count)) }
        return Histories(cpu: window(histories.cpu), gpu: histories.gpu.mapValues(window),
                         memory: window(histories.memory),
                         download: window(histories.download), upload: window(histories.upload),
                         cpuTemp: window(histories.cpuTemp), gpuTemp: histories.gpuTemp.mapValues(window))
    }
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct RootView: View {
    var maxHeight: CGFloat = .greatestFiniteMagnitude
    var onHeight: ((CGFloat) -> Void)? = nil
    @State private var measured: CGFloat?
    @EnvironmentObject private var monitor: HardwareMonitor
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ZStack {
            BlurBackground()

            ScrollView(.vertical) {
                panel.background(GeometryReader { proxy in
                    Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
                })
            }
            .frame(height: min(measured ?? maxHeight, maxHeight))
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onPreferenceChange(PanelHeightKey.self) { height in
            measured = height
            onHeight?(min(height, maxHeight))
        }
    }

    private var panel: some View {
        PanelBody(snapshot: monitor.snapshot, histories: .init(
            cpu: monitor.cpuHistory,
            gpu: monitor.gpuHistories,
            memory: monitor.memoryHistory,
            download: monitor.downloadHistory,
            upload: monitor.uploadHistory,
            cpuTemp: monitor.cpuTempHistory,
            gpuTemp: monitor.gpuTempHistories
        ), interval: monitor.interval)
        .environmentObject(settings)
        .padding(Panel.spacing)
    }
}