# AI 掌控相机 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal：** AI 通过本机实时程序真正掌控镜头、光圈、快门、ISO、对焦和裁切；快门永远可用；AI 开启时每次拍摄都连拍并在本机选片；同时修掉上一轮最终审查的问题。

**Architecture：** 云端只产出意图（ShotPlan v2）。CameraCore 中的纯函数负责把意图变成参数和时机：
- LensPlanner：选镜头。
- ExposureProgram：算光圈、快门、ISO。
- MomentScorer：给当前时刻打分、决定何时自动拍。
- BurstSelector：从连拍中选片。
- DirectorScheduler v2：决定何时问云端、何时拍。

App 层负责硬件和 Vision：
- CaptureSession 使用虚拟三摄，用全手动曝光写入参数，并负责连拍。
- Perception、Executor、AgentController 串起本机闭环。
- BurstAnalyzer、BurstStore 负责选片分析和备选存储。

**Tech Stack：** Swift 6、SwiftUI、AVFoundation（iOS 27）、Vision、Swift Testing、XCUITest、DeepSeek（`deepseek-flash`）。

**Spec：** `docs/superpowers/specs/2026-11-07-camera-control-design.md`

## Global Constraints

- iOS 27.0 / macOS 26.0；Swift 6 严格并发；不引入第三方依赖。
- 新文件放进已有目录（fileSystemSynchronizedGroups 会自动收录）。
- 界面文字和注释用简体中文。AI 相关颜色只用 Theme 的 accent（#3DF5C8）。
- 不提交 `.env` 和 `Signing.xcconfig`。不把用户照片发给评测以外的外部服务。
- 测试命令：
  - 单元测试：`swift test --package-path CameraCore`
  - 编译：`xcodebuild build-for-testing … -destination "id=00008160-001C25282680000A" -derivedDataPath build/test`，警告数不超过基线 1。
  - 真机测试：`xcodebuild test-without-building … -only-testing:<Target/Class>`
- 规格中的数值（阈值、间隔、权重）原样使用，不另行调整。
- **用户要求（2026-11-07）：开发过程中不运行测试。** 每个任务只编译：`swift build --package-path CameraCore --build-tests`，App 用 `build-for-testing`。测试代码照常先写；单元测试、真机测试和真实 API 测试全部放到 Task 15 统一运行。下文各任务中「运行失败 / 运行通过」的步骤，一律改为「测试代码编译通过」。

## Review Focus

1. 弱光：快门在手持安全值，ISO 到顶，仍欠曝。这时要能拍、要报告 starved、非主摄要回退到主摄，不能卡死。
2. 曝光和变焦正在写入时，用户按快门必须出片，不能被拒。
3. 连拍进行中再次触发（用户连按，或自动拍和手动同时发生），不能重复连拍，也不能丢失照片。
4. 网络或密钥失败、导演返回非法方案时，不能每 4 秒循环请求，AI 要能离线自动拍。
5. AI 停止或暂停时，在途的回复和连拍分析结果不能改写新的状态。

---

### Task 1：硬件可行性验证（一次性）—— 已完成

结论（iPhone 18 Pro Max，iOS 27）：
- 虚拟三摄的三颗镜头都报告不支持全手动曝光（`supportsExposureModeCustom` 返回 false），曝光模式始终是自动。
- **因此改用切换物理镜头的方案**：超广角 13 mm（f/2.2）、主摄 24 mm（f/1.48–4.0 可变，档位 1.48/1.8/2.8/4.0）、主摄 2× 裁切 48 mm、长焦 96 mm（4×，f/2.8）。
  - 换镜头时重新配置会话的输入。
  - 等效焦距按虚拟设备的 switch-over 倍率 [2, 8] × 0.5 换算。
- 连拍：间隔 100 ms 时，6 张要 1.5 秒；背靠背连发时，6 张约 0.4 秒。采用背靠背连发。
- 支持 responsive capture 和 ZSL，不支持 fast capture prioritization。照片尺寸 12 MP 或 24 MP。

以下是原步骤，保留作记录：

**Files：** Create（一次性，任务结束时删除）`LogitCamera/LensProbe.swift`、`CameraUITests/LensProbeTests.swift`；Modify `LogitCamera/CameraModel.swift`（`-LogitLensProbe` 钩子）、`LogitCamera/Agent/AgentController.swift`（`showDiagnostics`）。

