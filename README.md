# GlassMonitor

macOS 26 菜单栏硬件监控，Liquid Glass 风格的弹出面板。为黑苹果与 Mac 设计，全部传感器数据无需 root 即可读取。

## 功能

- **菜单栏分组读数**：每个硬件域使用一个图标（CPU / GPU / 内存 / 网络），温度与占用靠单位区分（`°C` / `%`），可自由多选；数值使用等宽字体与固定宽度，读数变化时图标宽度不跳动。
- **四张等宽玻璃卡片**：CPU、GPU、内存、网络，行列高度严格一致。
- **CPU**：总占用、每核心负载、温度、最忙核心、CPU 风扇转速、基础频率 ~ 最大睿频。风扇由 SMCSuperIO 自动识别，无需手动配置。
- **GPU**：占用、温度、功耗、风扇、显存、核心/显存频率与实时曲线。每张卡任一时刻只显示一块 GPU 的真实数据；多 GPU 机器（例如 UHD 630 + RX 6900 XT）可在卡片标题处下拉切换，默认独显，各 GPU 的曲线历史独立保存，菜单栏同步跟随。
- **内存**：压力、已用/总量、应用/联动/压缩/缓存构成、压缩率与交换空间。
- **网络**：上下行速率、会话累计流量、当前活动网卡与吞吐曲线。
- **偏好**：曲线窗口（1 / 3 / 5 分钟）、刷新间隔（1–5 秒）、显示每核心负载、开机自启（`SMAppService`，无需辅助进程或 root）。

## 数据来源

| 指标 | 来源 |
| --- | --- |
| GPU 全部指标 | `IOAccelerator` → `PerformanceStatistics`（逐设备采样，不合并） |
| CPU 温度 / 风扇 | AppleSMC、SMCSuperIO `Sensors` 通道（CPUFAN / SYSFAN / AUXFAN…） |
| 内存与交换 | Mach `host_statistics64`、`sysctl vm.swapusage` |
| 网络 | `getifaddrs` 字节计数差分 |
| CPU 基础频率 / 睿频上限 | `sysctl hw.cpufrequency` 与固件 P-State 表 |

### 诚实的限制

- 应用不使用 root、不安装特权驱动，因此**无法读取 Intel CPU 的实时全核频率**（需要内核读 MSR）。CPU 卡片显示的是固件声明的基础频率与最大睿频区间，而不是实时值。
- 实时核心频率、部分 SMC 键、某些主板的风扇通道是否可用，取决于机型、EFI 与已安装的 kext；缺失的传感器显示 `—`，不会伪造数值。
- 不使用任何模拟或占位数据，也不会把多块 GPU 的数据混在同一张卡里。

## 构建

需要 macOS 26 与 Xcode 26 Command Line Tools（Swift 6.2）。无需 Xcode 工程文件。

```bash
bash Scripts/build.sh release
open build/GlassMonitor.app
```

脚本会完成 release 构建、生成 `build/GlassMonitor.app`、用 `Resources/AppIcon.png` 生成 `AppIcon.icns`，并进行 ad-hoc 签名。

诊断传感器可用：

```bash
swift run -c release sysdump
```

## 许可

[MIT](LICENSE)