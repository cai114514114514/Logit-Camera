# 子项目 A：AI 掌控相机 —— 设计规格

日期：2026-11-07　分支：`camera-control`（从 `main` 1ad20e8 开始）

## 1. 背景与目标

真机试用的反馈（用户原话归纳）：
- AI 只在「辅助」，没有真正去调曝光、ISO、快门和焦段。
- 对着房间拍，AI 一直拍不下来。

参考业界做法（Pixel Camera Coach、Top Shot、Vidhance、Arsenal、CameraBench）：
- 云端大模型只负责看懂场景、给出方向。
- 毫秒级的参数控制都在本机完成。
- 「时机」靠连拍加事后挑选，而不是等一个许可。

A 的目标：
1. **AI 真正掌控相机**：镜头（0.5× / 1× / 2× / 长焦）、光圈（主摄可变光圈）、快门、ISO、对焦点和裁切框，全部由本机按 AI 的意图实时设定。
2. **永远拍得下来**：
   - 用户按快门永远立即拍摄，用 AI 当前的全部参数，不会被「相机正在调整」拒绝。
   - AI 自己判断时机自动拍，判断完全在本机完成，云端不再是放行条件。
3. **连拍选片**：
   - AI 开启时，每次拍摄（手动或自动）都连拍 6 张，在本机挑出最好的一张存入系统相册。
   - 其余几张留在 App 内 7 天，在照片详情里可以换成其中任意一张。
4. **修掉上一轮最终审查的问题**，见 §9。

不在 A 的范围：
- AI 界面的视觉重做（子项目 B）。A 只改语义已经变化的界面文字和状态。
- 滤镜（子项目 C）。
- 偏好学习本身。A 只记录用户「换成这张」的选择。

## 2. 用户可见的行为

| 场景 | 行为 |
|---|---|
| 开启 AI | 约 1.5 秒内识别题材，立即按该题材的默认意图接管镜头和曝光，自动拍摄随即可用；约 10 秒后导演方案到达，平滑替换 |
| 没有网络或密钥出错 | 3 秒后用通用默认意图继续工作，可以拍也可以自动拍；状态行说明「离线 · 本机取景」 |
| 对着静止的房间 | 曝光收敛、手机稳定后 1 秒内自动拍一组；之后进入冷却，场景变化后才会再拍 |
| 人像 | 自动切到 2×，脸部测光、浅景深、快门不低于 1/250 s，等睁眼、正脸、稳定后拍；最多 4 秒耐心期后，拍下耐心期内最好的时刻 |
| 用户按快门 | 立即连拍，AI 状态进入冷却，不会紧接着再自动拍一张重复的 |
| 用户手动改参数（变焦、光圈、EV、画幅） | 和现在一样：AI 停止，提示可以一键恢复 |
| AI 关闭 | 单张拍摄，系统自动曝光，和现在一样 |

## 3. 架构

保留「慢导演 + 快助理」的分层，但导演只给意图，不再有放行权。

```
云端（DeepSeek flash）            本机（10 Hz）
 侦察 scout ──题材──┐
 导演 direct ──意图─┤→ ShotPlan v2 → LensPlanner ─→ 镜头/变焦
                    │                 ExposureProgram → 光圈/快门/ISO（全手动）
 感知 Perception ───┤→ 测量 ────────→ CompositionSolver → 裁切框
                    │                 MomentScorer ──→ 时机分 → 自动拍
                    └→ DirectorScheduler v2（何时问云端、何时拍）
 拍摄：BurstCapture（6 张）→ BurstAnalyzer（Vision）→ BurstSelector → 相册 + BurstStore
```

纯逻辑全部放在 CameraCore，用 Swift Testing 覆盖：ShotPlan v2、ExposureProgram、LensPlanner、MomentScorer、BurstSelector、DirectorScheduler v2、提示词与工具 schema。

App 层只做硬件和 Vision：CaptureSession、Perception、Executor、AgentController、BurstAnalyzer、BurstStore。

## 4. ShotPlan v2（意图）

