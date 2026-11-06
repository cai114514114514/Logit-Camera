# Logit Camera UI 改版 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按「精密仪器 · 安静副驾驶」设计重做 Logit Camera 主界面，并修复审查中与 UI 相关的 7 个问题。

**Architecture:** 可单测的纯逻辑（变焦档位、参数差异、参数归属、照片元数据与缩略图）放进 `CameraCore` 并用 Swift Testing 覆盖；视觉组件放进 `LogitCamera/Design/`，每个文件一个组件；`CameraView` 只做组装。DEBUG 演示模式用于无 API 消耗的真机截图验证。

**Tech Stack:** Swift 6、SwiftUI（iOS 27）、AVFoundation、ImageIO、Swift Testing、XCUITest。所有命令通过 Mac Bridge 在 `/Users/wangzhe/Logit Camera` 执行。

**Spec:** `docs/superpowers/specs/2026-11-06-ui-redesign-design.md`

## Global Constraints

- 部署目标 iOS 27.0，Swift 6，仅 iPhone 竖屏；不新增第三方依赖。
- 颜色：`accent` = `#3DF5C8`，`warning` = `#FFB547`，背景 `#000000`；ink 92% / 60% / 38% 白，hairline 18% 白。黄色与彩虹渐变全部移除。
- `accent` 只用于 AI 相关元素；用户设定值 `ink`，系统自动值 `inkSecondary`。
- UI 文案不出现「DeepSeek」，模型名只在设置页。
- 保留无障碍标识：`camera.ratio`、`camera.preview`、`camera.aperture`（文本格式 `ƒ/1.48`）、`camera.controls`、`camera.aiSettings`、`camera.agent`（value 含「第 N 轮」）、`camera.ai`（value「已开启/已关闭」）、`camera.photo`、`camera.shutter`、`camera.autoCapture`、`camera.rearm`、`camera.countdown`、`camera.cancelCapture`、`aperture.auto`、`aperture.<值>`、`photo.dimensions`。
- 动效只由真实状态驱动；`accessibilityReduceMotion` 时改为淡入淡出/静态；`TimelineView` ≤ 30fps 且仅 AI 开启时运行。
- 字体使用 `relativeTo`，`dynamicTypeSize(...(.accessibility1))` 限制 HUD。
- Agent 安全语义不变：单请求在途、过期丢弃、两次确认 + 稳定 + 3 秒倒计时、可取消、手动调参停止 AI。

## Review Focus

1. 倒计时进行中用户双指缩放或点变焦档位 → 倒计时取消、AI 停止、提示「你接管了变焦」，不会拍出一张变焦中的照片。（Task 7 真机检查；由 `takeOver` → `agent.stop()` → `validCountdown` 失效保证）
2. AI 设定了手动 ISO/快门后点按对焦 → 曝光参数保持 AI 设定，不被重置为光圈优先。（Task 3 真机检查项）
3. 设备 `maxAvailableVideoZoomFactor` < 2 → 变焦档位只显示 `1×`，双指缩放不越界。（Task 1 测试）
4. 拍到 48MP 照片后立即打开详情 → 不卡主线程，详情尺寸文本显示原图像素而不是预览图像素。（Task 1 测试 + Task 3）
5. 演示模式下相机状态回到 ready → 不会启动真实 Agent 循环、不发网络请求。（Task 6 测试）

---

### Task 1: CameraCore 纯逻辑

**Files:**
- Create: `CameraCore/Sources/CameraCore/ZoomStops.swift`
- Create: `CameraCore/Sources/CameraCore/ParameterDelta.swift`
- Create: `CameraCore/Sources/CameraCore/ValueOrigin.swift`
- Create: `CameraCore/Sources/CameraCore/PhotoMetadata.swift`
- Test: `CameraCore/Tests/CameraCoreTests/ZoomStopsTests.swift`、`ParameterDeltaTests.swift`、`ValueOriginTests.swift`、`PhotoMetadataTests.swift`