- [ ] 探针在 `builtInTripleCamera` 上依次验证：
  - 锁定每个物理镜头，并记录 switch-over 倍率和 `displayVideoZoomFactorMultiplier`。
  - 在每个镜头上设置全手动 1/250 秒、ISO 400，并读回实际值。
  - 主摄的可变光圈能否设置。
  - 镜头锁定状态下改变变焦后，是否仍保持手动模式。
  - 主摄全手动、不超过 24 MP、`.speed` 连拍 6 张的时间分布，以及 EXIF 是否符合手动设定。
- [ ] 运行：`test-without-building -only-testing:CameraUITests/LensProbeTests`，输出夹在 `LENSPROBE-BEGIN` 和 `LENSPROBE-END` 之间。
- [ ] 把结论写进 ledger：`Task 1: Ruling: <虚拟设备方案 / 物理设备切换方案> — <依据>`。
- [ ] 删除探针代码，不提交。

### Task 2：ShotPlan v2 与知识库迁移

**Files：**
- Modify：`CameraCore/Sources/CameraCore/Agent/ShotPlan.swift`、`CameraLimits.swift`、`Resources/Knowledge/genres/*.json`（11 个）。
- Test：`CameraCore/Tests/CameraCoreTests/ShotPlanTests.swift`、`KnowledgeTests.swift`。

**Interfaces：**
- Produces：
  - `LensIntent { focalLength: Double }`（0 表示题材默认）。
  - `MotionIntent { freeze, normal, blur }`、`DepthIntent { shallow, normal, deep }`。
  - `ExposureIntent { meter, subjectEV, highlightClipMax, motion, depth, shutterFloor: Double, isoCeiling: Double }`，后两者 0 表示自动。
  - `ShotPlan { id, genre, genreConfidence, subject, composition, lens, exposure, moment: [Trigger], holdMs, rationale, intentWeights?, look? }`。
  - `Trigger` 去掉 `exposureSettled` 和 `subjectPresent` 两个 case。
  - `CameraLimits.lensStops: [Double]`（等效焦距 mm）。
  - `GenrePlaybook.defaultFocalLength: Double`，取自 `defaultPlan.lens.focalLength`。
  - `ShotPlan.validate(against:) throws(PlanValidationError)`，错误为 `.outOfRange("moment[1].threshold faceToward 0…45")` 这种带字段名的形式。

- [ ] **测试**：
  - `decodesV2Plan`：v2 JSON 能解码，并且字段值都正确。
  - `momentDropsRemovedKinds`：`{"kind":"exposureSettled"}` 和 `{"kind":"subjectPresent"}` 被忽略，未知种类也被忽略。
  - `validateUsesPerKindRanges`：faceToward 50 → 报错，信息包含 "faceToward"；deviceStill 1.5 → 通过；highlightsSafe 0.1 → 报错。
  - `validateFocalLength`：lensStops 为 [13, 24, 48, 120] 时，0 → 通过，100 → 通过，200 → 报错，8 → 报错。
  - `validateOverrides`：shutterFloor 2 → 报错，isoCeiling 50 → 报错，0 → 通过。
  - `everyDefaultPlanIsV2AndValid`：每个题材的默认方案都能通过 lensStops [13, 24, 48, 120] 的校验，焦距符合规格 §4 的表。
- [ ] 运行 `swift test`：编译失败（新类型不存在）。
- [ ] 实现 v2 并迁移 11 个 JSON。
  - motion 和 depth 按题材填写：
    - 人像：freeze + shallow。
    - 街拍、动物：freeze + normal。
    - 风光、建筑、文档：normal + deep。
    - 夜景：normal + normal，`isoCeiling` 填 6400。
    - 其余题材：normal + normal。
  - 删除默认方案里的 `exposureSettled` 和 `subjectPresent`。
  - 删除 `TriggerEvaluator.swift` 里依赖这两个 case 的分支（这个文件在 Task 5 整体替换）。在这一步先让它编译通过即可。
- [ ] `swift test` 全部通过后提交：`feat(core): shot plan v2 intent with lens, motion and depth`。

### Task 3：ExposureProgram

**Files：**
- Create：`CameraCore/Sources/CameraCore/Agent/ExposureProgram.swift`、`Tests/CameraCoreTests/ExposureProgramTests.swift`。
- Delete：`ExposureController.swift` 及其测试。

