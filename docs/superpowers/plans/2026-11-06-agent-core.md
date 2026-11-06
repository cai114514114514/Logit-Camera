# Agent 内核重设计 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用「导演（DeepSeek 两档）+ 本地摄影助理（感知、执行、条件触发）」取代现有 `CameraAgent` 轮询循环，让 AI 按题材知识库与七项量表做有证据的审美判断，并以偏心裁切构图、就绪即拍。

**Architecture:** 可测试的一切放进 CameraCore（数据类型、求解器、条件判定、量表、知识库、调度状态机、曝光控制律、DeepSeek 适配器）；App 只负责 Vision/vImage/CoreMotion 感知、相机硬件执行与 UI。模型只产出方案与评分，执行层是唯一硬件写入入口。

**Tech Stack:** Swift 6、SwiftUI（iOS 27）、AVFoundation、Vision（Swift API）、Accelerate/vImage、CoreMotion、URLSession、Swift Testing、XCUITest。所有命令经 Mac Bridge 在 `/Users/wangzhe/Logit Camera`（分支 `agent-core`）执行。

**Spec:** `docs/superpowers/specs/2026-11-06-agent-core-design.md`

## Global Constraints

- iOS 27.0、Swift 6 严格并发；不新增第三方依赖。CameraCore `Package.swift` 增加 `platforms: [.iOS(.v27), .macOS(.v26)]`。
- 模型：仅 `deepseek-flash`。scout：`thinking.type = disabled`、`detail: low`；judge：`thinking.type = enabled`、`reasoning_effort: high`、`detail: original`。严格工具走 `https://api.deepseek.com/beta/chat/completions`，每个函数 `"strict": true`、`additionalProperties: false`、全部属性 required；schema 不使用 string minLength/maxLength、array minItems/maxItems。
- judge 带工具时回传该场景上一次 judge 的 `reasoning_content`；场景变化或新方案后清空。
- 坐标：直立全画幅归一化坐标，原点左上，x 向右、y 向下。
- 量表：七项 0–4 整数；放行 = 加权总分 ≥ 3.0 且每项 > 1；模型 verdict 只能更严。
- 调度阈值：scout 场景变化 0.18 持续 0.5 s、主体丢失 1 s、心跳 15 s、最短间隔 2 s；judge 最短间隔 4 s；放行时效 10 s、漂移 0.08；过期丢弃 12 s / 0.18。
- 执行：曝光 10 Hz，步长 ≤ 0.1 EV，死区 ±0.1 EV；对焦点位移 > 0.05 才更新；弹簧时间常数 0.35 s；`minCropArea` 默认 0.25；`holdMs` 默认 200；测量超过 300 ms 视为过期。
- 没有 judge 放行永不自动拍摄；手动调参即停止 AI；后台/中断暂停；模型无硬件与快门权限。
- 用户可见文案中文；UI 不出现「DeepSeek」（设置页与 AIError 除外）；保留现有无障碍标识，新增元素加 `camera.*` 标识。

## Review Focus

1. 已就绪时主体走出画面或跟踪丢失 → 不能拍；有主体的方案隐含 `subjectPresent` 条件。（Task 2 测试 `armedPlanNeverFiresWithoutSubject`）
2. judge 响应返回时用户已接管或 AI 已关闭 → 响应被丢弃，不改变状态。（Task 6 测试 `responseAfterStopIsIgnored`）
3. 主体贴边且锚点不可达、并且照片带 EXIF 旋转 → 裁切框仍在图内，像素裁切方向正确。（Task 3 `clampsAtSensorEdge`、Task 10 `pixelRectRespectsOrientation`）
4. judge 返回 `finish_reason: length`、没有工具调用、多个工具调用或 schema 外字段 → 解析失败计为一次失败，不崩溃。（Task 7 `malformedRepliesAreFailures`）
5. 设备发热导致感知降频、测量变旧 → 条件判定视为不满足，不会凭旧数据开快门。（Task 2 `staleMeasurementSatisfiesNothing`）

---

## 阶段 1：CameraCore 纯逻辑

### Task 1: 测量与方案类型

**Files:**
- Modify: `CameraCore/Package.swift`（platforms、resources、`LogitEval` 目标在 Task 14 加）
- Create: `CameraCore/Sources/CameraCore/Agent/SceneMeasurement.swift`、`ShotPlan.swift`、`Genre.swift`
- Test: `CameraCore/Tests/CameraCoreTests/ShotPlanTests.swift`