**Interfaces:**
- Produces:
  - `public enum ZoomStops { static func available(min: Double, max: Double, candidates: [Double] = [1, 2, 3]) -> [Double]; static func clamp(_ zoom: Double, min: Double, max: Double) -> Double }`
  - `public struct ParameterDelta: Identifiable, Equatable, Sendable { id: String; title: String; before: String; after: String; static func changed(_ items: [ParameterDelta]) -> [ParameterDelta] }`
  - `public enum ValueOrigin: Sendable { case automatic, user, ai; static func of(isManual: Bool, agentOwned: Bool) -> ValueOrigin }`
  - `public enum PhotoMetadata { static func normalized(_ metadata: [String: Any], width: Int, height: Int) -> [String: Any]; static func pixelSize(of data: Data) -> CGSize?; static func downsample(_ data: Data, maxPixel: Int) -> CGImage? }`

- [ ] **Step 1: 创建分支** `git switch -c ui-redesign`
- [ ] **Step 2: 写失败测试**
  - `availableStopsWithinRange`: `available(min: 1, max: 3) == [1, 2, 3]`；`available(min: 1, max: 1.8) == [1]`；`available(min: 1, max: 2.005) == [1, 2]`（容差 0.01）。
  - `clampKeepsZoomInRange`: `clamp(5, min: 1, max: 3) == 3`；`clamp(0.5, min: 1, max: 3) == 1`；`clamp(.nan, min: 1, max: 3) == 1`。
  - `changedDropsUnchangedValues`: 输入光圈 `ƒ/1.8→ƒ/4`、ISO `100→100`、画幅 `3:4→1:1`，输出 id 为 `["aperture", "ratio"]`。
  - `originMapping`: `of(isManual: false, agentOwned: true) == .automatic`；`of(true, true) == .ai`；`of(true, false) == .user`。
  - `normalizedResetsBothOrientations`: 输入 `[Orientation: 6, {TIFF}: [Orientation: 6], {Exif}: [:]]`，宽 300 高 400；输出顶层与 TIFF Orientation 均为 1，PixelWidth/Height 与 Exif PixelX/YDimension 为 300/400。
  - `pixelSizeReadsWithoutDecoding` 与 `downsampleLimitsLongestEdge`: 用 CoreGraphics 生成 1200×1600 JPEG；`pixelSize == 1200×1600`；`downsample(maxPixel: 600)` 结果最长边 600。
- [ ] **Step 3: 运行** `swift test --package-path CameraCore` → 新测试编译失败。
- [ ] **Step 4: 实现四个文件**（ImageIO：`CGImageSourceCopyPropertiesAtIndex` 读尺寸；`CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceCreateThumbnailFromImageAlways` + `kCGImageSourceCreateThumbnailWithTransform` + `kCGImageSourceThumbnailMaxPixelSize`）。
- [ ] **Step 5: 运行** `swift test --package-path CameraCore` → 全部通过（32 + 新增）。
- [ ] **Step 6: 提交** `feat(core): add zoom stops, parameter deltas, value origin and photo metadata helpers`

### Task 2: 主题与基础组件

**Files:**
- Create: `LogitCamera/Design/Theme.swift`、`ViewfinderFrame.swift`、`Toast.swift`、`AIButton.swift`

**Interfaces:**
- Produces:
  - `enum Theme { enum Palette { static let background, ink, inkSecondary, inkTertiary, hairline, accent, accentDim, warning: Color }; enum Typeface { static var readout, label, countdown: Font }; static func color(for: ValueOrigin) -> Color }`
  - `struct ViewfinderFrame: View { init(aiActive: Bool, scanTick: Int) }` — 四角 L 形刻线（18pt、1pt），AI 时 accent 3 秒呼吸；`scanTick` 变化时扫描线 0.9 秒自上而下，尾迹 24pt；减少动态效果时改为角标闪亮一次。`allowsHitTesting(false)`。
  - `struct Toast: View { init(text: String, isWarning: Bool, action: (title: String, run: () -> Void)?) }`
  - `struct AIButton: View { init(isOn: Bool, stage: AgentStage, action: () -> Void) }` — 48pt 圆，自绘 `LogitGlyph: Shape`（细线圆 + 偏心实心小圆，ready/countdown 时小圆居中，带 0.4s spring）；标识 `camera.ai`，value「已开启/已关闭」，`.isSelected`。