**Interfaces：**
- Produces：
  - `ExposureReading { aperture, shutter, iso: Double }`。
  - `ExposureLimits { minISO, maxISO, minShutter, maxShutter: Double; apertureStops: [Double]; variableAperture: Bool }`。
  - `ExposureContext { focalLength, deviceAngularSpeed, subjectSpeed: Double; isNight: Bool }`。
  - `ExposureTarget { aperture: Double?; shutter: Double; iso: Double }`，aperture 为 nil 表示不改。
  - `ExposureDecision { target: ExposureTarget?; settled: Bool; starved: Bool; errorEV: Double }`。
  - `struct ExposureProgram { init(); mutating reset(); mutating step(luminance: LuminanceStats, intent: ExposureIntent, reading: ExposureReading, limits: ExposureLimits, context: ExposureContext, writePending: Bool) -> ExposureDecision }`。
  - 静态方法：`linear(_ encoded: Double) -> Double`、`shutterRange(intent:context:limits:) -> (preferred: Double, slowest: Double)`、`aperture(for: DepthIntent, limits:) -> Double?`。
  - 常量：`gain 0.6`、`maxStep 1.0`、`deadband 1/6`、`settleBand 1/3`、`defaultISOCeiling 1600`、`nightISOCeiling 6400`。

- [ ] **测试**（只用规格 §5.2 中的数值）：
  - `linearizesSRGB`：`linear(0.4613) ≈ 0.18 ± 0.002`，`linear(0) == 0`，`linear(1) == 1`。
  - `holdsAtTargetAndSettles`：线性 0.18（编码 0.4613），subjectEV 0。两步之后 target 为 nil，并且 settled。
  - `brightensTowardTarget`：编码 0.25，当前 1/100 秒、ISO 100、f/1.8，normal，焦距 24，角速度 0.2。期望：
    - shutter = 1/48。
    - `t×S/N²` 是原来的 2^min(0.6Δ, 1) 倍（误差 1%）。
  - `starvesInDarkness`：编码 0.01，当前已是 1/48 秒、ISO 1600，ISO 上限 0（默认 1600）。期望：shutter = 1/48，iso = 1600，starved。
  - `freezeShutterFromSubjectSpeed`：主体速度 0.5 → 1/333 秒（±2%）；速度 0 → 1/250 秒。
  - `stillDeviceAllowsLongerShutter`：角速度 0.01、焦距 24 → slowest = 4/48 秒。
  - `blurMotionUses1_15WhenStill`。
  - `clippedHighlightsDarken`：clipHigh 0.05、上限 0.01 → errorEV ≤ −1/3，并且进光量减少。
  - `depthChoosesAperture`：stops 为 [1.6, 2.8, 4, 5.6] 时，deep → 4，shallow → 1.6；不可变光圈时返回 nil。
  - `writePendingHolds`。
  - `shutterFloorOverridesSlowest`。
  - `nightUsesHigherCeiling`。
  - `brightSceneUsesMinISOAndFasterShutter`：编码 0.98 → iso == minISO，并且 shutter 变快。
- [ ] 运行：测试失败。
- [ ] 实现：
  - `H = t·S/N² · 2^step`。
  - 光圈由 depth 决定。
  - 先按 preferred 快门算 ISO；超过上限时把快门放慢，最多到 slowest；仍不够就按上限 ISO 并报告 starved。
  - 低于最低 ISO 时，加快快门，最快到 minShutter。
  - 每步写入量不超过死区时返回 target 为 nil。
- [ ] 运行：通过。全量 `swift test` 通过后提交：`feat(core): rule-based exposure program with linear metering`。

### Task 4：LensPlanner

**Files：** Create `CameraCore/Sources/CameraCore/Agent/LensPlanner.swift`、`Tests/CameraCoreTests/LensPlannerTests.swift`。

**Interfaces：**
- Produces：
  - `LensStop { focalLength: Double; zoomFactor: Double; isMain: Bool }`，zoomFactor 为显示倍率：13 → 0.5，24 → 1，48 → 2，120 → 5。
  - `struct LensPlanner { init(stops: [LensStop]); current: LensStop?; mutating plan(for: LensIntent, genreDefault: Double, planID: UUID) -> LensStop?; mutating reportStarved(_: Bool, now: TimeInterval) -> LensStop?; mutating reset(); static nearest(_ focal: Double, in: [LensStop]) -> LensStop? }`。
  - 返回 nil 表示不需要切换。
  - 常量：`starvationHold 1.0`。