**Interfaces — Produces:**
- `struct NormalizedRect: Codable, Sendable, Equatable { x, y, width, height: Double; var center: NormalizedPoint; func clamped() -> NormalizedRect }`、`struct NormalizedPoint { x, y: Double }`
- `enum SubjectKind: String, Codable { face, body, salient, none }`
- `struct Subject: Codable, Sendable, Equatable { id: Int; kind: SubjectKind; box: NormalizedRect; confidence: Double; yaw, pitch, roll: Double?; eyeOpenness: Double?; faceQuality: Double? }`（eyeOpenness 取左右较小值，0–1）
- `struct SceneMeasurement: Codable, Sendable { timestamp: TimeInterval; subjects: [Subject]; primarySubjectID: Int?; luminance: LuminanceStats; sharpness: Sharpness; horizonDegrees: Double?; deviceAngularSpeed: Double; subjectSpeed: Double; sceneChange: Double; aesthetics: AestheticsHint?; var primarySubject: Subject? }`
- `LuminanceStats { histogram: [Double] /*64*/; clipHigh, clipLow, mean: Double; subjectMean: Double? }`、`Sharpness { global: Double; subject: Double? }`、`AestheticsHint { score: Double; isUtility: Bool; labels: [String] }`
- `enum GenreID: String, Codable, CaseIterable { portrait, group, street, landscape, architecture, food, still, night, animal, document, general }`
- `struct ShotPlan: Codable, Sendable, Equatable { id: UUID; genre: GenreID; genreConfidence: Double; subject: SubjectKind; composition: Composition; exposure: ExposureIntent; triggers: [Trigger]; holdMs: Int; rationale: String; intentWeights: [String: Double]?; look: String?; func validate(against: CameraLimits) throws }`
- `Composition { ratio: FrameRatio; anchor: NormalizedPoint; subjectSize: ClosedRangeCodable; minCropArea: Double; levelHorizon: Bool }`、`ExposureIntent { meter: MeterMode; subjectEV: Double; highlightClipMax: Double; aperture: ApertureIntent; shutterFloor: Double?; isoCeiling: Double? }`
- `enum Trigger: Codable, Sendable, Equatable { subjectSharp(min: Double), eyesOpen(min: Double), faceToward(maxYaw: Double), horizonLevel(maxDegrees: Double), deviceStill(maxRadPerSec: Double), subjectPlaced(maxError: Double), highlightsSafe(maxClip: Double), exposureSettled, subjectPresent }`，JSON 形如 `{"kind":"eyesOpen","threshold":0.6}`
- 校验错误：`enum PlanValidationError: Error, Equatable { outOfRange(String), unsupportedAperture, invalidRange(String) }`

- [ ] **Step 1: 写失败测试** `defaultPlanValidates`、`anchorOutsideUnitSquareIsRejected`（anchor.x = 1.2 → `.outOfRange("anchor")`）、`subjectSizeMinAboveMaxIsRejected`、`minCropAreaBelowQuarterIsRejected`（0.2 → `.outOfRange("minCropArea")`）、`apertureOutsideLimitsIsRejected`、`triggerJSONRoundTrips`（每种 Trigger 编码再解码相等，`{"kind":"exposureSettled"}` 无 threshold）、`nullReservedFieldsDecode`。
- [ ] **Step 2: 运行** `swift test --package-path CameraCore` → 编译失败（类型不存在）。
- [ ] **Step 3: 实现**三个文件；`ShotPlan.validate` 检查：genreConfidence、anchor ∈ [0,1]、subjectSize 0.05…1 且 min ≤ max、minCropArea 0.25…1、subjectEV −2…2、highlightClipMax 0…0.05、holdMs 0…1000、aperture prefer 值在 limits 内、shutterFloor 在 limits 内、isoCeiling ≥ minISO、阈值范围（eyesOpen/subjectSharp 0…1、角度 0…45、角速度 0…2、maxError 0…0.5、maxClip 0…0.05）。
- [ ] **Step 4: 运行** → 全部通过。
- [ ] **Step 5: 提交** `feat(core): add scene measurement and shot plan types`

### Task 2: 条件判定 TriggerEvaluator

**Files:** Create `CameraCore/Sources/CameraCore/Agent/TriggerEvaluator.swift`；Test `TriggerEvaluatorTests.swift`

**Interfaces:**
- Consumes: Task 1。
- Produces: `struct TriggerStatus: Sendable, Equatable { trigger: Trigger; satisfied: Bool; margin: Double /* ≥0 满足，<0 未满足，按阈值归一 */ }`；`struct TriggerEvaluator { init(plan: ShotPlan); mutating func update(_ m: SceneMeasurement, now: TimeInterval, placementError: Double, exposureSettled: Bool) -> TriggerReport }`；`struct TriggerReport { statuses: [TriggerStatus]; allSatisfied: Bool; sustained: Bool /* allSatisfied 已持续 holdMs */; nearlyReady: Bool /* 全部满足，或仅一项未满足且 margin ≥ -0.2 */ }`
- 规则：plan.subject != .none 时隐含 `subjectPresent`；`now - m.timestamp > 0.3` 时所有条件不满足；任一帧不满足即重置持续计时。