- [ ] **Step 1: 实现四个文件**，每个带 `#Preview`（黑底，AI 开/关两态）。
- [ ] **Step 2: 构建** `bash scripts/build.sh` → `** BUILD SUCCEEDED **`，无新增 warning（`grep -c "warning:"` 与基线比较，基线在开工前记录）。
- [ ] **Step 3: 提交** `feat(ui): add Logit theme, viewfinder frame, toast and AI button`

### Task 3: 状态层与交互修正

**Files:**
- Modify: `LogitCamera/CameraAgent.swift`、`CameraModel.swift`、`CameraState.swift`、`CaptureSession.swift`、`CaptureSession+Agent.swift`、`CaptureSession+Exposure.swift`、`PhotoCapture.swift`、`PhotoFraming.swift`

**Interfaces:**
- Consumes: Task 1 全部。
- Produces:
  - `CameraAgent`: `var observationTick: Int`（每轮首次 `capture.observation()` 成功后 +1）；`var adjustmentID: UUID?`（adjust 回读后赋新值）；`var changes: [ParameterDelta]`（经 `ParameterDelta.changed`，删除 `AgentParameterChange`）；`@ObservationIgnored var demoLocked = false`（为 true 时 `resume` 直接返回）。
  - `CameraState`: `var minZoom: Float = 1`、`var maxZoom: Float = 1`（configure 时取 `minAvailableVideoZoomFactor` 与 `min(3, maxAvailableVideoZoomFactor)`）。
  - `CameraText.bias(_ value: Float) -> String`（`±0.0` / `+0.3` / `-1.0`）。
  - `CameraModel`: `var agentOwnsSettings: Bool`（agent adjust 成功置 true；任何用户接管或 reset 置 false）；`var noticeOffersResume: Bool`；`var preview: UIImage?`（≤ 2400px）；`var thumbnail: UIImage?`（≤ 600px）；`var photoPixelSize: CGSize?`；`func setZoom(_ value: Double)`；`func origin(isManual: Bool) -> ValueOrigin`。
  - `CaptureSession.setZoom(_ factor: Double)` 用 `ramp(toVideoZoomFactor:withRate: 8)`，值经 `ZoomStops.clamp`。

- [ ] **Step 1: CameraAgent** — 新字段；`setAutoCapture` 只在 `isEnabled` 时改 `stage`（修复 4.1-6）；`changes` 用 `ParameterDelta`。
- [ ] **Step 2: CameraModel**
  - `focus` 不再 `agent.stop()`（4.1-2）。
  - `takePhoto()` 不再设 `captureArmed = false`；改在 `takeAutomaticPhoto()` 中设置（4.1-4）。
  - `receive(.state)`：记录上一 phase，只在 ready → 非 ready 时 `agent.pause()` 一次（4.1-5）。
  - 私有 `takeOver(_ parameter: String)`：若 AI 开启则 `agent.stop()`，`notice = "你接管了\(parameter) · AI 已停止"`，`noticeOffersResume = true`；`setRatio`（画幅）、`setAperture`（光圈）、`setExposureBias`（曝光补偿）、`setZoom`（变焦）、`resetCamera`（参数）调用它。
  - `.photo` 事件：`Task.detached` 中用 `PhotoMetadata.downsample` 生成 600 与 2400 两张、`pixelSize` 取尺寸，回主线程赋值（4.1-3）。
  - `notice` 设置后 4 秒自动清空（用 `Task` + 文本相等检查，避免清掉新提示）。
