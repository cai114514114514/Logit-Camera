import CameraCore
import SwiftUI

/// 顶部一行：画幅 ｜ 实时硬件读数 ｜ 手动拨盘与设置。
/// 读数颜色说明谁设定了它：AI 青色、用户白色、系统自动灰色。
struct HUDReadoutBar: View {
    let model: CameraModel
    @Binding var dialOpen: Bool

    private var state: CameraState { model.state }

    var body: some View {
        HStack(spacing: 8) {
            ratioMenu
            Spacer(minLength: 2)
            readout
                .contentShape(Rectangle())
                .onTapGesture { toggleDial() }
            Spacer(minLength: 2)
            iconButton("camera.filters", label: "滤镜", selected: model.showsLookStrip, action: toggleLooks)
                .accessibilityIdentifier("camera.looks")
            iconButton("dial.low", label: "手动光圈与曝光", selected: dialOpen, action: toggleDial)
                .accessibilityIdentifier("camera.controls")
            iconButton("gearshape", label: "设置", selected: false) { model.showsSettings = true }
                .accessibilityIdentifier("camera.aiSettings")
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.Metric.hudHeight)
        .hudTypeSize()
    }

    private func toggleDial() {
        withAnimation(.snappy(duration: 0.25)) {
            dialOpen.toggle()
            if dialOpen { model.showsLookStrip = false }
        }
    }

    private func toggleLooks() {
        withAnimation(.snappy(duration: 0.25)) {
            model.showsLookStrip.toggle()
            if model.showsLookStrip { dialOpen = false }
        }
    }

    private var readout: some View {
        HStack(spacing: 10) {
            Text(CameraText.aperture(state.aperture))
                .foregroundStyle(Theme.color(for: model.origin(isManual: state.selectedAperture != nil)))
                .accessibilityLabel(CameraText.aperture(state.aperture))
                .accessibilityHint("实际光圈")
                .accessibilityIdentifier("camera.aperture")
            value("ISO", state.iso.map { String(Int($0.rounded())) } ?? "—",
                  origin: model.origin(isManual: state.selectedISO != nil))
            value(nil, CameraText.shutter(state.exposureSeconds),
                  origin: model.origin(isManual: state.selectedShutter != nil))
            value("EV", CameraText.bias(state.exposureBias),
                  origin: model.origin(isManual: abs(state.exposureBias) >= 0.05))
        }
        .font(Theme.Typeface.readout)
        .contentTransition(.numericText())
        .animation(.snappy(duration: 0.2), value: state.aperture)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .contain)
    }

    private func value(_ label: String?, _ text: String, origin: ValueOrigin) -> some View {
        HStack(spacing: 3) {
            if let label {
                Text(label).font(Theme.Typeface.label).foregroundStyle(Theme.Palette.inkTertiary)
            }
            Text(text).foregroundStyle(Theme.color(for: origin))
        }
        .accessibilityElement(children: .combine)
    }

    private var ratioMenu: some View {
        Menu {
            Section(model.agent.isEnabled ? "AI 正在选择画幅 · 手动选择将停止 AI" : "照片画幅") {
                ForEach(FrameRatio.allCases) { ratio in
                    Button {
                        model.setRatio(ratio)
                    } label: {
                        if state.ratio == ratio {
                            Label(ratio.rawValue, systemImage: "checkmark")
                        } else {
                            Text(ratio.rawValue)
                        }
                    }
                    .accessibilityIdentifier("ratio.\(ratio.rawValue)")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(state.ratio.rawValue).font(Theme.Typeface.readoutLarge)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.Palette.inkTertiary)
            }
            .foregroundStyle(Theme.color(for: model.origin(isManual: state.ratio != .standard)))
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 44)
            .overlay(Capsule().stroke(Theme.Palette.hairline, lineWidth: 1).padding(.vertical, 6))
        }
        .accessibilityLabel("照片画幅")
        .accessibilityValue(state.ratio.rawValue)
        .accessibilityIdentifier("camera.ratio")
    }

    private func iconButton(_ symbol: String, label: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(selected ? Theme.Palette.ink : Theme.Palette.inkSecondary)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