- [ ] **Step 1: 写失败测试** `eyesOpenUsesSmallerEye`、`horizonUsesAbsoluteAngle`、`missingHorizonFailsLevelCondition`、`sustainedRequiresHoldMs`（hold 200：t=0 满足 → sustained false；t=0.21 → true）、`singleFailingFrameResetsHold`、`armedPlanNeverFiresWithoutSubject`、`staleMeasurementSatisfiesNothing`（timestamp 0.4 s 前）、`nearlyReadyAllowsOneCloseMiss`（一项 margin −0.1 → true；−0.3 → false；两项未满足 → false）。
- [ ] **Step 2: 运行** → 失败。
- [ ] **Step 3: 实现**；margin = (实际 − 阈值)/阈值（上限类取反）。
- [ ] **Step 4: 运行** → 通过。
- [ ] **Step 5: 提交** `feat(core): add trigger evaluator`

### Task 3: 构图求解器与弹簧

**Files:** Create `Agent/CompositionSolver.swift`、`Agent/Spring.swift`；Test `CompositionSolverTests.swift`

**Interfaces — Produces:**
- `struct CompositionTarget: Equatable { crop: NormalizedRect; placementError: Double }`
- `enum CompositionSolver { static func solve(subject: NormalizedRect?, composition: Composition, sensorAspect: Double /* 宽/高，竖屏 0.75 */, salientCenter: NormalizedPoint?) -> CompositionTarget }`
- `struct CropSpring { init(timeConstant: Double = 0.35); mutating func step(toward: NormalizedRect, dt: Double) -> NormalizedRect; mutating func reset(to: NormalizedRect) }`（临界阻尼，分量独立）
- 算法：裁切高度 h = 主体高 / subjectSize 中点；宽 = h × ratio.widthToHeight / sensorAspect（归一化单位换算）；面积不小于 minCropArea 且不超出传感器（等比缩放）；位置使主体中心落在 anchor；夹在 [0,1]；placementError = 夹取后主体中心与目标锚点距离（裁切框归一化单位）。无主体：以 salientCenter 或 (0.5,0.5) 为参照，尺寸取最大允许值。

- [ ] **Step 1: 写失败测试** `centeredSubjectLandsOnAnchor`（误差 < 1e-6）、`cropKeepsRatio`（像素纵横比 = ratio，容差 1e-6）、`respectsMinCropArea`、`clampsAtSensorEdge`（主体在 x=0.95 → crop 在 [0,1] 内且 placementError > 0）、`noSubjectUsesLargestCrop`、`springConvergesWithoutOvershoot`（目标阶跃，2 s 内误差 < 0.01，过程中单调）、`springStaysInsideSensor`。
- [ ] **Step 2: 运行** → 失败。 **Step 3: 实现。** **Step 4: 运行** → 通过。
- [ ] **Step 5: 提交** `feat(core): add composition solver and crop spring`

### Task 4: 量表、知识库与提示词资源

**Files:**
- Create: `Agent/Rubric.swift`、`Agent/Knowledge.swift`
- Create resources: `CameraCore/Sources/CameraCore/Resources/Knowledge/rubric.json`、`genres/{portrait,group,street,landscape,architecture,food,still,night,animal,document,general}.json`、`prompts/system.md`、`prompts/scout.md`、`prompts/judge.md`
- Modify: `Package.swift`（`resources: [.copy("Resources/Knowledge")]`）
- Test: `RubricTests.swift`、`KnowledgeTests.swift`

**Interfaces — Produces:**
- `enum RubricCriterion: String, Codable, CaseIterable { clarity, exposure, composition, light, background, moment, genre }`
- `struct RubricScore: Codable, Equatable { criterion: RubricCriterion; score: Int; evidence: String }`
- `enum Verdict: String, Codable { approve, wait, revise }`
- `struct RubricResult: Codable, Equatable { scores: [RubricScore]; modelVerdict: Verdict; func weighted(_ weights: [RubricCriterion: Double]) -> Double; func verdict(weights:) -> Verdict /* 规则：缺项或任一 ≤1 → wait；加权 < 3.0 → wait；否则取 modelVerdict 与 approve 中更严者 */ }`
- `struct GenrePlaybook: Codable { id: GenreID; name: String; cues: Cues; principles: Principles; rubricWeights: [RubricCriterion: Double]; genreCriterion: Anchor; defaultPlan: ShotPlan; spaqCategories: [String] }`
- `enum Knowledge { static func playbook(_ id: GenreID) throws -> GenrePlaybook; static func allPlaybooks() throws -> [GenrePlaybook]; static func rubricAnchors() throws -> [RubricCriterion: Anchor]; static func prompt(_ name: PromptName) throws -> String }`（`Bundle.module`）
- 打法内容要求：每组原则 3–6 条具体规则（含数字或可观察特征），中文；人像、合影、街拍默认含 `eyesOpen`/`faceToward`；风光、建筑默认 `horizonLevel`；夜景 `deviceStill(0.05)` 且 `shutterFloor` 为空、`isoCeiling` 3200；文档 `subject: none`、权重只给 clarity 0.6、exposure 0.4。