- [ ] **Step 3: CaptureSession** — `configure` 写 `minZoom/maxZoom`；`setZoom`；`apply` 中 `videoZoomFactor =` 改为 ramp；`focus` 在 `selectedISO != nil || selectedShutter != nil` 时只设置兴趣点、不调用 `applyExposureLocked`；硬件超时分支 `timer?.cancel(); timer = nil`。
- [ ] **Step 4: PhotoFraming** 用 `PhotoMetadata.normalized` 替换手写元数据（4.1-7）。
- [ ] **Step 5: 构建** `bash scripts/build.sh` → 成功（旧 UI 文件此时会因 `AgentParameterChange` 删除而需要最小改动；本任务内把 `CameraAgentPanel.parameterChange` 改为接收 `ParameterDelta` 以保持可编译）。
- [ ] **Step 6: 提交** `fix: keep AI on tap-to-focus, background thumbnails, takeover notices, zoom ramp`

### Task 4: AI 与读数组件

**Files:**
- Create: `LogitCamera/Design/HUDReadoutBar.swift`、`AIStatusLine.swift`、`AIAnnotation.swift`、`AIDetailSheet.swift`、`ShutterButton.swift`、`ZoomSelector.swift`、`ManualDial.swift`

**Interfaces:**
- Consumes: Task 1–3。
- Produces（全部 `let model: CameraModel` 除非注明）：
  - `HUDReadoutBar(model:, dialOpen: Binding<Bool>)` — 画幅 `Menu`、读数按钮（切换 `dialOpen`，标识 `camera.controls`）、设置按钮（`camera.aiSettings`）；光圈文本标识 `camera.aperture`；颜色取 `Theme.color(for: model.origin(isManual:))`。
  - `AIStatusLine(agent: CameraAgent, onOpen: () -> Void)` — 28pt 单行按钮，状态点 + 阶段文本 + 「第 N 轮」+ 两枚确认点；标识 `camera.agent`，value「第 N 轮」。阶段文本映射：observing「观察中」、thinking「分析中」、applying「调整中」、verifying「复核中」、ready「准备拍摄」、countdown「即将拍摄」、paused「已暂停」。
  - `AIAnnotation(agent: CameraAgent)` — 监听 `adjustmentID`，显示 `changes`（`before → after`，accent 等宽）+ `· reason`（最多两行），4 秒淡出。
  - `AIDetailSheet(model:)` — 阶段 + 完整理由、变化表、自动拍摄 `Toggle`（`camera.autoCapture`）、「再拍一张」（`camera.rearm`）、模型名与图像发送提示；detents `.medium, .large`。
  - `ShutterButton(model:)` — 78pt 外环 + 64pt 内圆；倒计时时外环为 accent 进度环（`countdown` 3→0 线性），环内秒数（标识 `camera.countdown`），按钮动作改为 `cancelAutoCapture`、标识 `camera.cancelCapture`；否则 `camera.shutter`。保留 `.sensoryFeedback`。
  - `ZoomSelector(model:)` — 档位来自 `ZoomStops.available`，只有一个档位时隐藏；当前值非整档时显示精确倍率（`1.4×`）；AI 设定时 accent。
  - `ManualDial(model:)` — 分段「光圈 / EV」；光圈为档位按钮横排（`aperture.auto`、`aperture.<Float 描述>`，与旧标识一致），无推荐档位时 `Slider`；EV 刻度尺 -2…+2（0.1 小刻度、1.0 大刻度），拖动吸附，松手调用 `setExposureBias`；底部「全部自动」调用 `resetCamera`。
- [ ] **Step 1: 实现七个文件**，各带 `#Preview`。
- [ ] **Step 2: 构建** → 成功。
- [ ] **Step 3: 提交** `feat(ui): add HUD readout, AI status line, annotation, detail sheet, shutter, zoom and manual dial`

### Task 5: 组装主界面与设置页，删除旧 UI

**Files:**
- Modify: `LogitCamera/CameraView.swift`、`PhotoDetailView.swift`、`CameraPreview.swift`
- Create: `LogitCamera/SettingsView.swift`
- Delete: `LogitCamera/CameraAgentPanel.swift`、`CameraChrome.swift`、`ApertureControls.swift`、`AISettingsView.swift`

**Interfaces:**
- Consumes: Task 2–4。`CameraModel.showsInfo` 删除，`showsAISettings` 改名 `showsSettings`；新增 `showsAgentDetail`。