```json
{
  "genre": "portrait", "genreConfidence": 0.9, "subject": "face",
  "composition": { "ratio": "3:4", "anchor": {"x":0.5,"y":0.36},
                   "subjectSize": {"min":0.14,"max":0.24}, "minCropArea": 0.25, "levelHorizon": false },
  "lens": { "focalLength": 48 },
  "exposure": { "meter": "subject", "subjectEV": 0.3, "highlightClipMax": 0.01,
                "motion": "freeze", "depth": "shallow", "shutterFloor": 0, "isoCeiling": 0 },
  "moment": [ {"kind":"eyesOpen","threshold":0.6}, {"kind":"faceToward","threshold":25} ],
  "holdMs": 200,
  "rationale": "…"
}
```

字段说明：
- `lens.focalLength`：等效焦距（mm）。0 表示用题材默认值。本机吸附到最近的物理镜头档。
- `exposure.motion`：
  - `freeze`：冻结动作。
  - `normal`：手持安全。
  - `blur`：允许拖影，只在手机稳定时生效。
- `exposure.depth`：`shallow` / `normal` / `deep`，只影响可变光圈的主摄。
- `subjectEV`：主体相对 18% 线性中灰的目标亮度，单位 EV，范围 −2…2。
- `shutterFloor` 和 `isoCeiling`：可选的覆盖值，0 表示由程序决定。
  - 最慢快门：0 或 1/1000…1 秒。
  - ISO 上限：0 或 100…12800。
- `moment`：「时机信号」，即让这一刻更好的条件，不是前提条件。种类与阈值范围沿用现有 Trigger：
  - `subjectSharp` / `eyesOpen`：0…1。
  - `faceToward` / `horizonLevel`：0…45°。
  - `deviceStill`：0…2 rad/s。
  - `subjectPlaced`：0…0.5。
  - `highlightsSafe`：0…0.05。
  - `exposureSettled` 与 `subjectPresent` 取消（由程序隐含处理），解码时遇到会忽略。
- 删除 `exposure.aperture`：光圈由 `depth` 推出，不让模型直接写 f 值。

`validate(against: CameraLimits)`：
- 每种信号的阈值都按各自范围检查。
- 焦距检查：为 0，或落在 [最短档 × 0.8, 最长档 × 1.25] 之内。
- 失败时返回带字段名的错误文字，下一次导演请求原样反馈给模型（I6）。

11 个题材知识库的 `defaultPlan` 全部迁移到 v2。默认焦距：

| 焦距 | 题材 |
|---|---|
| 48 | 人像、静物、美食 |
| 24 | 合影、街拍、风光、夜景、文档、通用 |
| 13 | 建筑 |
| 长焦 | 动物（取长焦档，没有长焦时取 48） |

## 5. 本机执行

### 5.1 LensPlanner（纯函数）

1. 镜头档来自设备，以等效焦距表示：超广角 13，主摄 24，主摄 2× 裁切 48，长焦 = 24 × 长焦倍率（虚拟设备的 switch-over 倍率换算而来）。
2. 目标焦距按对数距离吸附到最近的档。方案不变时不切换，避免来回跳。
3. **弱光回退**：在非主摄镜头上，如果 ExposureProgram 连续 1 秒报告 `starved`（ISO 到顶且快门到最慢），本方案改用主摄 24，并且不再切回。
4. 输出显示倍率，例如 0.5、1、2、4。执行层用 ramp 平滑变焦，变焦时重置裁切弹簧。

### 5.2 ExposureProgram（纯函数，替换 ExposureController）

输入：
- 意图。
- 测光值：0…1 的编码亮度，取自 subjectMean、mean 或 clipHigh。
- 当前实际的光圈、快门、ISO。
- 设备范围：ISO、快门、光圈档、是否可变光圈。
- 运动信息：手机角速度、主体速度、等效焦距。
- 上一次写入是否仍在生效中。