- [ ] **测试**：
  - `snapsByLogDistance`：35 → 24，40 → 48，100 → 120。
  - `zeroUsesGenreDefault`。
  - `samePlanDoesNotSwitchAgain`：同一个 planID 第二次调用返回 nil。
  - `starvationFallsBackToMainOnce`：在 120 上 starved 0.5 秒 → nil；1.0 秒 → 24。之后同一方案再调用 plan，不会切回 120。
  - `starvationOnMainDoesNothing`。
  - `newPlanClearsFallback`。
- [ ] 运行失败 → 实现 → 运行通过，提交：`feat(core): lens planner with low-light fallback`。

### Task 5：MomentScorer（替换 TriggerEvaluator）

**Files：**
- Create：`CameraCore/Sources/CameraCore/Agent/MomentScorer.swift`、`Tests/CameraCoreTests/MomentScorerTests.swift`。
- Delete：`TriggerEvaluator.swift`、`TriggerEvaluatorTests.swift`（其中有效的余量用例迁移过来）。

**Interfaces：**
- Produces：
  - `MomentStatus { trigger: Trigger; available: Bool; satisfied: Bool; score: Double }`。
  - `MomentReport { statuses: [MomentStatus]; score: Double; fireReady: Bool; reason: FireReason? }`，其中 `FireReason { perfect, patience }`，并提供 public init。
  - `struct MomentScorer { init(plan: ShotPlan, startedAt: TimeInterval); mutating restart(at:); mutating update(_ m: SceneMeasurement, now: TimeInterval, placementError: Double, exposureSettled: Bool) -> MomentReport }`。
  - 常量：`patience 4`、`patienceFloor 0.6`、`patienceRatio 0.95`、`maxMeasurementAge 0.3`、`unsettledScore 0.5`。

- [ ] **测试**：
  - `missingHorizonIsNeutral`：方案只有 horizonLevel 5，地平线为 nil，曝光已收敛，持续 200 ms → fireReady，reason 为 perfect。
  - `geometricMeanOfScores`：两个信号的分数为 1 和 0.64 → score 0.8。
  - `missingSubjectZeroesScore`：subject 为 face 但没有主体 → score 0，不触发。
  - `staleMeasurementZeroes`。
  - `perfectNeedsHold`：满足 100 ms → 不触发；200 ms → 触发。
  - `patienceFiresNearBest`：分数长期在 0.7 左右、峰值 0.75，4 秒后一帧 0.72 → 触发，reason 为 patience；一帧 0.65（低于 0.95×0.75）→ 不触发。
  - `patienceNeedsFloor`：分数一直是 0.5 → 不触发。
  - `unsettledExposureHalves`。
  - `restartResetsPatience`。
- [ ] 运行失败 → 实现：余量的计算从 TriggerEvaluator 迁移过来；数据缺失的信号记为 `available = false`。
- [ ] 删除 TriggerEvaluator。把 `TriggerReport` 的引用改为 `MomentReport`：CameraCore 这一侧在本任务完成；App 侧在 Task 11 和 13 完成，在那之前只保证 CameraCore 能编译。
- [ ] 运行通过，提交：`feat(core): soft moment scoring with patience`。

### Task 6：BurstSelector

**Files：** Create `CameraCore/Sources/CameraCore/Agent/BurstSelector.swift`、`Tests/CameraCoreTests/BurstSelectorTests.swift`。

**Interfaces：**
- Produces：
  - `FrameQuality: Codable { sharpness, eyesOpen, faceQuality, aesthetics: Double? }`。
  - `enum BurstSelector { static func scores(_ frames: [FrameQuality], genre: GenreID) -> [Double]; static func best(_ frames: [FrameQuality], genre: GenreID) -> Int }`。
  - 权重：
    - portrait 和 group：faceQuality 0.35、eyesOpen 0.3、sharpness 0.25、aesthetics 0.1。
    - 其他题材：sharpness 0.6、aesthetics 0.4。

- [ ] **测试**：
  - `portraitPrefersOpenEyes`：A 更清晰但闭眼，B 睁眼 → 选 B。
  - `landscapePrefersSharp`。
  - `missingMetricsIgnored`：缺失的指标不参与计分。
  - `allMissingPicksFirst`。
  - `constantMetricIsNeutral`：所有帧同一个值时，归一化为 0，不影响结果。
  - `emptyReturnsZero`。
