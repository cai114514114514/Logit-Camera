import CameraCore
import SwiftUI

/// 快门上方展开的手动拨盘：光圈档位与 EV 刻度尺。取景画面始终可见。
struct ManualDial: View {
    let model: CameraModel
    @State private var mode: Mode = .aperture
    @State private var draftBias: Float = 0
    @State private var editingBias = false
    @State private var draftAperture: Float = 2.8

    enum Mode: String, CaseIterable { case aperture = "光圈", bias = "曝光" }

    private var state: CameraState { model.state }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 18) {
                ForEach(Mode.allCases, id: \.self) { item in
                    Button { mode = item } label: {
                        VStack(spacing: 4) {
                            Text(item.rawValue).font(.system(.caption, weight: .semibold))
                                .foregroundStyle(mode == item ? Theme.Palette.ink : Theme.Palette.inkTertiary)
                            Rectangle().fill(mode == item ? Theme.Palette.ink : .clear).frame(width: 14, height: 1.5)
                        }
                        .frame(minHeight: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(mode == item ? .isSelected : [])
                    .accessibilityIdentifier("dial.\(item == .aperture ? "aperture" : "bias")")
                }
                Spacer()
                if state.isApplying { ProgressView().controlSize(.mini) }
                Button("全部自动", action: model.resetCamera)
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(Theme.Palette.inkSecondary)
                    .disabled(!state.canCapture)
                    .frame(minHeight: 32)
                    .accessibilityLabel("恢复自动光圈、自动对焦和零曝光补偿")
            }
            .padding(.horizontal, Theme.Metric.gutter)

            switch mode {
            case .aperture: apertureRow
            case .bias: biasRuler.padding(.horizontal, Theme.Metric.gutter + 6)
            }
        }
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(Theme.Palette.hairline).frame(height: 1) }
        .hudTypeSize()
        .onAppear {
            draftBias = state.exposureBias
            syncDraftAperture()
        }
        .onChange(of: state.exposureBias) { _, value in if !editingBias { draftBias = value } }
        .onChange(of: state.selectedAperture) { _, _ in syncDraftAperture() }
    }

    // MARK: Aperture

    @ViewBuilder private var apertureRow: some View {
        if !state.supportsAperturePriority && state.phase == .ready {
            Text("当前设备不支持硬件光圈调节")
                .font(Theme.Typeface.body).foregroundStyle(Theme.Palette.inkSecondary)
                .frame(minHeight: 44)
        } else if let range = state.apertureRange, range.isVariable, range.stops.isEmpty {
            // 部分格式只提供连续范围、没有推荐档位。
            Slider(value: $draftAperture, in: range.minimum...range.maximum) { editing in
                if !editing { model.setAperture(draftAperture) }
            }
            .disabled(!state.canAdjust)
            .accessibilityLabel("目标光圈")
            .padding(.horizontal, Theme.Metric.gutter)
        } else {
            ViewThatFits(in: .horizontal) {
                stopButtons
                ScrollView(.horizontal, showsIndicators: false) { stopButtons }
            }
        }
    }

    private var stopButtons: some View {
        HStack(spacing: 4) {
            stopButton("自动", value: nil)
            if let range = state.apertureRange, range.isVariable {
                ForEach(range.stops, id: \.self) { stopButton(CameraText.aperture($0), value: $0) }
            }
        }
        .padding(.horizontal, Theme.Metric.gutter - 4)
    }

    private func stopButton(_ title: String, value: Float?) -> some View {
        let selected = state.selectedAperture == value
        let color = selected ? Theme.color(for: model.origin(isManual: value != nil)) : Theme.Palette.inkSecondary
        return Button { model.setAperture(value) } label: {
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(.footnote, design: .monospaced, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize()
                Rectangle().fill(selected ? color : Theme.Palette.hairline)
                    .frame(width: selected ? 18 : 1, height: selected ? 2 : 6)
            }
            .foregroundStyle(color)
            .frame(minWidth: 52, minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(value == nil ? !state.canCapture : !state.canAdjust)
        .accessibilityLabel(value.map { "光圈 " + CameraText.aperture($0) } ?? "自动光圈")
        .accessibilityIdentifier(value.map { "aperture.\($0)" } ?? "aperture.auto")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func syncDraftAperture() {
        let value = state.selectedAperture ?? state.aperture ?? 2.8
        guard let range = state.apertureRange else { draftAperture = value; return }
        draftAperture = min(range.maximum, max(range.minimum, value))
    }

    // MARK: Exposure bias

    private var biasRuler: some View {
        let lower = state.minimumBias, upper = state.maximumBias
        return GeometryReader { geometry in
            let width = geometry.size.width
            let position = upper > lower ? CGFloat((draftBias - lower) / (upper - lower)) * width : width / 2
            ZStack(alignment: .topLeading) {
                ForEach(Array(stride(from: lower, through: upper + 0.001, by: 0.1).enumerated()), id: \.offset) { _, tick in
                    let major = abs(tick - tick.rounded()) < 0.01
                    Rectangle()
                        .fill(major ? Theme.Palette.inkSecondary : Theme.Palette.hairline)
                        .frame(width: 1, height: major ? 12 : 6)
                        .position(x: CGFloat((tick - lower) / (upper - lower)) * width, y: 22)
                    if major {
                        Text(tick == 0 ? "0" : String(format: "%+.0f", tick))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Theme.Palette.inkTertiary)
                            .position(x: CGFloat((tick - lower) / (upper - lower)) * width, y: 38)
                    }
                }
                Rectangle().fill(Theme.Palette.ink).frame(width: 2, height: 22)
                    .position(x: position, y: 20)
                Text(CameraText.bias(draftBias))
                    .font(.system(.caption2, design: .monospaced, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .position(x: min(max(position, 18), width - 18), y: 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    editingBias = true
                    let fraction = Float(min(max(gesture.location.x / width, 0), 1))
                    let snapped = ((lower + fraction * (upper - lower)) * 10).rounded() / 10
                    if snapped != draftBias { draftBias = snapped }
                }
                .onEnded { _ in
                    editingBias = false
                    model.setExposureBias(draftBias)
                })
        }
        .frame(height: 46)
        .disabled(!state.canCapture || !(lower < upper))
        .sensoryFeedback(.selection, trigger: draftBias)
        .accessibilityRepresentation {
            Slider(value: $draftBias, in: lower...max(upper, lower + 0.1), step: 0.1) {
                Text("曝光补偿")
            } onEditingChanged: { editing in
                editingBias = editing
                if !editing { model.setExposureBias(draftBias) }
            }
        }
        .accessibilityIdentifier("dial.biasRuler")
    }
}