算法：
1. **线性化（修 I5）**：按 sRGB EOTF 把编码亮度换算成线性值 `Y`，目标为 `0.18 × 2^subjectEV`。
2. **误差** `Δ = log2(目标 / max(Y, 1e-4))`。
   - 高光保护：`clipHigh > highlightClipMax` 时，`Δ = min(Δ, −1/3)`。
   - `clipHigh ≥ 0.8 × 上限` 且 `Δ > 0` 时，`Δ = 0`。
   - 死区：`|Δ| ≤ 1/6` 时保持不动。
   - 每步只校正 `0.6 × Δ`，并限制在 ±1 EV 之内。
   - 上一次写入未生效时保持不动，防止测光滞后引起振荡。
3. **需要的进光量** `H = t × S / N² × 2^step`。
4. **光圈**（只在可变光圈时调整，否则固定）：
   - `shallow` 和 `normal`：最大光圈。
   - `deep`：最接近 f/4 的档。
5. **快门**：
   - 手持安全快门 `tH = clamp(1 / (2 × 等效焦距), 1/500, 1/30)`。手机角速度低于 0.03 rad/s 时放宽到 `tH × 4`，最慢 1/8 秒。
   - `freeze`：`t = clamp(0.0015 / max(主体速度, 0.006), 1/2000, 1/250)`。
   - `normal`：`t = min(tH, 0.003 / max(主体速度, 0.003))`。
   - `blur`：手机稳定时为 1/15 秒，否则为 `tH`。
   - `shutterFloor > 0` 时，以它作为最慢快门。
6. **ISO**：`S = H × N² / t`。
   - ISO 上限：`isoCeiling` 非 0 时取它，否则取 1600；夜景题材默认 6400。超过上限时，先把快门放慢，最多到最慢快门；仍不够就按上限欠曝，并报告 `starved`。
   - 低于设备最低 ISO 时，把快门加快到设备极限；仍过亮就接受过曝，由高光保护在下一步处理。
7. **收敛判定（settled）**：连续 2 帧 `|Δ| ≤ 1/3`，或者已经到达设备极限。

执行层用 `setExposureModeCustom(lensAperture:duration:iso:)` 写入全手动参数，测光完全由本机完成。

AI 的曝光写入**不置 `isApplying`**，因此不会阻塞快门。只有用户在界面上改光圈时，才继续使用 `isApplying`。

### 5.3 对焦

主体中心变化超过 0.05 时，执行层设置对焦兴趣点，使用连续自动对焦。没有主体时用画面中心。全手动曝光下不再设置测光兴趣点（我们自己测光）。

### 5.4 MomentScorer（纯函数，替换 TriggerEvaluator 的放行判定）

1. **每个信号的余量**沿用 TriggerEvaluator 的计算：满足记 1 分，否则记 `max(0, 1 + margin)`。
2. **数据缺失的信号不参与计分**，例如室内没有地平线、没检测到脸时的睁眼判定（修复「室内永远不拍」）。
3. **隐含信号**：「曝光已收敛」始终参与计分，未收敛记 0.5 分。
4. **时机分**取所有参与信号的几何平均；没有任何信号时为 1。
5. **以下情况时机分为 0**：
   - 方案要求主体但当前没有主体。
   - 测量已超过 0.3 秒。
6. **自动拍摄**，满足以下任一条件即触发：
   - **完美**：时机分 ≥ 0.999，并持续 `holdMs`。
   - **耐心**：进入取景状态后已满 4 秒，当前分 ≥ 0.6，且不低于这 4 秒内最高分的 95%。
7. 报告 `{statuses, score, fireReady, reason}`。界面用 `score` 显示快门环的亮度。

### 5.5 裁切与画幅

沿用 CompositionSolver 和 CropSpring。拍摄时把画幅与裁切框一起交给拍摄，不再依赖异步的 `setRatio`（修 I4）。

## 6. 连拍与选片

1. **BurstCapture**（App）：
   - AI 开启时，每次拍摄连拍 6 张，间隔约 100 ms。
   - 尺寸取设备支持的不超过 24 MP 的最大尺寸，质量优先级用 `.speed`；设备支持时开启 responsive capture 和 fast capture prioritization。
   - 连拍期间冻结曝光写入和裁切框。
   - 每张都按同一个画幅和裁切框裁好再编码成 JPEG。
