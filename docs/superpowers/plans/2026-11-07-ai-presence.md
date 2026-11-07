# AI 存在感 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal：** 用青色极光边缘、呼吸光晕、看得见的动作和人话字幕取代技术化的 AI 界面。

**Architecture：** CameraCore 里有两个纯函数模型：`CaptionDirector` 决定字幕，`PresenceModel` 决定光效参数。App 层的 `Design/Presence/` 组件用 TimelineView 渲染它们。

**Tech Stack：** SwiftUI（iOS 27）、Swift Testing、XCUITest。

**Spec：** `docs/superpowers/specs/2026-11-07-ai-presence-design.md`

## Global Constraints

- 只用品牌青及规格 §1 列出的三种辅助色；AI 关闭时不渲染任何光效。
- 字幕一次一句，最多 16 字，2.5 秒后淡出，同一句话 8 秒内不重复。
- 必须支持减少动态效果。
- 用户要求开发过程中不运行测试，测试放到最后（Task 6）统一运行。

## Review Focus

1. 主体在画面里快速移动时，光晕和角框要跟得上，不能闪烁。
2. AI 刚开启时的状态快速切换（侦察 → 计划 → 拍下）不能让字幕刷屏。
3. 减少动态效果时没有持续的动画。
4. 光效不能挡住点按对焦和双指缩放。

### Task 1：CaptionDirector 与 PresenceModel（CameraCore）

**Files：**
- Create：`CameraCore/Sources/CameraCore/Presence/CaptionDirector.swift`、`PresenceModel.swift`。
- Test：`CameraCore/Tests/CameraCoreTests/CaptionDirectorTests.swift`、`PresenceModelTests.swift`。

**Interfaces：**
- `struct CaptionSnapshot { phase: AgentPhase; isOffline: Bool; genre: GenreID?; genreName: String?; isDefaultPlan: Bool; planID: UUID?; rationale: String?; lens: LensStop?; depth: DepthIntent?; waitingFor: Trigger.Kind?; starved: Bool; capturedAutomatically: Bool; pickedAt: TimeInterval? }`
- `struct CaptionDirector { mutating update(_ s: CaptionSnapshot, now: TimeInterval) -> String? }`：返回当前应显示的字幕，nil 表示不显示。常量：`lifetime 2.5`、`repeatWindow 8`、`waitHold 1.5`、`maxLength 16`。
- `static func lensPhrase(_ stop: LensStop, depth: DepthIntent?) -> String`
- `struct PresenceInput { phase: AgentPhase; readiness: Double; subject: NormalizedRect?; crop: NormalizedRect; time: TimeInterval; reduceMotion: Bool }`
- `struct PresenceFrame { auroraOpacity, auroraWidth, auroraAngle (度), haloOpacity, haloRadius: Double; gaze: NormalizedPoint; gradientCenter: NormalizedPoint; breathing: Bool }`
- `enum PresenceModel { static func frame(_ input: PresenceInput, captureProgress: Double?) -> PresenceFrame }`

- [ ] 测试：
  - `captionPriorityPickedOverWaiting`
  - `captionTruncatesTo16`
  - `captionDoesNotRepeatWithin8s`
  - `waitingNeedsHold`
  - `lensPhraseByIntent`
  - `rationaleFirstClause`
  - `scoutingCaptionOnce`
  - `presenceObservingIsSlowAndDim`
  - `presenceGazeFollowsSubject`
  - `presenceBreathesWhenReady`
  - `presenceCollapsesOnCapture`
  - `presenceReduceMotionIsStatic`
- [ ] 实现上述两个模型。编译通过后提交：`feat(core): caption director and presence model`。

### Task 2：光效组件

**Files：** Create `LogitCamera/Design/Presence/AuroraEdge.swift`、`AttentionHalo.swift`、`CaptureFlash.swift`、`AICaption.swift`。

- [ ] `AuroraEdge(frame: PresenceFrame, rect: CGRect)`：
  - 用 `AngularGradient` 描边圆角矩形（圆角 4），渐变中心取 `gradientCenter`。
  - 外加一层 `.blur(radius: 14)` 的光晕描边。
  - 光效层 `allowsHitTesting(false)`、`accessibilityHidden(true)`。
- [ ] `AttentionHalo`：`RadialGradient` 加 `blendMode(.screen)`，外加压暗的径向渐变。
- [ ] `CaptureFlash(trigger:)`：白色叠层，用 keyframe 做闪白动画（0.45 秒，峰值 0.85）。
- [ ] `AICaption(text:)`：字幕样式，带淡入淡出；文字变化时发出无障碍播报。

### Task 3：选片动画与数据

**Files：** Create `LogitCamera/Design/Presence/BurstFilmstrip.swift`；Modify `CameraModel.swift`（`burstPreview`）。

- [ ] `struct BurstPreview: Identifiable { id: UUID; thumbnails: [UIImage]; chosen: Int }`：在 `select()` 的分析任务里顺便生成长边 120 px 的缩略图；选片完成时发布，2.4 秒后清空。
- [ ] `BurstFilmstrip(preview:)`：缩略图依次弹出，被选中的那张抬起、描青边、标「AI 选择」，之后整组淡出。

### Task 4：接入取景界面

**Files：**
- Modify：`CameraView.swift`、`AIStatusLine.swift`、`CropOverlay.swift`、`ViewfinderFrame.swift`、`AgentController.swift`。
- Delete：`AIAnnotation.swift`。

- [ ] AgentController：
  - 每次测量后用 `CaptionDirector.update` 刷新 `caption`；
  - 自动拍下时记下 `capturedAutomatically`；
  - 选片完成时由 CameraModel 调用 `agent.picked(at:)`。
- [ ] CameraView 的叠层从下到上：画面 → 光晕 → 裁切压暗 → 极光（沿裁切框）→ 主体角框（弹簧析出）→ 闪白 → 字幕 → 选片缩略图。
- [ ] ViewfinderFrame：AI 开启时不再画扫描线和青色角标，只在 AI 关闭时显示白色角标。
- [ ] AIStatusLine 改为人话短句，删除 TriggerChips。保留 `camera.agent` 标识和「第 N 轮」取值。

### Task 5：演示场景与文档

- [ ] DemoScenario 新增 `picking` 场景（设置 `burstPreview` 并配合字幕）；其他场景补上字幕。
- [ ] 更新 `README.md` 和 `docs/agent-loop.md` 中描述界面的段落。

### Task 6：统一测试

- [ ] 运行 `swift test`：全部通过。
- [ ] 真机运行 DesignScreenshotTests（包括 picking）、InteractionTests、ApertureTests、CompositionTests 的画幅用例，并检查截图。
- [ ] 真机实测：开 AI 对着房间，检查光效、字幕和选片动画；同时验证上一轮的无极变焦（0.5×–40×）。