- [ ] 失败 → 实现（组内 min-max 归一化；只用可用指标的权重之和做归一化）→ 通过，提交：`feat(core): burst frame selector`。

### Task 7：DirectorScheduler v2

**Files：** Rewrite `CameraCore/Sources/CameraCore/Agent/DirectorScheduler.swift` 和 `Tests/CameraCoreTests/DirectorSchedulerTests.swift`。

**Interfaces：**
- Consumes：`MomentReport`（Task 5）、`ShotPlan`（Task 2）。
- Produces：
  - `AgentPhase { off, scouting, planning, composing, capturing, cooldown, paused }`。
  - `DirectorReply { case plan(ShotPlan, RubricResult?), invalid(String) }`。
  - `SchedulerEvent { start, stop, pause, resume, measurement(SceneMeasurement, MomentReport), scoutReply(id: Int, ScoutResult), directorReply(id: Int, DirectorReply), requestFailed(id: Int, retryable: Bool, stale: Bool), captured, fireRejected, rearm }`。
  - `SchedulerCommand { none, callScout, callDirector(GenreID, feedback: String?), fire }`。
  - `SchedulerOutput { command; requestID: Int?; resetBaseline; resetMemory }`。
  - `struct DirectorScheduler { init(defaultPlan: @Sendable (GenreID) -> ShotPlan); static live() throws; phase; plan; isDefaultPlan; isOffline: Bool; mutating handle(_:now:) -> SchedulerOutput }`。
  - 常量：`sceneChangeThreshold 0.18`、`sceneChangeHold 0.5`、`subjectLostHold 1`、`heartbeat 15`、`scoutSpacing 2`、`directorSpacing 4`、`offlineFallback 3`、`backoff [5, 10, 20, 30]`、`maxInvalidRetries 1`。
  - `RubricResult.modelVerdict` 改为可选；删除 `verdict(weights:)`，同时删掉它的测试。

- [ ] **测试**（每条对应规格 §7.2 的一行）：
  - `startScouts`：start 后得到 callScout 和 requestID 1，阶段为 scouting。
  - `scoutNeedsPlanAppliesGenreDefault`：阶段变为 planning，方案换成 portrait 默认，并发出 callDirector(portrait)。
  - `scoutKeepsPlanResetsBaselineNoStorm`：保持方案时 resetBaseline。之后场景变化度 0.1 持续 10 秒，不再发出 callScout，直到 15 秒心跳。
  - `offlineFallbackAfter3s`：scout 失败，到 3 秒时阶段变为 composing，isOffline 为 true。
  - `directorInvalidRetriesOnceThenHolds`：第一次 invalid → callDirector 并带上 feedback；第二次 invalid → composing，之后场景不变时不再请求导演。
  - `fireOnlyWhenReadyInPlanningOrComposing`：scouting 阶段 fireReady → 不触发；composing 阶段 → fire，阶段变为 capturing。
  - `capturedGoesToCooldownAndRescoutsOnSceneChange`。
  - `requestIDsMonotonicAcrossRestart`：stop 再 start 后 ID 继续递增。旧 ID 的回复被忽略，状态不变。
  - `staleFailureDoesNotEscalateBackoff`。
  - `pauseResume`、`fireRejectedReturnsToComposing`、`rearmFromCooldown`。
  - `subjectLostTriggersScout`。
- [ ] 失败 → 实现 → 通过（全量），提交：`feat(core): director scheduler v2 without approval gate`。

### Task 8：导演提示词、工具、适配器与评测

**Files：**
- Modify：`ToolSchemas.swift`、`PromptBuilder.swift`、`VisionModel.swift`、`DeepSeekAdapter.swift`、`Resources/Knowledge/prompts/system.md`、`scout.md`。
- Rename：`judge.md` 改名为 `director.md`。
- Modify：`LogitEval/main.swift`、`Evaluate.swift`。
- Test：`DeepSeekAdapterTests.swift`、`KnowledgeTests.swift`、`AgentDecisionTests.swift`。

**Interfaces：**
- Produces：
  - `protocol VisionModel { scout(_:plan:) async throws -> ScoutResult; direct(_ frame: ModelFrame, playbook: GenrePlaybook, plan: ShotPlan?, memory: DirectorMemory?, feedback: String) async throws -> DirectorOutcome }`。
  - `DirectorOutcome { plan: ShotPlan; critique: RubricResult; memory: DirectorMemory; usage: TokenUsage? }`。
  - `ToolSchemas.directorTools(limits: CameraLimits)`：只有一个工具 `set_plan`，参数为 `{plan, critique}`。
  - `ModelError.invalidPlan(String)`：里面是 `validate` 的错误文字。
  - `JudgeMemory` 改名为 `DirectorMemory`。