2. **BurstAnalyzer**（App）：
   - 每张缩到长边 1024 后，测清晰度（主体框内的 Laplacian 方差）、睁眼程度、人脸质量（Vision）和系统美学分。
   - 6 张在后台依次分析，失败的指标记为缺失。
3. **BurstSelector**（CameraCore，纯函数）：
   - 每项指标在这一组内做 min-max 归一化，按题材加权求和，选出最高分。
   - 人像和合影：人脸质量 0.35、睁眼 0.3、清晰度 0.25、美学 0.1。
   - 其他题材：清晰度 0.6、美学 0.4。
   - 缺失的指标不参与计分；全部缺失时选第一张。
4. **保存**：
   - 最好的一张走现有流程存入系统相册。
   - 其余几张存到 `Application Support/Bursts/<photoID>/`，附带 `manifest.json`，记录日期、选中序号、各张得分和题材。
   - 启动时删除 7 天前的组，最多保留 30 组。
5. **照片详情**：
   - 存在备选时显示一排缩略图，AI 选中的那张标「AI 选择」。
   - 点「换成这张」会把这张也存入相册，并把用户的选择记进 CaptureRecord（`chosenIndex`），供子项目 4 学习。
   - A 不删除相册里原来那张：删除需要完整相册权限和系统确认，留到以后。
6. **AI 关闭时**仍然单张拍摄，行为不变。

## 7. 导演与调度

### 7.1 云端调用

- **侦察 scout**：沿用现有逻辑（非思考，768 px）。
- **导演 direct**：替换 judge（思考模式，1280 px）。只有一个工具 `set_plan`，参数包括：
  - `plan`：v2 意图。
  - `critique`：七项量表的分数和证据，不含 verdict。
- 删除 `keep_plan` 和 approve 模式。量表只用来让模型基于证据思考，以及在界面和日志里展示，不参与任何判定。
- 方案校验失败时，把错误文字作为下一次导演请求的反馈；最多重试 1 次，仍然失败就保持题材默认意图，直到场景变化（修 I6）。
- 工具 schema 的阈值描述按信号种类写出各自的范围，焦距写出本机可用的镜头档。

### 7.2 DirectorScheduler v2（纯状态机）

阶段：`off → scouting → planning → composing ⇄ capturing → cooldown`，另有 `paused`。

| 事件 | 行为 |
|---|---|
| start | 进入 scouting，方案为通用默认，发出侦察 |
| 侦察回复：需要新方案（默认方案、题材变化、场景变化或方案已不适用） | 立即换成该题材的默认方案，进入 planning，发出导演请求 |
| 侦察回复：方案仍适用 | 进入 composing，重置场景基线，清空 `sceneChangeSince` 和 `subjectLostSince`（修 I2） |
| 侦察失败，且从 start 起 3 秒内没有一次成功的侦察 | 用通用默认方案进入 composing，退避后再侦察 |
| 导演回复有效 | 采用新方案，进入 composing，重置基线 |
| 导演回复无效 | 带反馈重试 1 次；仍然无效就进入 composing 并保持默认，直到场景变化 |
| 测量（planning 或 composing），自动拍摄开启且 `fireReady` | 进入 capturing，发出 fire |
| 已拍摄（自动或手动） | 进入 cooldown，重置基线 |
| cooldown 中场景变化持续 0.5 秒 | 回到 scouting |
| 场景变化持续 0.5 秒、主体丢失持续 1 秒，或心跳 15 秒（cooldown 以外） | 侦察，间隔不少于 2 秒 |
| fireRejected | 回到 composing |
| rearm（冷却中再拍一张） | 回到 composing |

其他规则：
- 每个请求带一个**单调递增的 requestID**。调度器实例在 AgentController 的整个生命周期内只创建一次，ID 不会因为重新开启 AI 而回到 1。过期的回复在修改任何状态之前就被丢弃（修 I7）。
- 「画面已变化」导致的丢弃不计入失败次数，不加长退避。
- 早返回的路径同样会释放 inFlight（修 minor）。