- [ ] **Step 1: 写失败测试** `verdictRequiresEveryCriterionAboveOne`、`verdictRequiresWeightedThree`（全 3 分 → approve；全 3 分但一项 1 → wait）、`modelCannotLoosenVerdict`（规则 wait + 模型 approve → wait；规则 approve + 模型 wait → wait）、`missingCriterionIsWait`、`allGenresLoad`、`weightsSumToOne`（容差 1e-6）、`defaultPlansValidate`（对一组典型 CameraLimits）、`everyGenreHasPrinciples`（每组 3–6 条）、`spaqCategoriesCoverAllNine`、`promptsExistAndMentionTools`（judge.md 含 `set_plan`、`keep_plan`；scout.md 含 `classify_scene`）。
- [ ] **Step 2: 运行** → 失败。 **Step 3: 实现代码并撰写 11 个打法、量表锚定与三份提示词。** **Step 4: 运行** → 通过。
- [ ] **Step 5: 提交** `feat(core): add rubric, genre playbooks and prompts`

### Task 5: 测量算法 MeasurementMath

**Files:** Create `Agent/MeasurementMath.swift`；Test `MeasurementMathTests.swift`

**Interfaces — Produces:**（输入为 8 位灰度缓冲 `LumaImage { width, height: Int; bytes: [UInt8] }`）
- `static func luminance(_ image: LumaImage, subject: NormalizedRect?) -> LuminanceStats`（64 档归一化直方图；clipHigh ≥ 250、clipLow ≤ 5）
- `static func sharpness(_ image: LumaImage, region: NormalizedRect?) -> Double`（3×3 拉普拉斯方差 / (均值² + 1)，映射到 0–1：`v / (v + 0.02)`）
- `static func eyeOpenness(eye: [NormalizedPoint]) -> Double?`（6 点眼部纵横比 EAR，`min(1, EAR / 0.3)`；点数不足返回 nil）
- `static func signature(_ image: LumaImage) -> [UInt8]`（16×16 均值）与 `static func sceneChange(_ a: [UInt8], _ b: [UInt8]) -> Double`（与 `CameraFrame.difference` 相同的去均值 L1，迁移该算法并让 `CameraFrame` 调用它）

- [ ] **Step 1: 写失败测试** `uniformGrayHasNoClipping`、`whiteImageClipsHigh`、`subjectMeanUsesRegion`、`checkerboardIsSharperThanBlur`、`flatImageHasZeroSharpness`、`openEyeScoresHigherThanClosed`、`sceneChangeIgnoresGlobalBrightness`（整体 +30 → < 0.01）、`sceneChangeDetectsShift`。
- [ ] **Step 2–4:** 运行失败 → 实现 → 通过（并跑全量 swift test）。
- [ ] **Step 5: 提交** `feat(core): add measurement math`

### Task 6: 调度状态机 DirectorScheduler

**Files:** Create `Agent/DirectorScheduler.swift`；Test `DirectorSchedulerTests.swift`

