import Observation
import UIKit
import CameraCore

@MainActor @Observable
final class CameraModel {
    let capture = CaptureSession()
    let agent = CameraAgent()
    var state = CameraState()
    var latestPhoto: CapturedPhoto?
    var thumbnail: UIImage?
    var isSaving = false
    var capturePending = false
    var photoSaved = false
    var archivedURL: URL?
    var notice: String?
    var showsPhoto = false
    var showsInfo = false
    var showsControls = false
    var showsAISettings = false
    var hasAPIKey = false
    private var apiKey: String?
    private var foreground = false
    private var automaticCapturePending = false

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
        } catch { notice = error.localizedDescription }
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
        guard let apiKey else { showsAISettings = true; return }
        guard state.canCapture, !isSaving else { notice = "相机就绪后即可开启 AI。"; return }
        notice = nil
        agent.enable(capture: capture, key: apiKey)
    }

    func setRatio(_ value: FrameRatio) { agent.stop(); capture.setRatio(value) }
    func setAperture(_ value: Float?) { agent.stop(); capture.setAperture(value) }
    func setExposureBias(_ value: Float) { agent.stop(); capture.setExposureBias(value) }
    func resetCamera() { agent.stop(); capture.reset() }
    func focus(at point: CGPoint) { agent.stop(); capture.focus(at: point) }
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
        agent.captureArmed = false
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
                notice = "已保存到照片图库"
            }
            if let localURL { try? FileManager.default.removeItem(at: localURL) }
        } catch {
            guard latestPhoto?.id == photo.id else { return }
            notice = localURL != nil
                ? "原图已保留在「文件 → 我的 iPhone → Logit Camera → 待保存照片」。可重试保存或分享。"
                : "照片尚未保存，请先保存或分享当前照片。" + error.localizedDescription
        }
    }

    func discardUnprotectedPhoto() {
        guard !isSaving, hasUnprotectedPhoto else { return }
        latestPhoto = nil
        thumbnail = nil
        archivedURL = nil
        notice = nil
    }

    private func receive(_ event: CameraEvent) {
        switch event {
        case .state(let state):
            self.state = state
            if state.phase != .ready && !state.isCapturing { capturePending = false }
            if state.phase == .ready { resumeAgentIfReady() }
            else { agent.pause() }
        case .error(let message):
            notice = message
        case .captureRejected:
            capturePending = false
            if automaticCapturePending { agent.armAutoCapture(); automaticCapturePending = false }
            notice = "相机正在调整，请稍后再拍。"
        case .captureFailed(let message):
            notice = message
            capturePending = false
            if automaticCapturePending { agent.armAutoCapture(); automaticCapturePending = false }
        case .photo(let photo):
            automaticCapturePending = false
            capturePending = false
            latestPhoto = photo
            thumbnail = UIImage(data: photo.data)
            photoSaved = false
            archivedURL = nil
            isSaving = true
            Task { await persistAndSave(photo) }
        }
    }
}
