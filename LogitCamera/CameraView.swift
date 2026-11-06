import SwiftUI
import CameraCore

/// 主界面只负责布局：HUD ｜ 取景 ｜ 浮动层（提示、AI 标注、变焦或拨盘）｜ 固定控制区。
struct CameraView: View {
    @State private var model = CameraModel()
    @State private var dialOpen = false
    @State private var controlsHeight: CGFloat = 150
    @State private var pinchBase: Double?
    @Environment(\.scenePhase) private var scenePhase

    private var agent: AgentController { model.agent }

    var body: some View {
        GeometryReader { geometry in
            let size = previewSize(in: geometry.size)
            let top = previewTop(size: size, height: geometry.size.height)

            ZStack(alignment: .top) {
                Theme.Palette.background.ignoresSafeArea()

                viewfinder
                    .frame(width: size.width, height: size.height)
                    .position(x: geometry.size.width / 2, y: top + size.height / 2)

                VStack(spacing: 0) {
                    HUDReadoutBar(model: model, dialOpen: $dialOpen)
                        .background {
                            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                                .ignoresSafeArea(edges: .top)
                                .allowsHitTesting(false)
                        }
                    Spacer(minLength: 0)
                    floatingLayer
                    fixedControls
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
                }
            }
        }
        .background(Theme.Palette.background)
        .foregroundStyle(Theme.Palette.ink)
        .tint(Theme.Palette.accent)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task {
            model.activate()
            #if DEBUG
            if DemoScenario.current == .manual { dialOpen = true }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.activate()
            case .inactive: model.pauseAI()
            case .background: model.deactivate()
            @unknown default: model.pauseAI()
            }
        }
        .sheet(isPresented: $model.showsPhoto) { PhotoDetailView(model: model) }
        .sheet(isPresented: $model.showsSettings) { SettingsView(model: model) }
        .sheet(isPresented: $model.showsAgentDetail) { AIDetailSheet(model: model) }
    }

    // MARK: Layout

    /// AI 开启时取景显示传感器全画幅（3:4），裁切框标出 AI 的构图。
    private var showsFullFrame: Bool { agent.isEnabled || agent.diagnostics != nil }

    private func previewSize(in available: CGSize) -> CGSize {
        let ratio = CGFloat((showsFullFrame ? FrameRatio.standard : model.state.ratio).widthToHeight)
        let width = min(available.width, available.height * ratio)
        return CGSize(width: width, height: width / ratio)
    }

    /// 能放进 HUD 与固定控制区之间就居中；放不下时贴着 HUD；
    /// 更高的画幅（9:16）在整屏内居中，延伸到控制区下方但不改变比例。
    private func previewTop(size: CGSize, height: CGFloat) -> CGFloat {
        let hud = Theme.Metric.hudHeight
        let region = height - hud - controlsHeight
        if size.height <= region { return hud + (region - size.height) / 2 }
        if size.height <= height - hud { return hud }
        return max(0, (height - size.height) / 2)
    }

    // MARK: Viewfinder

    private var viewfinder: some View {
        CameraPreview(session: model.capture.session,
                      onFocus: focus,
                      markerColor: agent.isEnabled ? UIColor(Theme.Palette.accent) : .white)
            .background(.black)
            .overlay {
                if agent.isEnabled, let crop = agent.crop {
                    CropOverlay(crop: crop, subject: agent.subjectBox)
                } else if agent.diagnostics != nil {
                    CropOverlay(crop: .full, subject: agent.subjectBox)
                }
            }
            .overlay {
                ViewfinderFrame(aiActive: agent.isEnabled && agent.phase != .paused && agent.phase != .cooldown,
                                scanTick: agent.observationTick,
                                crop: agent.isEnabled ? agent.crop : nil)
            }
            .overlay(alignment: .topLeading) {
                if let diagnostics = agent.diagnostics {
                    Text(diagnostics)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.Palette.accent)
                        .padding(6)
                        .background(.black.opacity(0.6))
                        .padding(8)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("camera.diagnostics")
                }
            }
            .overlay {
                if model.state.phase != .ready { statusOverlay }
            }
            .clipped()
            .gesture(pinch)
            // camera.preview 标识由 UIKit 预览视图提供；这里再设会覆盖叠层（裁切框、诊断）的标识。
    }

    private func focus(_ point: CGPoint) {
        if dialOpen {
            withAnimation(.snappy(duration: 0.25)) { dialOpen = false }
        } else {
            model.focus(at: point)
        }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? Double(model.state.zoom)
                pinchBase = base
                model.setZoom(base * value.magnification, animated: false)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private var statusOverlay: some View {
        VStack(spacing: 18) {
            if model.state.phase == .starting {
                ProgressView().tint(Theme.Palette.inkSecondary)
            } else {
                Image(systemName: model.state.phase == .denied ? "camera.badge.ellipsis" : "camera")
                    .font(.system(size: 30, weight: .ultraLight))
                    .foregroundStyle(Theme.Palette.inkSecondary)
            }
            Text(model.state.message)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.ink)
                .multilineTextAlignment(.center)
            if model.state.phase == .denied {
                outlineButton("打开系统设置", action: openSettings)
            } else if model.state.phase == .unavailable || model.state.phase == .interrupted {
                outlineButton("重新连接相机") { model.activate() }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.85))
    }

    private func outlineButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Palette.accent)
                .padding(.horizontal, 20)
                .frame(minHeight: 44)
                .overlay(Capsule().stroke(Theme.Palette.accentDim, lineWidth: 1))
        }
    }

    // MARK: Controls

    /// 浮在取景画面下沿：提示、AI 标注，以及变焦（拨盘展开时换成拨盘）。不参与取景定位。
    private var floatingLayer: some View {
        VStack(spacing: 10) {
            if let notice = model.notice {
                Toast(text: notice.text, isWarning: notice.isWarning,
                      action: notice.offersResume ? ToastAction(title: "恢复 AI", run: resumeAI) : nil)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            AIAnnotation(agent: agent)
                .padding(.horizontal, Theme.Metric.gutter)
            if dialOpen {
                ManualDial(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                ZoomSelector(model: model)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 6)
        .animation(.snappy(duration: 0.25), value: model.notice)
        .animation(.snappy(duration: 0.25), value: dialOpen)
    }

    private func resumeAI() {
        model.notice = nil
        model.toggleAI()
    }

    /// 固定高度：状态线槽位始终保留，开关 AI 时取景不跳动。
    private var fixedControls: some View {
        VStack(spacing: 2) {
            ZStack {
                if agent.isEnabled || agent.faulted {
                    AIStatusLine(agent: agent) { model.showsAgentDetail = true }
                        .transition(.opacity)
                }
            }
            .frame(height: 44)
            .animation(.easeOut(duration: 0.2), value: agent.isEnabled)

            HStack(spacing: 0) {
                photoButton.frame(maxWidth: .infinity)
                ShutterButton(model: model)
                AIButton(isOn: agent.isEnabled, aligned: agent.phase == .armed || agent.phase == .capturing,
                         action: model.toggleAI)
                    .disabled(model.state.phase != .ready || model.isSaving || model.capturePending)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Theme.Metric.gutter)
        }
        .padding(.bottom, 10)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.85), .black], startPoint: .top, endPoint: .bottom)
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
                    Image(systemName: "photo").font(.system(size: 17, weight: .light))
                        .foregroundStyle(Theme.Palette.inkTertiary)
                }
            }
            .frame(width: 44, height: 44)
            .background(.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.Palette.hairline, lineWidth: 1))
            .frame(width: 56, height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.latestPhoto == nil)
        .accessibilityLabel("查看刚拍摄的照片")
        .accessibilityIdentifier("camera.photo")
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