**Interfaces — Produces:**
- `enum AgentPhase: String, Codable, Sendable { off, scouting, planning, tracking, reviewing, armed, capturing, cooldown, paused }`
- `enum SchedulerEvent: Sendable { start, stop, pause, resume, measurement(SceneMeasurement, TriggerReport), scoutReply(generation: Int, ScoutResult), judgeReply(generation: Int, JudgeResult), requestFailed(generation: Int, retryable: Bool), captured, rearm }`
- `enum SchedulerCommand: Equatable, Sendable { callScout, callJudge(JudgeMode /* plan | approve */), fire, none }`
- `struct ScoutResult: Codable, Equatable { genre: GenreID; confidence: Double; sceneChanged: Bool; planStillValid: Bool; subjectHint: SubjectKind; reason: String }`
- `enum JudgeResult: Equatable { setPlan(ShotPlan, RubricResult), keepPlan(RubricResult, reason: String) }`
- `struct DirectorScheduler { private(set) var phase: AgentPhase; private(set) var plan: ShotPlan?; private(set) var generation: Int; private(set) var inFlight: Bool; private(set) var memoryReset: Bool /* 读取后由控制器清零 */; mutating func handle(_ event: SchedulerEvent, now: TimeInterval) -> SchedulerCommand }`
- `start` 时立即采用 `general` 打法的默认方案（仅用于执行层辅助对焦、曝光、构图，**不会放行**），随后 scout 结果决定正式方案；断网时保持此状态。场景变化或新方案时清空 JudgeMemory（由 Task 12 的控制器执行，scheduler 输出 `memoryReset` 标志）。
- 规则见 Global Constraints；`approve` 仅当 `RubricResult.verdict(weights: playbook.rubricWeights) == .approve` 才进入 `armed`；`armed` + `report.sustained` → `.fire` 并进入 `capturing`；`captured` → `cooldown`；`cooldown` 中 sceneChange > 0.18 持续 0.5 s → `scouting`；`rearm` → `tracking`；回复的 generation 不等于当前值即忽略；失败退避 5,10,20,30 s。

- [ ] **Step 1: 写失败测试** `startCallsScout`、`newGenreRequestsPlan`、`setPlanEntersTracking`、`nearlyReadyRequestsApproval`、`approveArmsOnlyWhenRubricPasses`、`armedFiresWhenSustained`、`approvalExpiresAfterTenSeconds`、`driftDisarms`、`sceneChangeTriggersScoutAfterHalfSecond`、`scoutRespectsTwoSecondSpacing`、`judgeRespectsFourSecondSpacing`、`heartbeatAfterFifteenSeconds`、`onlyOneRequestInFlight`、`responseAfterStopIsIgnored`、`staleGenerationIsIgnored`、`cooldownRearmsOnSceneChange`、`failuresBackOff`、`pauseKeepsPlanButStopsFiring`、`startAppliesGeneralDefaultPlanWithoutArming`、`newPlanResetsJudgeMemory`。
- [ ] **Step 2–4:** 失败 → 实现 → 通过。
- [ ] **Step 5: 提交** `feat(core): add director scheduler state machine`

## 阶段 3（先于阶段 2，均在 CameraCore 可测）：模型层

### Task 7: VisionModel 协议与 DeepSeekAdapter

**Files:** Create `Agent/VisionModel.swift`、`Agent/DeepSeekAdapter.swift`、`Agent/ToolSchemas.swift`、`Agent/PromptBuilder.swift`；Test `DeepSeekAdapterTests.swift`、`Fixtures/deepseek/*.json`

**Interfaces — Produces:**
- `struct ModelFrame: Sendable { jpeg: Data; measurement: SceneMeasurement; limits: CameraLimits; timestamp: TimeInterval }`
- `protocol VisionModel: Sendable { func scout(_ frame: ModelFrame) async throws -> ScoutResult; func judge(_ frame: ModelFrame, genre: GenrePlaybook, plan: ShotPlan?, memory: JudgeMemory?) async throws -> (JudgeResult, JudgeMemory) }`
- `struct JudgeMemory: Sendable { messages: [[String: AnyCodable]] /* 上一次 assistant(reasoning_content, tool_calls) + tool 结果 */ }`；`AnyCodable` 为最小 JSON 值枚举。
- `enum ModelError: Error, Equatable { authentication, rateLimited, http(Int), truncated, noToolCall, multipleToolCalls, schema(String), invalidPlan(String), transport }`
- `final class DeepSeekAdapter: VisionModel { init(key: String, session: URLSession = .shared, endpoint: URL = beta) }`；`PromptBuilder.scoutMessages(...)`、`judgeMessages(...)` 产出请求体（可单测，不发网络）。
- 解析：`finish_reason` 必须为 `tool_calls`；恰好一个调用；函数名合法；`JSONDecoder` 严格解码（未知键报错）；`set_plan` 的方案经 `validate`；时间：请求超时 scout 10 s、judge 30 s。

- [ ] **Step 1: 写失败测试**（`URLProtocol` 桩，不联网）`scoutRequestDisablesThinkingAndUsesLowDetail`、`judgeRequestEnablesThinkingAndOriginalDetail`、`toolsAreStrictWithNoAdditionalProperties`、`schemasAvoidUnsupportedKeywords`（遍历 schema 无 minLength/maxLength/minItems/maxItems）、`imageOnlyInUserMessage`、`judgeMemoryEchoesReasoningContent`、`parsesSetPlan`、`parsesKeepPlan`、`malformedRepliesAreFailures`（length、无调用、两个调用、未知字段、方案越界 各一个）、`httpStatusesMapToErrors`（401/402/403 → authentication，429 → rateLimited，500 → http(500)）。
- [ ] **Step 2–4:** 失败 → 实现 → 通过。
- [ ] **Step 5: 提交** `feat(core): add vision model protocol and DeepSeek adapter`

