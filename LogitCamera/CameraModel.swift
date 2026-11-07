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
    let capture: CaptureSession
    let agent: AgentController
    var state = CameraState()
    var latestPhoto: CapturedPhoto?
    var thumbnail: UIImage?
    var preview: UIImage?
    var photoPixelSize: CGSize?
    var isSaving = false
    var capturePending = false
    var photoSaved = false
    var archivedURL: URL?
    /// 最近一张照片所在连拍组的备选（含 AI 选中的那张）。
    var alternates: [BurstAlternate] = []
    /// 连拍已拍完、正在本机选片。
    var isSelecting = false
    /// 每次按下快门（手动或自动）加一，驱动取景闪白。
    var shutterTick = 0
    /// 选片完成后短暂展示的一组缩略图。
    var burstPreview: BurstPreview?
    /// 当前生效的滤镜配方（预设 + 微调 + 强度）：取景实时生效，成片按快门按下那一刻的配方渲染。
    private(set) var look: LookRecipe = .identity
    /// 内置预设与「我的滤镜」。
    let presets: [LookRecipe] = Knowledge.looks()
    private(set) var myLooks: [LookRecipe] = LookLibrary.load()
    /// 当前选择的滤镜（预设或我的滤镜）。
    private(set) var lookBase: LookRecipe = .identity
    var lookAdjustments = LookAdjustments() { didSet { refreshLook() } }
    var lookStrength = 1.0 { didSet { refreshLook() } }
    var showsLookStrip = false
    var showsLookAdjust = false
    /// 最近一张照片调色前的原片（照片详情里换滤镜用）。
    private(set) var latestOriginal: CapturedPhoto?
    /// 单张拍摄（AI 关闭）按下快门时冻结的配方。
    @ObservationIgnored private var pendingLook: LookRecipe = .identity
    var notice: CameraNotice?
    /// 当前手动参数是否由 AI 设定。用户任何接管都会清除。
    var agentOwnsSettings = false
    var showsPhoto = false
    var showsSettings = false
    var showsAgentDetail = false
    var hasAPIKey = false
    private var apiKey: String?
    private var foreground = false
    private var automaticCapturePending = false
    /// 每组连拍一个序号；只有最新一组的选片结果更新界面。
    private var burstSequence = 0
    /// AI 开启时每次拍摄的连拍张数。
    static let burstCount = 6
    private var lastPhase: CameraPhase = .starting
    @ObservationIgnored private var demoApplied = false

    var hasUnprotectedPhoto: Bool {
        latestPhoto != nil && !photoSaved && archivedURL == nil
    }

    var canTakePhoto: Bool {
        state.canCapture && !isSaving && !capturePending && !hasUnprotectedPhoto
    }

    init() {
        let capture = CaptureSession()
        self.capture = capture
        agent = AgentController(capture: capture)
        capture.observe { [weak self] event in
            Task { @MainActor in self?.receive(event) }
        }
        agent.onFire = { [weak self] crop, ratio in self?.takeAutomaticPhoto(crop: crop, ratio: ratio) ?? false }
        agent.onPlanApplied = { [weak self] _ in
            // AI 方案决定镜头、曝光与画幅；读数标为 AI 设定。
            self?.agentOwnsSettings = true
        }
        Task.detached(priority: .background) { BurstStore.purge() }
        BuiltinShaders.warmUp()
        #if DEBUG
        if let debugLook = DebugLooks.current { selectLook(debugLook) }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-LogitPreset"), index + 1 < arguments.count,
           let preset = presets.first(where: { $0.name == arguments[index + 1] }) {
            selectLook(preset)
            showsLookStrip = true
        }
        #endif
    }

    func activate() {
        foreground = true
        refreshAIConfiguration()
        capture.start()
        #if DEBUG
        if !demoApplied, let demo = DemoScenario.current {
            demoApplied = true
            applyDemo(demo)
        }
        if !demoApplied, ProcessInfo.processInfo.arguments.contains("-LogitPerceptionOnly") {
            demoApplied = true
            agent.startPerceptionProbe()
        }
        #endif
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
        if agent.isEnabled || agent.faulted { agent.stop(); return }
        var key = apiKey
        #if DEBUG
        // 离线导演不需要真实密钥。
        if ProcessInfo.processInfo.arguments.contains("-LogitOfflineDirector") { key = key ?? "offline" }
        #endif
        guard let apiKey = key else { showsSettings = true; return }
        guard state.canCapture, !isSaving else { post("相机就绪后即可开启 AI。"); return }
        notice = nil
        agent.enable(key: apiKey)
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
    /// 冷却中「再拍一张」。
    func armAutoCapture() { agent.rearm() }

    private func takeAutomaticPhoto(crop: CameraCore.NormalizedRect?, ratio: FrameRatio) -> Bool {
        guard foreground, canTakePhoto else { return false }
        automaticCapturePending = true
        shoot(crop: crop, ratio: ratio)
        return true
    }

    private func resumeAgentIfReady() {
        guard foreground, state.canCapture else { return }
        agent.resume()
    }

    /// 快门永远立即拍摄：AI 开启时按 AI 的裁切框与画幅连拍并在本机选片（所见即所得），否则单张按画幅居中裁切。
    func takePhoto() {
        if agent.isEnabled {
            shoot(crop: agent.crop, ratio: agent.plan?.composition.ratio ?? state.ratio)
        } else {
            guard canTakePhoto else { return }
            capturePending = true
            notice = nil
            shutterTick += 1
            pendingLook = look
            capture.capture()
        }
    }

    private func shoot(crop: CameraCore.NormalizedRect?, ratio: FrameRatio) {
        guard canTakePhoto else { return }
        capturePending = true
        notice = nil
        shutterTick += 1
        pendingLook = look
        capture.captureBurst(count: Self.burstCount, crop: crop, ratio: ratio)
    }

    /// 连拍拍完：先让 AI 进入冷却、释放快门，再在后台选片；最好的一张走正常保存流程，其余存为备选。
    private func select(_ photos: [CapturedPhoto], automatic: Bool, look: LookRecipe) {
        burstSequence += 1
        let sequence = burstSequence
        let genre = agent.plan?.genre ?? .general
        isSelecting = true
        Task {
            let (qualities, thumbs) = await Task.detached(priority: .userInitiated) {
                var result: [FrameQuality] = []
                var images: [CGImage] = []
                for photo in photos {
                    result.append(await BurstAnalyzer.quality(of: photo.data))
                    if let image = PhotoMetadata.downsample(photo.data, maxPixel: 160) { images.append(image) }
                }
                return (result, images)
            }.value
            let best = BurstSelector.best(qualities, genre: genre)
            let scores = BurstSelector.scores(qualities, genre: genre)
            let original = photos[min(best, photos.count - 1)]
            let chosen = await Self.graded(original, look: look)
            if sequence == burstSequence { latestOriginal = original }
            agent.record(photoID: chosen.id, automatic: automatic)
            let stored: [BurstAlternate] = await Task.detached(priority: .utility) {
                guard photos.count > 1 else { return [] }
                try? BurstStore.save(photos, chosen: best, photoID: chosen.id, genre: genre, scores: scores, look: look)
                return BurstStore.load(photoID: chosen.id)
            }.value
            guard sequence == burstSequence else {
                // 更新的一组已经到了：这一组只保存，不改界面。
                Task { try? await PhotoLibrary.save(chosen) }
                return
            }
            isSelecting = false
            show(chosen)
            alternates = stored
            if thumbs.count == photos.count, photos.count > 1 {
                let preview = BurstPreview(thumbnails: thumbs.map(UIImage.init(cgImage:)), chosen: best)
                burstPreview = preview
                agent.picked()
                Task { [weak self = self] in
                    try? await Task.sleep(for: .seconds(2.4))
                    if self?.burstPreview?.id == preview.id { self?.burstPreview = nil }
                }
            }
            isSaving = true
            await persistAndSave(chosen)
        }
    }

    /// 把备选里的另一张也存入相册，并记下用户的选择（子项目 4 学习用）。
    func saveAlternate(_ alternate: BurstAlternate) async {
        guard let current = latestPhoto, let data = try? Data(contentsOf: alternate.url) else { return }
        let photo = CapturedPhoto(data: data, aperture: current.aperture, iso: current.iso,
                                  exposureSeconds: current.exposureSeconds)
        do {
            try await PhotoLibrary.save(photo)
            await CaptureRecordStore.shared.setChosen(alternate.index, for: current.id)
            post("已把这张也存入照片图库")
        } catch {
            post(error.localizedDescription, warning: true)
        }
    }

    func saveLatestPhoto() async {
        guard let photo = latestPhoto, !isSaving, !photoSaved else { return }
        isSaving = true
        await persistAndSave(photo)
    }

    private func persistAndSave(_ photo: CapturedPhoto) async {
        defer { isSaving = false }
        var localURL = archivedURL
        if localURL == nil {
            let directory = URL.documentsDirectory.appendingPathComponent("待保存照片", isDirectory: true)
            // A failed or denied Photos export must not destroy the original.
            localURL = try? await Task.detached(priority: .userInitiated) {
                try PhotoArchive(directory: directory).store(photo.data, fileExtension: photo.isHEIC ? "heic" : "jpg")
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

    // MARK: - Looks

    func selectLook(_ recipe: LookRecipe) {
        lookBase = recipe
        lookAdjustments = .zero
        lookStrength = 1
        refreshLook()
    }

    private func refreshLook() {
        var recipe = lookAdjustments.apply(to: lookBase)
        recipe.strength = lookBase.strength * lookStrength
        if lookBase.isIdentity && !lookAdjustments.isZero { recipe.name = "原片 · 调整" }
        look = recipe
    }

    func saveMyLook(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !presets.contains(where: { $0.name == trimmed }) else {
            post("这个名字已被内置滤镜使用，换一个吧。", warning: true)
            return
        }
        var recipe = look
        recipe.name = trimmed
        recipe.strength = min(max(recipe.strength, 0), 1)
        guard (try? recipe.validate()) != nil else { post("这个滤镜无法保存。", warning: true); return }
        myLooks.removeAll { $0.name == trimmed }
        myLooks.append(recipe)
        LookLibrary.save(myLooks)
        selectLook(recipe)
        post("已保存「\(trimmed)」")
    }

    func deleteMyLook(named name: String) {
        myLooks.removeAll { $0.name == name }
        LookLibrary.save(myLooks)
        if lookBase.name == name { selectLook(.identity) }
    }

    /// 照片详情里换滤镜后另存为新照片（原来那张保留）。
    func saveAsNewPhoto(look recipe: LookRecipe) async {
        guard let original = latestOriginal else { return }
        let rendered = await Self.graded(CapturedPhoto(data: original.data, aperture: original.aperture, iso: original.iso,
                                                       exposureSeconds: original.exposureSeconds), look: recipe)
        do {
            try await PhotoLibrary.save(rendered)
            post("已用「\(recipe.name)」另存为新照片")
        } catch {
            post(error.localizedDescription, warning: true)
        }
    }

    /// 按配方渲染成片（后台）；配方为空或渲染失败时返回原片，照片照常保存。
    nonisolated private static func graded(_ photo: CapturedPhoto, look: LookRecipe) async -> CapturedPhoto {
        guard !look.isIdentity else { return photo }
        return await Task.detached(priority: .userInitiated) {
            (try? LookRenderer.renderPhoto(photo.data, recipe: look)).map(photo.replacingData) ?? photo
        }.value
    }

    private func show(_ photo: CapturedPhoto) {
        latestPhoto = photo
        thumbnail = nil
        preview = nil
        photoPixelSize = nil
        loadPreviews(for: photo)
        photoSaved = false
        archivedURL = nil
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
            agent.cameraState = state
            if state.phase != .ready && !state.isCapturing { capturePending = false }
            if state.phase == .ready { resumeAgentIfReady() }
            // 只在离开 ready 时暂停一次，避免每次读数刷新都重置 Agent 状态。
            else if lastPhase == .ready { agent.pause() }
            lastPhase = state.phase
        case .error(let message):
            post(message, warning: true)
        case .captureRejected:
            capturePending = false
            if automaticCapturePending { agent.fireRejected(); automaticCapturePending = false }
            post("相机正在调整，请稍后再拍。")
        case .captureFailed(let message):
            post(message, warning: true)
            capturePending = false
            if automaticCapturePending { agent.fireRejected(); automaticCapturePending = false }
        case .photo(let original):
            automaticCapturePending = false
            capturePending = false
            alternates = []
            let look = pendingLook
            isSaving = true
            Task {
                let photo = await Self.graded(original, look: look)
                latestOriginal = original
                show(photo)
                await persistAndSave(photo)
            }
        case .burst(let photos):
            let automatic = automaticCapturePending
            automaticCapturePending = false
            capturePending = false
            agent.captured(automatic: automatic)
            select(photos, automatic: automatic, look: pendingLook)
        }
    }
}