## 8. 硬件（CaptureSession）

1. **设备**：优先 `builtInTripleCamera`，其次 `builtInDualWideCamera`，再其次 `builtInWideAngleCamera`。
   - 显示倍率用 `displayVideoZoomFactorMultiplier` 换算。
   - 变焦上限放宽到「长焦档 × 2」。
2. **镜头锁定**：选定镜头后，如果设备支持，用 `setPrimaryConstituentDeviceSwitchingBehaviorLocked(with:)` 锁定物理镜头，让手动曝光作用在确定的镜头上。
3. **可行性验证（任务 1，先于其他硬件改动）**：
   - 在真机上逐个验证：虚拟设备上的全手动曝光、可变光圈经由虚拟设备是否可用、镜头锁定、连拍速度。
   - 如果虚拟设备不支持全手动曝光，改为切换物理设备输入（换镜头时取景会短暂停顿），对上层接口不变。
   - 结论写进 ledger。
4. **手动参数界面**：光圈刻度盘只在当前为主摄时可用，其他镜头显示固定光圈。

## 9. 上一轮审查问题的处理

| 编号 | 处理 |
|---|---|
| C1 | Perception 修复：<br>• 各档结果带时间戳，超过 0.5 秒的丢弃。<br>• 设备过热到 critical 时清空缓存。<br>• 跟踪失败即清空 tracked。<br>• 同类检测为空时丢弃 tracker。<br>• await 之后用 epoch 防止写回旧状态。 |
| I1 | 放行机制删除，问题随之消失。 |
| I2 | 见 §7.2「侦察回复：方案仍适用」。 |
| I3 | `keep_plan` 删除，问题随之消失。默认方案按侦察到的题材取。 |
| I4 | 见 §5.5。 |
| I5 | 见 §5.2 第 1 步。 |
| I6 | 见 §7.1。 |
| I7 | 见 §7.2 的 requestID 规则。 |
| minor：室内永远不拍 | 见 §5.4 第 2 步。 |
| minor：开 AI 时变焦不复位 | 由 LensPlanner 设定焦段。 |
| minor：AgentCompat.swift | 删除。 |
| minor：CaptureRecordStore 并发写入 | 改为串行 actor。 |
| minor：isFresh 在主线程编码 JPEG | 签名改在后台计算。 |

## 10. 测试

- **CameraCore 单元测试（Swift Testing）**，覆盖 §4–§7 的每条规则，例如：
  - ExposureProgram 的线性化。
  - 弱光下先放慢快门、再到 ISO 上限、最后报告 `starved`。
  - `freeze` 时的快门下限。
  - MomentScorer 在缺失地平线时仍然能拍。
  - 耐心期触发。
  - 调度器：侦察保持方案后不再风暴；离线 3 秒回退；requestID 跨重启单调。
  - BurstSelector 的权重与缺失指标处理。
- **离线导演**：DEBUG 启动参数 `-LogitOfflineDirector` 让侦察返回 general、导演请求失败，用于在真机上不花 API 额度地跑完整的本地闭环。
- **真机 UI 测试**：
  - AI 开启时按快门一定出片，不出现「相机正在调整」。
  - 静止场景自动拍下一组，详情里能看到备选。
  - 现有截图场景和交互测试继续通过。
- **真机实测**：用真实 API 跑几次导演调用和一段自动拍摄，额度花费在几分钱级别。

## 11. 风险

| 风险 | 影响 | 应对 |
|---|---|---|
| 虚拟设备不支持全手动曝光 | 换镜头时取景短暂停顿 | §8 第 3 步的回退方案 |
| 预览帧经过 ISP 色调映射，线性化只是近似 | 曝光误差 | 闭环迭代收敛，并用真机实测校准 |
| 全手动 `.speed` 拍摄失去 Deep Fusion 和 Smart HDR | 画质 | 接受这个代价换取可控性；高光保护和测光由本机负责 |
| 6 张 24 MP 照片约占 60 MB 内存 | 内存压力 | 依次编码，分析完即释放 |