### Task 8: 真实 API 探针（验证「工具 + 图像 + 思考」）

**Files:** Create `CameraCore/Sources/LogitEval/main.swift`（先只含 `probe` 子命令）；Modify `Package.swift`（executable target `LogitEval`）

- [ ] **Step 1:** 实现 `swift run --package-path CameraCore LogitEval probe <image.jpg>`：从环境变量 `DEEPSEEK_API_KEY` 读取密钥，依次调用 scout 与 judge（无方案），打印工具名、解析结果、延迟、token 用量。
- [ ] **Step 2: 运行**（用 `.env` 中的密钥与一张 SPAQ 风格测试照片；约消耗 2 次 flash 调用）。Expected：两次均返回合法工具调用并通过解析；记录 judge 延迟。若 judge 的「工具 + 图像 + 思考」被拒绝：按规格 §13 改为思考 + JSON 输出（`response_format: json_object`）并在客户端用同一结构严格解码；补测试后继续。
- [ ] **Step 3: 提交** `feat(eval): add live API probe` ，并在 ledger 记录延迟与结论。

## 阶段 2：感知层

### Task 9: Perception

**Files:** Create `LogitCamera/Agent/Perception.swift`、`LogitCamera/Agent/VisionDetectors.swift`、`LogitCamera/Agent/MotionMonitor.swift`；Modify `LogitCamera/FrameGrabber.swift`（暴露 `latestBuffer() -> (CVPixelBuffer, TimeInterval)?`，`CameraFrame.difference` 改用 `MeasurementMath.sceneChange`）

**Interfaces — Produces:**
- `protocol SceneDetecting: Sendable { func faces(_ buffer: CVPixelBuffer) async throws -> [Subject]; func bodies(...) async throws -> [Subject]; func horizon(...) async throws -> Double?; func saliency(...) async throws -> NormalizedRect?; func aesthetics(...) async throws -> AestheticsHint; func track(_ buffer: CVPixelBuffer, from: NormalizedRect?) async throws -> NormalizedRect? }`；`VisionDetectors: SceneDetecting` 用 Vision Swift API（`DetectFaceLandmarksRequest` + `DetectFaceCaptureQualityRequest`、`DetectHumanBodyPoseRequest`、`DetectHorizonRequest`、`GenerateAttentionBasedSaliencyImageRequest`、`CalculateImageAestheticsScoresRequest` + `ClassifyImageRequest` 前 5、`TrackObjectRequest`）；眼部关键点经 `MeasurementMath.eyeOpenness`。
- `actor Perception { init(frames: FrameGrabber, detectors: SceneDetecting, motion: MotionMonitor); func start(baseline: [UInt8]?, onMeasurement: @Sendable (SceneMeasurement) -> Void); func stop(); func setBaseline(_ signature: [UInt8]); func setPrimarySubject(kind: SubjectKind) }`
- 调度：快 100 ms、中 250 ms、慢 1000 ms；thermal serious 时间隔×2，critical 停中慢档；处理中跳过新一帧。Y 平面经 vImage 缩至长边 320 生成 `LumaImage`。
- 方向：视频连接已设 `videoRotationAngle = 90`，缓冲即直立；Vision 坐标（左下原点）转换为左上原点。

- [ ] **Step 1:** 实现；`MotionMonitor` 用 `CMMotionManager` 60 Hz 陀螺仪，0.3 s 平均。
- [ ] **Step 2: 构建** `bash scripts/build.sh` → 成功，warning 数 = 基线 1。
- [ ] **Step 3: 真机检查**：DEBUG 设置页增加「感知诊断」开关，叠加显示主体框、地平线角、清晰度、溢出与各档实际频率；在 iPhone 上运行 30 秒，记录快档单次耗时（目标 < 8 ms）到 ledger。
- [ ] **Step 4: 提交** `feat: add on-device perception`

## 阶段 4：执行层与 loop

### Task 10: 任意裁切框拍摄

**Files:** Modify `CameraCore/Sources/CameraCore/FrameRatio.swift`（新增）或 Create `Agent/CropGeometry.swift`；Modify `LogitCamera/PhotoFraming.swift`、`PhotoCapture.swift`、`CaptureSession+...`（`capture(crop: NormalizedRect?)`）；Test `CropGeometryTests.swift`

**Interfaces — Produces:** `enum CropGeometry { static func pixelRect(_ crop: NormalizedRect, uprightWidth: Int, uprightHeight: Int, ratio: FrameRatio) -> CGRect /* 取整到比例单位，夹在图内 */ }`；`PhotoFraming.crop(_ data: Data, to rect: NormalizedRect, ratio: FrameRatio) throws -> Data`（旧的 `crop(_:to ratio:)` 改为调用它并传居中矩形）。

