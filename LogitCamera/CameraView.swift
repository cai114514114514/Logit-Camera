import SwiftUI
import CameraCore

struct CameraView: View {
    @State private var model = CameraModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            let size = previewSize(in: geometry.size)
            // Keep the normal frame above the shutter. Tall frames continue
            // beneath floating controls without changing their aspect ratio.
            let previewTop = max(0, (geometry.size.height - 132 - size.height) / 2)

            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                viewfinder
                    .frame(width: size.width, height: size.height)
                    .position(x: geometry.size.width / 2, y: previewTop + size.height / 2)

                VStack(spacing: 0) {
                    topToolbar
                    if model.agent.isEnabled || !model.agent.reason.isEmpty {
                        CameraAgentPanel(model: model)
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                    }
                    Spacer(minLength: 0)
                    shutterDock
                }
            }
        }
        .background(.black)
        .foregroundStyle(.white)
        .tint(.yellow)
        .preferredColorScheme(.dark)
        .task { model.activate() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.activate()
            case .inactive: model.pauseAI()
            case .background: model.deactivate()
            @unknown default: model.pauseAI()
            }
        }
        .sheet(isPresented: $model.showsPhoto) { PhotoDetailView(model: model) }
        .sheet(isPresented: $model.showsInfo) { CameraInfoView(state: model.state) }
        .sheet(isPresented: $model.showsControls) { CameraControlsSheet(model: model) }
        .sheet(isPresented: $model.showsAISettings) { AISettingsView(model: model) }
    }

    private func previewSize(in available: CGSize) -> CGSize {
        let ratio = CGFloat(model.state.ratio.widthToHeight)
        let width = min(available.width, available.height * ratio)
        return CGSize(width: width, height: width / ratio)
    }

    private var topToolbar: some View {
        HStack(spacing: 8) {
            CameraToolButton(symbol: "camera.aperture", label: "相机能力与使用说明") {
                model.showsInfo = true
            }
            Spacer(minLength: 8)
            ratioMenu
            Spacer(minLength: 8)
            CameraToolButton(symbol: "slider.horizontal.3", label: "手动相机控制") {
                model.showsControls = true
            }
            .accessibilityIdentifier("camera.controls")
            CameraToolButton(symbol: "gearshape", label: "DeepSeek 设置") {
                model.showsAISettings = true
            }
            .accessibilityIdentifier("camera.aiSettings")
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var ratioMenu: some View {
        Menu {
            Section(model.agent.isEnabled ? "DeepSeek 正在自动选择画幅" : "照片画幅") {
                ForEach(FrameRatio.allCases) { ratio in
                    Button {
                        model.setRatio(ratio)
                    } label: {
                        if model.state.ratio == ratio {
                            Label(ratio.rawValue, systemImage: "checkmark")
                        } else {
                            Text(ratio.rawValue)
                        }
                    }
                    .accessibilityIdentifier("ratio.\(ratio.rawValue)")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(model.state.ratio.rawValue)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(model.agent.isEnabled ? .yellow : .white)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(.black.opacity(0.6), in: Capsule())
        }
        .accessibilityLabel("照片画幅")
        .accessibilityValue(model.state.ratio.rawValue)
        .accessibilityIdentifier("camera.ratio")
    }

    private var viewfinder: some View {
        CameraPreview(session: model.capture.session, onFocus: model.focus)
            .background(.black)
            .overlay {
                if model.state.phase != .ready { statusOverlay }
            }
            .overlay {
                if model.agent.stage == .countdown, let countdown = model.agent.countdown {
                    CameraCaptureCountdown(countdown: countdown, onCancel: model.cancelAutoCapture)
                        .offset(y: 44)
                }
            }
            .clipped()
            .accessibilityIdentifier("camera.preview")
    }

    private var statusOverlay: some View {
        VStack(spacing: 18) {
            if model.state.phase == .starting {
                ProgressView()
            } else {
                Image(systemName: model.state.phase == .denied ? "camera.badge.ellipsis" : "camera")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
            }
            Text(model.state.message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            if model.state.phase == .denied {
                Button("打开系统设置", action: openSettings)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
            } else if model.state.phase == .unavailable || model.state.phase == .interrupted {
                Button("重新连接相机") { model.activate() }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.8))
    }

    private var shutterDock: some View {
        VStack(spacing: 10) {
            if let notice = model.notice {
                Text(notice.text)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityAddTraits(.updatesFrequently)
            }

            CameraExposureReadout(state: model.state)

            HStack(spacing: 0) {
                photoButton.frame(maxWidth: .infinity)
                shutterButton.frame(maxWidth: .infinity)
                CameraAgentButton(agent: model.agent, action: model.toggleAI)
                    .frame(maxWidth: .infinity)
                    .disabled(model.state.phase != .ready || model.isSaving || model.capturePending)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.8), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }

    private var photoButton: some View {
        Button { model.showsPhoto = true } label: {
            Group {
                if let thumbnail = model.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, height: 52)
            .background(.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.15), lineWidth: 1))
        }
        .disabled(model.latestPhoto == nil)
        .accessibilityLabel("查看刚拍摄的照片")
        .accessibilityIdentifier("camera.photo")
    }

    private var shutterButton: some View {
        Button(action: model.takePhoto) {
            ZStack {
                Circle().stroke(.white.opacity(0.9), lineWidth: 3).frame(width: 78, height: 78)
                Circle().fill(.white).frame(width: 64, height: 64)
                if model.capturePending || model.state.isCapturing || model.isSaving {
                    ProgressView().tint(.black)
                }
            }
        }
        .disabled(!model.canTakePhoto)
        .opacity(model.canTakePhoto ? 1 : 0.4)
        .accessibilityLabel("拍照并保存")
        .accessibilityIdentifier("camera.shutter")
        .sensoryFeedback(.impact(weight: .medium), trigger: model.state.isCapturing)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
