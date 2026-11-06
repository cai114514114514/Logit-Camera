import Observation
import UIKit
import CameraCore

/// 单行提示。`offersResume` 表示用户刚接管了参数，可一键恢复 AI。
struct CameraNotice: Equatable {
    let id = UUID()
    let text: String
    var isWarning = false
    var offersResume = false
}

@MainActor @Observable
final class CameraModel {
    let capture = CaptureSession()
    let agent = CameraAgent()
    var state = CameraState()
    var latestPhoto: CapturedPhoto?
    var thumbnail: UIImage?
    var preview: UIImage?
    var photoPixelSize: CGSize?
    var isSaving = false
    var capturePending = false
    var photoSaved = false
    var archivedURL: URL?
    var notice: CameraNotice?
    /// 当前手动参数是否由 AI 设定。用户任何接管都会清除。
    var agentOwnsSettings = false
    var showsPhoto = false
    var showsInfo = false
    var showsControls = false
    var showsSettings = false
    var showsAgentDetail = false
    var hasAPIKey = false
    private var apiKey: String?
    private var foreground = false
    private var automaticCapturePending = false
    private var lastPhase: CameraPhase = .starting

    var hasUnprotectedPhoto: Bool {
        latestPhoto != nil && !photoSaved && archivedURL == nil
    }

    var canTakePhoto: Bool {
        state.canCapture && !isSaving && !capturePending && !hasUnprotectedPhoto
    }

    init() {
        capture.observe { [weak self] event in
            Task { @MainActor in self?.receive(event) }
        }
        agent.onAutoCapture = { [weak self] in self?.takeAutomaticPhoto() ?? false }
        agent.onAdjusted = { [weak self] in self?.agentOwnsSettings = true }
    }

    func activate() {
        foreground = true
        refreshAIConfiguration()
        capture.start()
    }

    func deactivate() {
        foreground = false
        agent.pause()
        capture.stop()
    }

    func pauseAI() {
        foreground = false
        agent.pause()
    }

    func refreshAIConfiguration() {
        do {
            try AICredentials.importDevelopmentKey()
            apiKey = try AICredentials.load()
            hasAPIKey = apiKey != nil
        } catch { post(error.localizedDescription, warning: true) }
    }

    func saveAPIKey(_ value: String) throws {
        agent.stop()
        try AICredentials.save(value)
        refreshAIConfiguration()
    }

    func removeAPIKey() throws {
        agent.stop()
        try AICredentials.remove()
        refreshAIConfiguration()
    }

    func toggleAI() {
        if agent.isEnabled { agent.stop(); return }
        guard let apiKey else { showsSettings = true; return }
        guard state.canCapture, !isSaving else { post("相机就绪后即可开启 AI。"); return }
        notice = nil
        agent.enable(capture: capture, key: apiKey)
    }

    func setRatio(_ value: FrameRatio) { takeOver("画幅"); capture.setRatio(value) }
    func setAperture(_ value: Float?) { takeOver("光圈"); capture.setAperture(value) }
    func setExposureBias(_ value: Float) { takeOver("曝光补偿"); capture.setExposureBias(value) }
    func setZoom(_ value: Double, animated: Bool = true) { takeOver("变焦"); capture.setZoom(value, animated: animated) }
    func resetCamera() { takeOver("相机参数"); capture.reset() }
    /// 点按对焦只移动对焦和测光点，不算接管，AI 继续运行。
    func focus(at point: CGPoint) { capture.focus(at: point) }

    func origin(isManual: Bool) -> ValueOrigin {
        ValueOrigin.of(isManual: isManual, agentOwned: agentOwnsSettings)
    }

    /// 用户手动改参数：停止 AI（语义不变），并提示可以恢复。
    private func takeOver(_ parameter: String) {
        agentOwnsSettings = false
        guard agent.isEnabled else { return }
        agent.stop()
        post("你接管了\(parameter) · AI 已停止", offersResume: hasAPIKey)
    }