- [ ] **测试**：
  - `directorToolHasOnlySetPlan`。
  - `momentThresholdDescriptionsListPerKindRanges`：description 里包含 "faceToward 0–45" 和 "highlightsSafe 0–0.05"。
  - `focalLengthDescribesDeviceStops`：description 里包含 "13/24/48/120"。
  - `critiqueHasNoVerdict`。
  - `parsesSetPlanIntoOutcome`。
  - `invalidPlanThrowsWithFieldText`。
  - `directorPromptStatesNoGate`：system 提示里包含「你不决定是否按快门」。
  - `measurementTextIncludesLensStops`。
- [ ] 失败 → 实现：
  - 提示词按规格 §7.1 改写：导演只给意图；本机会掌控镜头、光圈、快门、ISO 和时机；时机信号是加分项，不是前提条件。
  - 评测改用 `direct`，记录 critique 的加权分（不再有 verdict）。
- [ ] 运行通过。
- [ ] 真实 API 探测：`swift run --package-path CameraCore LogitEval probe eval/fixtures/<现有样例图>`。成功条件：返回 set_plan 并通过校验，打印出延迟。结果写进 ledger。
- [ ] 提交：`feat(core): director emits intent; drop approval tooling`。

### Task 9：CaptureSession —— 镜头、全手动曝光、连拍

**Files：**
- Modify：`LogitCamera/CaptureSession.swift`、`CaptureSession+Exposure.swift`、`CaptureSession+Executor.swift`、`CaptureSession+Agent.swift`、`PhotoCapture.swift`、`CameraState.swift`。

**Interfaces：**
- Consumes：`LensStop`（Task 4）、`ExposureTarget`（Task 3）。
- Produces：
  - `CameraState` 新增字段：
    - `lensStops: [LensStop]`、`activeLens: LensStop?`。
    - `apertureVariable: Bool`（当前镜头）。
    - `agentWritePending: Bool`（不影响 canCapture）。
    - `isBursting: Bool`（canCapture 为 false）。
  - `CaptureSession` 新增方法：
    - `setLens(_ stop: LensStop)`：锁定物理镜头，然后 ramp 到它的倍率。
    - `setManualExposure(_ target: ExposureTarget)`：不设置 isApplying，完成时清除 agentWritePending。
    - `releaseManualExposure()`。
    - `capture(crop:ratio:)`。
    - `captureBurst(count: Int, crop: NormalizedRect?, ratio: FrameRatio)`：完成后发出 `CameraEvent.burst([CapturedPhoto])`；中途失败时发出已经拿到的照片，一张都没有则发出 `.captureFailed`。
  - `currentLimits()` 返回 `lensStops`。
  - 变焦上限改为长焦档 × 2。

- [ ] 按 Task 1 的结论配置设备：
  - 默认使用物理主摄。
  - `setLens` 在会话配置中替换输入，切换到 `builtInUltraWideCamera`、`builtInWideAngleCamera` 或 `builtInTelephotoCamera`。2× 是在主摄上设置变焦。
  - 换镜头后重新设置连接的旋转角、照片尺寸，以及 apertureRange 和 supportsAperturePriority。
  - 镜头档的焦距来自 `AVCaptureDevice.default(.builtInTripleCamera)` 的 switch-over 倍率乘以 displayVideoZoomFactorMultiplier；拿不到三摄时，只提供主摄 24 和 48 两档。
  - 连拍 6 张背靠背连发，尺寸不超过 24 MP，开启 responsive capture。
  - 全手动用 `setExposureModeCustom(lensAperture:duration:iso:)`（只有主摄支持可变光圈），其他镜头用 `setExposureModeCustom(duration:iso:)`。
- [ ] 显示倍率统一用 `displayVideoZoomFactorMultiplier` 换算；`setZoom` 接收显示倍率。
- [ ] 单元测试：`CameraCore/Tests/CameraCoreTests/LensStopsTests.swift`。
  - `LensStop.stops(switchOver: [2, 8], displayMultiplier: 0.5, hasUltraWide: true, hasTele: true)` 得到 13/24/48/96，zoomFactor 为 0.5/1/2/4。
  - 拿不到三摄时只得到 24/48。
  - 纯函数放在 LensPlanner.swift。