- [ ] **Step 1: 写失败测试** `pixelRectMatchesRatioExactly`、`pixelRectStaysInsideImage`、`pixelRectRespectsOrientation`（同一归一化框在直立 3024×4032 上的像素位置正确，左上原点）、`centeredRectEqualsLegacyCrop`（与 `FrameRatio.cropRect` 结果一致）。
- [ ] **Step 2–4:** 失败 → 实现 → 通过；`bash scripts/build.sh` 成功。
- [ ] **Step 5: 提交** `feat: capture with arbitrary crop rect`

### Task 11: 曝光控制律与执行层

**Files:** Create `CameraCore/Sources/CameraCore/Agent/ExposureController.swift`（纯逻辑）、Test `ExposureControllerTests.swift`；Create `LogitCamera/Agent/Executor.swift`；Modify `CaptureSession+Exposure.swift`

**Interfaces — Produces:**
- `struct ExposureState { bias: Double; shutterSeconds: Double; isoAuto: Bool; minBias, maxBias: Double }`；`enum ExposureCommand: Equatable { none, setBias(Double), lockShutter(seconds: Double, isoCeiling: Double?), releaseShutter }`
- `struct ExposureController { mutating func step(_ m: SceneMeasurement, intent: ExposureIntent, state: ExposureState) -> ExposureCommand; var settled: Bool }`：主体亮度 → EV 误差（log2(subjectMean/0.46) − subjectEV）；死区 0.1；步长 ≤ 0.1；高光溢出超限时只允许降低；自动快门慢于 shutterFloor → lockShutter；恢复到 floor 以上 1/3 档 → releaseShutter；settled = 误差在死区内且连续 3 帧。
- `final class Executor: @unchecked Sendable`（相机队列）：`apply(plan:)`、`ingest(_ m: SceneMeasurement)`（对焦点、曝光命令、裁切框求解与弹簧）、`currentCrop: NormalizedRect`、`reset()`；所有硬件写入经 `CaptureSession` 新方法 `setFocusPoint(_:)`、`setBias(_:)`、`lockShutter(_:isoCeiling:)`、`releaseShutter()`、`setAperture(_:)`。

- [ ] **Step 1: 写失败测试** `darkSubjectRaisesBias`、`stepIsLimited`、`deadbandHoldsSteady`、`highlightClipBlocksBrightening`、`slowAutoShutterLocksFloor`、`releasesWhenBrightEnough`、`settledAfterThreeFrames`。
- [ ] **Step 2–4:** 失败 → 实现控制律 → 通过；实现 Executor；构建成功。
- [ ] **Step 5: 提交** `feat: add exposure controller and executor`

### Task 12: AgentController 取代 CameraAgent

**Files:** Create `LogitCamera/Agent/AgentController.swift`、`LogitCamera/Agent/CaptureRecordStore.swift`；Modify `CameraModel.swift`、`DemoScenario.swift`、`AgentTrace.swift`；Delete `CameraAgent.swift`、`CameraPrompt.swift`、`DeepSeekClient.swift`、`CaptureSession+Agent.swift` 中旧 apply 路径（保留通用硬件方法）

**Interfaces — Produces（MainActor @Observable，供 UI）：**
- `AgentController { isEnabled: Bool; phase: AgentPhase; plan: ShotPlan?; playbookName: String?; rubric: RubricResult?; triggerReport: TriggerReport?; crop: NormalizedRect?; subjectBox: NormalizedRect?; observationTick: Int; planID: UUID?; faulted: Bool; status: String; reason: String; history: [AgentLogEntry]; autoCaptureEnabled: Bool; demoLocked: Bool; func enable(key:); func stop(); func pause(); func resume(); func rearm(); func disarm(); func setAutoCapture(_:); var onFire: (() -> Bool)? }`
- 内部：持有 `DirectorScheduler`、`Perception`、`Executor`、`VisionModel`；测量回调 → 主线程 → scheduler.handle → 执行命令（调用模型时 `observationTick += 1`；`.fire` 调 `onFire` 并传当前裁切框）；`CaptureRecordStore` 在照片保存后写 `CaptureRecord { photoID, plan, measurement, rubric, date }` 到 Application Support（JSON，保留最近 200 条）。
- `CameraModel`：`agent` 类型改为 `AgentController`；`takeOver` 语义不变；`takePhoto(crop:)`；AI 开启时 `state.ratio` 跟随方案；`origin(isManual:)` 规则不变。

