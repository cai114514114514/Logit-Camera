import SwiftUI

struct ApertureControls: View {
    let state: CameraState
    let onAperture: (Float?) -> Void
    let onBias: (Float) -> Void
    @State private var draftBias: Float = 0
    @State private var editingBias = false
    @State private var draftAperture: Float = 2.8

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("光圈优先").font(.subheadline.weight(.semibold))
                    Spacer()
                    if state.isApplying {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(state.selectedAperture.map { "目标 " + CameraText.aperture($0) } ?? "系统自动")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                // Adaptive columns keep every calibrated stop large enough to tap.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 8) {
                    apertureButton("自动", value: nil)
                    if let range = state.apertureRange, range.isVariable {
                        ForEach(range.stops, id: \.self) { aperture in
                            apertureButton(CameraText.aperture(aperture), value: aperture)
                        }
                    }
                }

                if let range = state.apertureRange, range.isVariable, range.stops.isEmpty {
                    // Some formats expose a continuous range without calibrated stops.
                    Slider(value: $draftAperture, in: range.minimum...range.maximum) { editing in
                        if !editing { onAperture(draftAperture) }
                    }
                    .disabled(!state.canAdjust)
                    .accessibilityLabel("目标光圈")
                }

                if !state.supportsAperturePriority && state.phase == .ready {
                    Text("当前设备不支持硬件光圈调节")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 8) {
                HStack {
                    Label("曝光补偿", systemImage: "sun.max")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(String(format: "%+.1f EV", draftBias))
                        .font(.system(size: 12, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if state.minimumBias < state.maximumBias {
                    Slider(value: $draftBias, in: state.minimumBias...state.maximumBias, step: 0.1) { editing in
                        editingBias = editing
                        if !editing { onBias(draftBias) }
                    }
                    .disabled(!state.canCapture)
                    .accessibilityLabel("曝光补偿")
                }
            }
        }
        .onAppear {
            draftBias = state.exposureBias
            updateDraftAperture()
        }
        .onChange(of: state.exposureBias) { _, value in
            if !editingBias { draftBias = value }
        }
        .onChange(of: state.selectedAperture) { _, _ in updateDraftAperture() }
    }

    private func updateDraftAperture() {
        let value = state.selectedAperture ?? state.aperture ?? 2.8
        if let range = state.apertureRange {
            draftAperture = min(range.maximum, max(range.minimum, value))
        } else {
            draftAperture = value
        }
    }

    private func apertureButton(_ title: String, value: Float?) -> some View {
        let selected = state.selectedAperture == value
        return Button { onAperture(value) } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(selected ? Color.yellow : .white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(selected ? .black : .white)
        }
        .disabled(value == nil ? !state.canCapture : !state.canAdjust)
        .accessibilityLabel(value.map { "光圈 " + CameraText.aperture($0) } ?? "自动光圈")
        .accessibilityIdentifier(value.map { "aperture.\($0)" } ?? "aperture.auto")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