- [ ] 构建通过。现有 `ApertureTests`、`CompositionTests/testPreviewRatiosMatchTheirSelection` 在真机上通过。
- [ ] 提交：`feat(camera): virtual triple camera, manual exposure writes and burst capture`。

### Task 10：Perception 修复（C1）

**Files：** Modify `LogitCamera/Agent/Perception.swift`；纯逻辑放在 `CameraCore/Sources/CameraCore/Agent/TierCache.swift`；Test `Tests/CameraCoreTests/TierCacheTests.swift`。

**Interfaces：**
- Produces：`struct TierCache<Value> { mutating store(_ value: Value, at: TimeInterval, epoch: Int); value(now: TimeInterval, epoch: Int, maxAge: Double) -> Value?; mutating clear() }`，maxAge 为 0.5。

- [ ] **测试**：
  - `staleValueDropped`：0.6 秒前的值返回 nil。
  - `oldEpochIgnored`：epoch 不同的写入被丢弃。
  - `clearEmpties`。
- [ ] 失败 → 实现 TierCache。
- [ ] Perception 改用 TierCache 管理 faces、bodies、salient、horizon、aesthetics：
  - stop 或 setPreferredSubject 时 `epoch += 1`。
  - 设备过热到 critical 时 clear。
  - 跟踪失败就把 tracked 置为 nil。
  - 同类的新检测为空时丢弃 tracker。
  - updateTracking 的 await 之后，epoch 不同就不写回。
- [ ] 通过 + 构建 → 提交：`fix(perception): expire stale tier results and tracker state`。

### Task 11：Executor 与 AgentController v2

**Files：**
- Rewrite：`LogitCamera/Agent/Executor.swift`、`AgentController.swift`。
- Modify：`CaptureRecordStore.swift`（改为 actor，加 `chosenIndex`）、`CameraModel.swift`（onFire 连拍、手动拍摄通知调度器）。
- Create：`LogitCamera/Agent/OfflineDirector.swift`（DEBUG）。
- Delete：`LogitCamera/Agent/AgentCompat.swift`。

**Interfaces：**
- Consumes：Task 2–10 的全部接口。
- Produces：
  - `AgentController` 对外暴露：
    - 状态：`phase`、`plan`、`isDefaultPlan`、`isOffline`、`genreName`、`critique: RubricResult?`、`moment: MomentReport?`、`crop`、`subjectBox`、`lensName`。
    - 方法：`captured(photoID:automatic:)`（自动和手动拍摄都通知调度器）、`fireRejected()`、`rearm()`。
  - `Executor.ingest(_:state:now:) -> MomentReport?`：内部运行 LensPlanner、ExposureProgram、CompositionSolver 和 MomentScorer，再通过 CaptureSession 写入硬件。
  - 连拍期间（`state.isBursting`）不写硬件。

- [ ] 规则：
  - 请求带 requestID；回复先核对 ID，再修改任何状态。
  - 调度器只创建一次。
  - 新鲜度判断里的签名在后台计算。
  - stale 丢弃时以 `requestFailed(stale: true)` 上报。
  - 关闭自动拍摄时，屏蔽 `fireReady`。
- [ ] `OfflineDirector`：启动参数 `-LogitOfflineDirector` 时生效（DEBUG）。scout 返回 general，direct 抛出 `ModelError.transport`。
- [ ] 构建通过。现有 InteractionTests 在真机上通过（可以按语义调整断言，调整要写进 ledger）。
- [ ] 提交：`feat(agent): executor drives lens, manual exposure and moments`。

### Task 12：连拍分析、备选存储与照片详情

**Files：**
- Create：`LogitCamera/Agent/BurstAnalyzer.swift`、`LogitCamera/BurstStore.swift`。
- Modify：`CameraModel.swift`（`.burst` 事件 → 分析 → 选出最好一张走现有保存流程；备选写入 BurstStore）、`PhotoDetailView.swift`（备选缩略图条、「换成这张」）。
- Test：`CameraCore/Tests/CameraCoreTests/BurstManifestTests.swift`，测清理规则的纯函数 `BurstManifest.expired(_:now:maxAge:maxCount:)`，放在 CameraCore 的 `BurstManifest.swift`。