- [ ] **Step 1:** 实现与迁移；演示场景改为驱动 AgentController 的展示字段（idle、scouting、tracking、armed、cooldown、landscape 无主体、error），并保持 `demoLocked` 阻止真实循环。
- [ ] **Step 2: 构建 + 全量 swift test** → 成功 / 全部通过。
- [ ] **Step 3: 提交** `feat: replace polling agent with plan-driven agent controller`

## 阶段 5：界面

### Task 13: 全画幅取景、裁切框、条件与就绪态

**Files:** Create `LogitCamera/Design/CropOverlay.swift`、`TriggerChips.swift`、`RubricBars.swift`；Modify `CameraView.swift`、`ViewfinderFrame.swift`、`AIStatusLine.swift`、`AIAnnotation.swift`、`AIDetailSheet.swift`、`ShutterButton.swift`、`HUDReadoutBar.swift`、`CameraUITests/DesignScreenshotTests.swift`、`InteractionTests.swift`、`CompositionTests.swift`

**Interfaces:** `CropOverlay(crop: NormalizedRect, subject: NormalizedRect?, active: Bool)`（框外 55% 压暗、青色细线 + 四角刻线、主体淡括号，弹簧值直接来自 AgentController）；`TriggerChips(report: TriggerReport)`（`camera.triggers`）；`RubricBars(result: RubricResult, weights:)`。
- 取景：AI 开启 → 预览比例固定 3:4（全画幅），`ViewfinderFrame` 角标画在裁切框上；AI 关闭 → 现有居中画幅。
- 状态线阶段文案：侦察中 / 制定方案 / 跟踪中 / 复核中 / 就绪 / 拍摄中 / 已拍摄 · 场景变化后继续 / 已暂停。
- 快门：`armed` 时外圈青色常亮呼吸，点按 = `disarm`（标识 `camera.disarm`）；删除倒计时环与 `camera.countdown`/`camera.cancelCapture`；更新依赖它们的测试。
- 标注：`planID` 变化时显示 `题材 · rationale`。
- 详情面板：方案摘要、条件实时状态、七项评分条与证据、最近 10 条决策；「再拍一张」（`camera.rearm`）在 `cooldown` 显示。

- [ ] **Step 1: 实现。** **Step 2: 构建测试包并在真机运行** `DesignScreenshotTests`、`InteractionTests`（改为：armed 场景中双指缩放 → 接管、`camera.disarm` 消失）、`ApertureTests` → 全部通过。
- [ ] **Step 3: 导出截图审阅**（裁切框、主体括号、条件标记、就绪环、详情面板），问题回到本任务修复。
- [ ] **Step 4: 提交** `feat(ui): show AI crop, triggers and armed state`

## 阶段 6：评测

### Task 14: LogitEval 评测

**Files:** Modify `CameraCore/Sources/LogitEval/main.swift`；Create `CameraCore/Sources/CameraCore/Eval/EvalMetrics.swift`、`eval/README.md`、`eval/manifest.schema.json`、`eval/fixtures/manifest-sample.json`；Test `EvalMetricsTests.swift`；Modify `.gitignore`（`eval/results/`、`eval/images/`）

**Interfaces:** `EvalMetrics.spearman(_:_:) -> Double`、`auc(positives:negatives:) -> Double`、`confusion(expected:predicted:) -> [GenreID: [GenreID: Int]]`；子命令 `sample --spaq-labels <file> --out eval/manifest-spaq.json`（每类 20 张，MOS 高低各半，固定随机种子）、`run --manifest <file> --images <dir>`。

- [ ] **Step 1: 写失败测试** `spearmanOfIdenticalRanksIsOne`、`spearmanOfReversedIsMinusOne`、`aucOfSeparatedSetsIsOne`、`aucOfIdenticalSetsIsHalf`、`confusionCountsPairs`、`manifestFixtureDecodes`。
- [ ] **Step 2–4:** 失败 → 实现 → 通过；`swift run --package-path CameraCore LogitEval run --manifest eval/fixtures/manifest-sample.json --images CameraCore/Tests/CameraCoreTests/Fixtures/images` 在 2 张自带测试图上跑通（消耗约 4 次调用）。
- [ ] **Step 5:** `eval/README.md` 写明数据集下载位置、许可未声明故不分发、如何生成清单与运行；提交 `feat(eval): add offline aesthetics evaluation`。

### Task 15: 文档与收尾

- [ ] 更新 `README.md`（Agent 如何工作一节、架构图）与 `docs/agent-loop.md`（改写为新架构，保留调研依据并加入 DeepSeek 文档事实）。
- [ ] 全量 `swift test`、`bash scripts/build.sh`、真机 UI 测试通过；提交 `docs: describe plan-driven agent core`。