    func post(_ text: String, warning: Bool = false, offersResume: Bool = false, sticky: Bool = false) {
        let value = CameraNotice(text: text, isWarning: warning, offersResume: offersResume)
        notice = value
        guard !sticky else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.notice?.id == value.id { self?.notice = nil }
        }
    }
    func setAutoCapture(_ enabled: Bool) { agent.setAutoCapture(enabled) }
    func armAutoCapture() { agent.armAutoCapture() }
    func cancelAutoCapture() { agent.cancelAutoCapture() }

    private func takeAutomaticPhoto() -> Bool {
        guard foreground, canTakePhoto else { return false }
        automaticCapturePending = true
        takePhoto()
        return true
    }

    private func resumeAgentIfReady() {
        guard foreground, state.canCapture, !capturePending, !isSaving, let apiKey else { return }
        agent.resume(capture: capture, key: apiKey)
    }

    func takePhoto() {
        guard canTakePhoto else { return }
        // 手动快门不解除自动拍摄准备；自动拍摄在倒计时结束时自行解除。
        agent.pause()
        capturePending = true
        notice = nil
        capture.capture()
    }

    func saveLatestPhoto() async {
        guard let photo = latestPhoto, !isSaving, !photoSaved else { return }
        isSaving = true
        await persistAndSave(photo)
    }

    private func persistAndSave(_ photo: CapturedPhoto) async {
        defer { isSaving = false; resumeAgentIfReady() }
        var localURL = archivedURL
        if localURL == nil {
            let directory = URL.documentsDirectory.appendingPathComponent("待保存照片", isDirectory: true)
            // A failed or denied Photos export must not destroy the original.
            localURL = try? await Task.detached(priority: .userInitiated) {
                try PhotoArchive(directory: directory).store(photo.data)
            }.value
            if latestPhoto?.id == photo.id { archivedURL = localURL }
        }
        do {
            try await PhotoLibrary.save(photo)
            if latestPhoto?.id == photo.id {
                photoSaved = true
                post("已保存到照片图库")
            }
            if let localURL { try? FileManager.default.removeItem(at: localURL) }
        } catch {
            guard latestPhoto?.id == photo.id else { return }
            post(localURL != nil
                 ? "原图已保留在「文件 → 我的 iPhone → Logit Camera → 待保存照片」。可重试保存或分享。"
                 : "照片尚未保存，请先保存或分享当前照片。" + error.localizedDescription,
                 warning: true, sticky: true)
        }
    }

    func discardUnprotectedPhoto() {
        guard !isSaving, hasUnprotectedPhoto else { return }
        latestPhoto = nil
        thumbnail = nil
        preview = nil
        photoPixelSize = nil
        archivedURL = nil
        notice = nil
    }

    /// 缩略图与详情预览在后台用 ImageIO 生成，主线程不解码整张照片。
    private func loadPreviews(for photo: CapturedPhoto) {
        let data = photo.data
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                (PhotoMetadata.downsample(data, maxPixel: 600).map(UIImage.init(cgImage:)),
                 PhotoMetadata.downsample(data, maxPixel: 2400).map(UIImage.init(cgImage:)),
                 PhotoMetadata.pixelSize(of: data))
            }.value
            guard latestPhoto?.id == photo.id else { return }
            thumbnail = result.0
            preview = result.1
            photoPixelSize = result.2
        }
    }

    private func receive(_ event: CameraEvent) {
        switch event {
        case .state(let state):
            self.state = state
            if state.phase != .ready && !state.isCapturing { capturePending = false }
            if state.phase == .ready { resumeAgentIfReady() }
            // 只在离开 ready 时暂停一次，避免每次读数刷新都重置 Agent 状态。
            else if lastPhase == .ready { agent.pause() }
            lastPhase = state.phase
        case .error(let message):
            post(message, warning: true)
        case .captureRejected:
            capturePending = false
            if automaticCapturePending { agent.armAutoCapture(); automaticCapturePending = false }
            post("相机正在调整，请稍后再拍。")
        case .captureFailed(let message):
            post(message, warning: true)
            capturePending = false
            if automaticCapturePending { agent.armAutoCapture(); automaticCapturePending = false }
        case .photo(let photo):
            automaticCapturePending = false
            capturePending = false
            latestPhoto = photo
            thumbnail = nil
            preview = nil
            photoPixelSize = nil
            loadPreviews(for: photo)
            photoSaved = false
            archivedURL = nil
            isSaving = true
            Task { await persistAndSave(photo) }
        }
    }
}