**Interfaces：**
- Produces：
  - `BurstManifest: Codable { photoID: UUID; date: Date; genre: GenreID; chosen: Int; files: [String]; scores: [Double] }`。
  - `static expired(_ manifests: [BurstManifest], now: Date, maxAge: 7 天, maxCount: 30) -> [UUID]`。
  - `BurstStore.save`、`load(photoID:)`、`purge()`。
  - `CameraModel.alternates: [BurstAlternate]`、`saveAlternate(_:)`。

- [ ] **测试**：
  - `expiresOlderThan7Days`。
  - `keepsNewest30`。
  - `emptyIsEmpty`。
- [ ] 失败 → 实现 → 通过。
- [ ] 连拍分析在后台进行：长边 1024；清晰度用 `MeasurementMath.sharpness`；睁眼和人脸质量用 Vision；美学用 `CalculateImageAestheticsScoresRequest`。
- [ ] 分析结果按 photoID 核对后才能写入。连拍期间快门显示处理中，`canTakePhoto` 为 false。
- [ ] 构建通过后提交：`feat(camera): burst analysis, alternates and swap in photo detail`。

### Task 13：界面语义、演示场景与真机测试

**Files：**
- Modify：`LogitCamera/Design/AIStatusLine.swift`、`AIDetailSheet.swift`、`TriggerChips.swift`、`AgentText.swift`、`ShutterButton.swift`、`RubricBars.swift`、`HUDReadoutBar.swift`、`ZoomSelector.swift`、`CameraView.swift`、`DemoScenario.swift`。
- Modify：`CameraUITests/DesignScreenshotTests.swift`、`InteractionTests.swift`、`CompositionTests.swift`。

- [ ] 状态文字：

  | 阶段 | 文字 |
  |---|---|
  | scouting | 观察中 |
  | planning | 构思中 |
  | composing | 取景中 |
  | capturing | 拍摄中 |
  | cooldown | 已拍摄 · 场景变化后继续 |
  | paused | 已暂停 |
  | 离线 | 离线 · 本机取景 |

- [ ] 快门：AI 开启时点按永远拍摄。呼吸环的亮度跟随 `moment.score`。删除 disarm。
- [ ] 详情面板：
  - 显示意图：焦段、动作、景深、亮度。
  - 显示量表点评（不再有放行结论）、时机信号和历史。
  - 冷却中提供「再拍一张」。
- [ ] 读数：AI 开启时，光圈、快门、ISO、焦段都标为 AI 来源（cyan）。
- [ ] 变焦档：显示设备的镜头档（0.5、1、2、长焦）。
- [ ] 演示场景：idle、scouting、composing、capturing、cooldown、landscape、manual、error、offline，替换掉 armed 和 tracking。
- [ ] 新增真机测试：
  - `InteractionTests.testShutterAlwaysCapturesWithAIOn`：`-LogitOfflineDirector` 开 AI，等 2 秒后点快门。8 秒内出现照片缩略图，并且没有出现文字「相机正在调整」。
  - `InteractionTests.testAutoCaptureInStaticScene`：`-LogitOfflineDirector` 开 AI，手机静置。20 秒内自动拍下一张；打开详情能看到备选（`photo.alternates` 至少有 1 张）。
- [ ] 运行全部真机测试：DesignScreenshotTests、InteractionTests、ApertureTests、`CompositionTests/testPreviewRatiosMatchTheirSelection` → 通过，截图检查。
- [ ] 提交：`feat(ui): reflect camera control, moments and offline mode`。

### Task 14：文档

**Files：** Modify `README.md`、`docs/agent-loop.md`。

- [ ] 文档按规格更新：架构图、意图字段、曝光程序、时机和连拍。
- [ ] 构建通过后提交：`docs: describe intent-driven camera control`。

### Task 15：统一测试

- [ ] `swift test --package-path CameraCore`：全部通过。失败的按 TDD 修复，修复要写进 ledger。
- [ ] Task 8 的真实 API 探测。
- [ ] 真机：DesignScreenshotTests、InteractionTests（包括两个新增用例）、ApertureTests、`CompositionTests/testPreviewRatiosMatchTheirSelection`，并检查截图。
- [ ] 真实 API 真机实测（少量额度）：开 AI 运行 30 秒。记录侦察和导演的延迟、方案是否通过校验、自动拍摄次数，写进 ledger。
- [ ] 提交修复：`fix: issues found in full test run`（有修复时才提交）。
