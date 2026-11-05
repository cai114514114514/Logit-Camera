import SwiftUI

struct CameraToolButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 44, height: 44)
                .foregroundStyle(.white)
                .background(.black.opacity(0.6), in: Circle())
        }
        .accessibilityLabel(label)
    }
}

struct CameraExposureReadout: View {
    let state: CameraState

    var body: some View {
        HStack(spacing: 12) {
            Text(CameraText.aperture(state.aperture))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.yellow)
                .accessibilityHint("实际光圈")
                .accessibilityIdentifier("camera.aperture")
            Spacer(minLength: 0)
            Text("ISO " + (state.iso.map { String(Int($0.rounded())) } ?? "—"))
            Text(CameraText.shutter(state.exposureSeconds))
            Text(state.zoom.formatted(.number.precision(.fractionLength(0...1))) + "×")
                .foregroundStyle(.yellow)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 4)
        .frame(minHeight: 28)
        .accessibilityElement(children: .contain)
    }
}

struct CameraAgentButton: View {
    let agent: CameraAgent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold))
                    Text("DeepSeek").font(.system(size: 12, weight: .bold))
                }
                Text(agent.isEnabled ? "AI 已开启" : "AI 关闭")
                    .font(.system(size: 10, weight: .medium))
            }
            .frame(width: 104, height: 56)
            .foregroundStyle(agent.isEnabled ? .black : .white)
            .background(agent.isEnabled ? Color.yellow : .white.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 16))
        }
        .accessibilityLabel("DeepSeek 自动相机")
        .accessibilityValue(agent.isEnabled ? "已开启" : "已关闭")
        .accessibilityHint("自动选择光圈、曝光和照片画幅")
        .accessibilityIdentifier("camera.ai")
        .accessibilityAddTraits(agent.isEnabled ? .isSelected : [])
    }
}

struct CameraControlsSheet: View {
    let model: CameraModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    CameraExposureReadout(state: model.state)
                    ApertureControls(state: model.state,
                                     onAperture: model.setAperture,
                                     onBias: model.setExposureBias)

                    Button(action: model.resetCamera) {
                        Label("恢复自动参数", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.state.canCapture)
                    .accessibilityLabel("恢复自动光圈、自动对焦和零曝光补偿")

                    Text("手动调整后，点按 DeepSeek 可继续自动控制。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
            .navigationTitle("手动控制")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .frame(minHeight: 44)
                }
            }
        }
        .tint(.yellow)
        .preferredColorScheme(.dark)
        .presentationDetents([.height(460), .large])
        .presentationDragIndicator(.visible)
    }
}