- [ ] **Step 1: CameraView** 按规格 §3 布局：`HUDReadoutBar` / 取景（`CameraPreview` + `ViewfinderFrame(aiActive: agent.isEnabled, scanTick: agent.observationTick)` + `AIAnnotation` + 状态浮层）/ `Toast` / `ZoomSelector` / `ManualDial`（`dialOpen` 时）/ `AIStatusLine` / 操作栏。控制区高度用 `onGeometryChange` 测量，替代魔数 `132`；取景加 `MagnifyGesture` 调用 `setZoom`；点取景区时若 `dialOpen` 先收起拨盘。全局 `.tint(Theme.Palette.accent)`。
- [ ] **Step 2: CameraPreview** 对焦框颜色参数化：`init(session:, onFocus:, markerColor: UIColor)`。
- [ ] **Step 3: SettingsView** 合并五个分组（规格 §3.9）；`PhotoDetailView` 使用 `model.preview`、`photoPixelSize`（标识 `photo.dimensions`）并套用主题。
- [ ] **Step 4: 删除旧文件；`LogitCameraApp` 中 `.tint(.yellow)` 改为 accent。**
- [ ] **Step 5: 构建** → 成功；`grep -rn "yellow\|DeepSeek" LogitCamera --include=*.swift` 只剩 `AICredentials`/`DeepSeekClient`/`SettingsView` 的模型说明。
- [ ] **Step 6: 提交** `feat(ui): assemble instrument-style camera screen and unified settings`

### Task 6: 演示模式与截图测试，适配现有 UI 测试

**Files:**
- Create: `LogitCamera/DemoScenario.swift`（整文件 `#if DEBUG`）
- Create: `CameraUITests/DesignScreenshotTests.swift`
- Modify: `LogitCamera/CameraModel.swift`（`activate()` 中调用 demo 钩子）、`CameraUITests/ApertureTests.swift`、`CameraUITests/CompositionTests.swift`

**Interfaces:**
- Produces: `enum DemoScenario: String, CaseIterable { case idle, observing, adjusted, ready, countdown, manual, error; static var current: DemoScenario? /* 读 -LogitDemo 参数 */ }`；`extension CameraModel { func applyDemo(_ s: DemoScenario) }`，设置 `agent.demoLocked = true` 后直接写 agent 展示字段（不调用 `enable`），`observing` 用定时 `Task` 每 5 秒 `observationTick += 1`。

- [ ] **Step 1: 写测试** `DesignScreenshotTests.testCaptureEveryScenario`：对每个场景 `app.launchArguments = ["-LogitDemo", s]`，等待 `camera.shutter` 存在，附加截图（`lifetime = .keepAlways`，名称为场景名）；`observing` 场景断言 10 秒内 `camera.agent` 的 value 不变（Review Focus 5：不发生真实轮次）。
- [ ] **Step 2: 实现 DemoScenario 与钩子。**
- [ ] **Step 3: 适配旧测试**：自动拍摄开关前先点 `camera.agent` 打开详情；拨盘需先点 `camera.controls`（标识不变）。
- [ ] **Step 4: 构建测试包** `xcodebuild build-for-testing -project LogitCamera.xcodeproj -scheme LogitCamera -destination 'id=00008160-001C25282680000A' -allowProvisioningUpdates` → 成功。
- [ ] **Step 5: 提交** `test: add debug demo scenarios and design screenshot test`

### Task 7: 真机验证

- [ ] **Step 1:** `swift test --package-path CameraCore` → 全部通过。
- [ ] **Step 2:** 真机跑 `-only-testing:CameraUITests/DesignScreenshotTests`，用 `xcrun xcresulttool export attachments` 导出截图，传回云端审阅；对照规格逐项检查（遮挡、颜色归属、倒计时环、标注、状态线）。发现问题回到对应任务修复。
- [ ] **Step 3:** 告知用户将消耗 API 额度后，跑 `ApertureTests` 与 `CompositionTests`，记录结果；真机手动检查 Review Focus 1、2。
- [ ] **Step 4:** 更新 README「操作」一节与截图说明；提交 `docs: describe redesigned camera UI`。
