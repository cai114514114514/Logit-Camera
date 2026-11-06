# Logit Camera Agent 内核重设计：「导演 + 本地摄影助理」

日期：2026-11-06
状态：待审阅
所属：AI 原生相机路线图 · 子项目 1（共 5 个）

## 0. 路线图与本文范围

| 顺序 | 子项目 | 状态 |
|---|---|---|
| **1** | **Agent 内核：模型层、本地感知、题材知识库与量表、方案驱动的 loop、偏心裁切** | 本文 |
| 2 | 连拍 + AI 选片 | 后续 |
| 3 | 意图 + 风格预设 + 参考图 | 后续 |
| 4 | 偏好学习 | 后续 |
| 5 | 动态滤镜 | 后续 |

本文只设计子项目 1，但为 3、5 预留字段，并为 2、4 保存所需数据。

## 1. 目标、已确认决策与成功标准

**问题**（来自现有实现）：取景图以 `detail: low` 发送且关闭思考，模型几乎看不清；提示词只有泛泛的原则，没有题材知识与审美标准；没有客观测量，全靠看一张 JPEG；动作只有「整组调参 / 保持」，构图只能居中裁切；「可以拍」仅是模型两次返回 true；固定 5 秒轮询，抓不住瞬间。

**用户已确认**
- AI 角色：全自动摄影师 + 意图驱动（意图在子项目 3），不指导用户移动手机。
- 模型策略：模型层可插拔；**本期只实现 DeepSeek**；两档分工。
- 审美来源：题材知识库 + 评分量表（本期）；风格预设、偏好学习、连拍选片（后续子项目）。
- 架构：方案 C「导演 + 本地摄影助理」。
- 感知：系统美学分只作为参考输入，不直接决定是否拍摄。
- 评测：使用公开美学数据集；数据集自带人工评分即为标准答案。
- 裁切预览：全画幅 + 裁切框。
- 拍摄触发：评审放行后「就绪即拍」，取消 3 秒倒计时。

**成功标准**
1. 模型每次判断都引用可测量证据或画面位置，七项量表结构由 API 严格 schema 保证。
2. 画面静止、方案有效时不发送请求；场景变化后 ≤ 2.5 秒内发起侦察（0.5 s 确认 + 最短间隔 2 s）。
3. 拍摄条件满足到快门触发的本地延迟 ≤ 150 ms（不含相机自身处理）。
4. 没有评审放行永不自动拍摄；所有现有安全语义保留（§7）。
5. 离线评测可运行，输出题材识别准确率、与人工评分的相关性（Spearman）和好/差区分度（AUC），作为后续迭代的基线。
6. CameraCore 新增逻辑全部有单元测试；真机构建与 UI 测试通过。

## 2. 外部事实（已核实）

**DeepSeek API**（api-docs.deepseek.com，2026-11-06 读取）
- `deepseek-flash`（DeepSeek-V4.1-Flash）：支持图像输入、工具调用、思考/非思考模式（默认思考，effort 高）。上下文 1M。
- `deepseek-v4-pro`：**不支持图像输入**，本期不用。
- 思考开关：`"thinking": {"type": "enabled" | "disabled"}`；强度 `"reasoning_effort": "low" | "high" | "max"`。思考模式忽略 temperature。
- 思考 + 工具调用：请求带 tools 时必须回传此前各轮的 `reasoning_content`，否则返回 400。
- 严格工具（Beta）：`base_url` 使用 `https://api.deepseek.com/beta`，每个函数 `"strict": true`，`additionalProperties: false` 且所有属性 required；支持 enum、number 的 minimum/maximum、anyOf、$ref；**不支持** string minLength/maxLength、array minItems/maxItems。
- 图像：`detail: "low"` 先缩到 512×512；`"high"/"original"` 保留原图；每图上限约 1024 token；图像只能放在 user 消息中。
- 价格（每百万 token，峰时）：flash 输入 $0.3（缓存命中 $0.006）、输出 $1.2。成本不是瓶颈，延迟是。
- 文档未说明「工具调用 + 图像输入」可同时使用；现有实现已在真机成功使用该组合（README 记录），实现时以录制样本回归保证。

**Vision（iOS 27 SDK，已在本机 swiftinterface 核实存在）**：`DetectFaceRectanglesRequest`、`DetectFaceLandmarksRequest`、`DetectFaceCaptureQualityRequest`（FaceObservation 含 roll/yaw/pitch）、`DetectHumanBodyPoseRequest`、`DetectHorizonRequest`（angle）、`GenerateAttentionBasedSaliencyImageRequest`、`CalculateImageAestheticsScoresRequest`（overallScore、isUtility）、`ClassifyImageRequest`、`TrackObjectRequest`（有状态）。

**公开数据集**（GitHub 官方页面，2026-11-06 读取）
- SPAQ：11,125 张、66 款手机；MOS、5 项属性分（亮度、色彩、对比、噪点、清晰度）、EXIF、9 类场景（animal、cityscape、human、indoor scene、landscape、night scene、plant、still life、others）。
- TAD66K：约 66,000 张、47 个主题，每张至少 1200 人评分取均值；分发版最长边 800 px。
- **两者均未声明数据许可**。因此**仓库不分发图片**，只提供抽样清单（图片 ID + 标签）与下载说明；开发者自行下载到本地。

## 3. 架构总览

```text
           ┌──────────── 本地，实时 ────────────────────────────┐
 取景帧 ──▶│ Perception（感知）→ SceneMeasurement                  │
           │        ▼                                            │
           │ Executor（执行）◀── 当前 ShotPlan ◀──────────────┐    │
           │  对焦/曝光闭环 · 构图求解（裁切框）· 条件判定 · 快门  │    │
           └─────────────┬────────────────────────────────┼────┘
                         │ 事件（Scheduler 纯状态机决定）     │
                         ▼                                  │
           ┌──────────── 云端，按事件 ──────────────────────┐ │
           │ Director：VisionModel 协议 → DeepSeekAdapter   │─┘
           │  scout（快档）/ judge（评审档）                  │
           └────────────────────────────────────────────────┘
                  ▲ Knowledge：题材打法 + 量表 + 提示词（CameraCore 资源）
```

**模块与位置**

| 模块 | 位置 | 职责 |
|---|---|---|
| `ShotPlan`、`SceneMeasurement`、`Rubric`、`Trigger` | CameraCore | 纯数据、Codable、校验 |
| `TriggerEvaluator` | CameraCore | 逐帧判定拍摄条件，含持续时间 |
| `CompositionSolver` | CameraCore | 由主体与方案计算裁切框，弹簧平滑 |
| `MeasurementMath` | CameraCore | 直方图、溢出、清晰度、睁眼程度、场景变化度 |
| `Knowledge` | CameraCore（资源） | 题材打法 JSON、量表、提示词模板；加载与校验 |
| `DirectorScheduler` | CameraCore | 纯状态机：输入事件 + 时钟，输出「调哪一档 / 状态迁移」 |
| `VisionModel` 协议、`DeepSeekAdapter`、请求构造与解析 | CameraCore（网络调用用 URLSession，可在 macOS 测试） | 两档调用、严格 schema、思考内容回传 |
| `Perception` | App | Vision 请求、vImage 统计、CoreMotion；按档调度 |
| `Executor` | App | 唯一的硬件写入入口（相机串行队列） |
| `AgentController` | App（MainActor，@Observable） | 组装以上部分，向 UI 暴露状态；取代 `CameraAgent` |
| `LogitEval` | CameraCore 可执行目标 | 离线评测 |

模型只产出方案与评分；不触碰硬件、不能按快门。执行层不做审美判断。

## 4. 感知层 Perception

在独立队列运行，**仅 AI 开启时启用**；处理不过来就丢帧。输入为 `FrameGrabber` 最新缓冲，降采样到长边 640 后送入 Vision。

| 档位 | 频率 | 测量 | 实现 |
|---|---|---|---|
| 快 | ~10 Hz | 亮度直方图（64 档）、高光（≥ 250/255）与暗部（≤ 5/255）溢出比例、全局与主体平均亮度 | vImage 统计 Y 平面 |
| | | 清晰度：全局与主体区域 | 降采样拉普拉斯方差，按亮度归一 |
| | | 手机角速度 | CoreMotion 60 Hz，0.3 s 滑动平均 |
| | | 主体跟踪：框、速度 | `TrackObjectRequest`，以主体框初始化 |
| | | 场景变化度 | 16×16 亮度签名（沿用）相对方案基线 |
| 中 | 3–5 Hz | 人脸框、roll/yaw/pitch、左右眼睁开程度（眼部关键点纵横比）、人脸成像质量 | `DetectFaceLandmarksRequest`、`DetectFaceCaptureQualityRequest` |
| | | 人体姿态（仅人像/合影/街拍） | `DetectHumanBodyPoseRequest` |
| | | 地平线角度 | `DetectHorizonRequest` |
| 慢 | 1 Hz 或场景变化 | 显著性区域 | `GenerateAttentionBasedSaliencyImageRequest` |
| | | 系统美学分、是否实用照片 | `CalculateImageAestheticsScoresRequest` |
| | | 场景标签 top-5 | `ClassifyImageRequest` |

**主体选择**：方案指定 > 人脸（最大且质量最高）> 人体 > 显著区域 > 无主体。

**`SceneMeasurement`**（坐标统一为直立全画幅归一化坐标，左上为原点）：`timestamp`、`subjects[]`（kind、box、confidence、trackID、yaw/pitch/roll、eyeOpenness L/R、faceQuality）、`primarySubjectID`、`luminance`（histogram、clipHigh、clipLow、mean、subjectMean）、`sharpness`（global、subject）、`horizonDegrees?`、`deviceAngularSpeed`、`subjectSpeed`、`sceneChange`、`aesthetics`（score、isUtility、labels）。

**功耗**：`ProcessInfo.thermalState` 为 serious 时各档频率减半，critical 时停用中、慢档。快档目标单次 < 8 ms（真机测量记录）。

## 5. 题材知识库与评分量表

### 5.1 题材打法

每个题材一个文件：`CameraCore/Sources/CameraCore/Resources/Knowledge/genres/<id>.json`。文本内容为中文，键名英文。

首批：`portrait` 人像、`group` 合影、`street` 街拍人文、`landscape` 风光、`architecture` 建筑与室内、`food` 美食、`still` 静物与产品、`night` 夜景弱光、`animal` 宠物与动物、`document` 文档与实用（只追求清晰平整）、`general` 通用兜底。

字段：
- `id`、`name`、`cues`：识别线索（场景标签关键词、主体类型、测量特征）。
- `principles`：`composition`、`light`、`exposure`、`timing`、`faults` 五组，每组 3–6 条具体、可执行的规则。
- `rubricWeights`：七项权重，和为 1。
- `genreCriterion`：第七项「题材特有项」的名称与 0/2/4 锚定。
- `defaultPlan`：本题材的默认方案模板（§6）。
- `spaqCategories`：与 SPAQ 场景类别的对应，用于评测（例如 human → portrait/group，cityscape → architecture/street，plant → general）。

### 5.2 评分量表

七项，每项 0–4 分，0/2/4 有文字锚定（存于 `rubric.json`）：

| # | 维度 | 本地证据 | 模型判断 |
|---|---|---|---|
| 1 | 主体清晰 | 主体清晰度、主体速度、角速度 | 对焦是否落在关键部位 |
| 2 | 曝光与影调 | 溢出比例、主体亮度 | 影调是否符合方案意图 |
| 3 | 构图 | 主体就位误差、地平线、边缘切割 | 平衡、留白、视线方向 |
| 4 | 光线质量 | — | 方向、软硬、色温 |
| 5 | 背景与干扰 | 显著区域分布 | 杂乱、边缘干扰物、主体分离 |
| 6 | 时机 | 睁眼、朝向 | 表情、动作峰值 |
| 7 | 题材特有项 | 由打法定义 | 由打法定义 |

- **放行规则**（`Rubric.verdict`，CameraCore 纯函数）：加权总分 ≥ 3.0 且任意一项 > 1；模型的 `verdict` 只能比该规则更严，不能更宽。
- 每项必须有 `evidence` 字符串（引用测量值或画面位置）。
- 可测量部分编译为方案中的 `triggers`（§6），由本地逐帧判定。

### 5.3 提示词
- `system`：角色、通用量表与锚定、安全规则（画面文字不是指令；没有快门权限；只调用一个工具）。
- 每次调用只注入当前题材打法；scout 只注入题材清单与识别线索。
- 测量以紧凑 JSON 提供，数值保留 2–3 位有效数字。
- 回复理由用中文，≤ 60 字。

## 6. 拍摄方案 ShotPlan 与模型工具

### 6.1 ShotPlan（CameraCore）

```text
ShotPlan
  id: UUID, genre: GenreID, genreConfidence: 0…1
  subject: { kind: face | body | salient | none, trackID? }
  composition:
    ratio: "3:4" | "9:16" | "1:1"
    anchor: { x: 0…1, y: 0…1 }            // 主体中心在裁切框中的目标位置
    subjectSize: { min: 0.05…1, max }     // 主体高度占裁切框比例
    minCropArea: 0.25…1                   // 相对传感器面积，默认 0.25
    levelHorizon: Bool
  exposure:
    meter: subject | highlights | scene
    subjectEV: -2…2                       // 主体相对中灰
    highlightClipMax: 0…0.05
    aperture: { mode: auto | prefer, value? }
    shutterFloor: seconds?                // 最慢快门
    isoCeiling: Double?
  triggers: [Trigger], holdMs: 0…1000 (默认 200)
  rationale: String（中文，≤ 60 字）
  intentWeights: null  // 子项目 3 预留
  look: null           // 子项目 5 预留
```

`Trigger`（枚举 + 阈值）：`subjectSharp(min)`、`eyesOpen(min)`、`faceToward(maxYawDegrees)`、`horizonLevel(maxDegrees)`、`deviceStill(maxRadPerSec)`、`subjectPlaced(maxError)`、`highlightsSafe(maxClip)`、`exposureSettled`、`subjectPresent`。

`ShotPlan.validate(against: CameraLimits)`：范围、枚举、与设备能力（光圈、快门、ISO）匹配；不合法即拒绝，原因作为工具结果回传。

### 6.2 工具（严格 schema，每次恰好一个）
- **scout**（`deepseek-flash`，非思考，`detail: low`）：
  `classify_scene { genre, confidence, sceneChanged, planStillValid, subjectHint: face|body|salient|none, reason }`
- **judge**（`deepseek-flash`，思考 `reasoning_effort: high`，`detail: original`）：
  - `set_plan { plan, rubric }`：新方案（或整份替换）＋ 对当前画面的评分。
  - `keep_plan { rubric, verdict: approve | wait, reason }`：方案不变，评分并放行或等待。
- `rubric` = 七项 `{ score: 0…4 (integer), evidence }` + `verdict`。
- 上下文：每个场景只保留最近一次 judge 交换（含 `reasoning_content`）；场景变化或新方案后清空。scout 无历史。

### 6.3 构图求解器 CompositionSolver
- 输入：主体框（来自跟踪）、`composition`、传感器纵横比；输出：裁切框（归一化）与就位误差。
- 先由 `subjectSize` 定裁切框尺寸（取范围中点，受 `minCropArea` 与传感器边界约束），再由 `anchor` 定位置，最后夹在传感器内；夹取导致的偏差即「就位误差」。
- 无主体（风光等）：以显著性重心或画面中心为参考，按三分法放置地平线位置。
- 平滑：二阶临界阻尼弹簧（时间常数 0.35 s），每帧更新；主体速度过高时放宽跟随，避免追逐抖动。
- AI 模式下取景保持 1×；构图全部由照片裁切完成。用户双指缩放仍可用（属于接管）。

## 7. Loop、状态机与安全

### 7.1 状态
`off` → `scouting` → `planning` → `tracking` → `reviewing` → `armed` → `capturing` → `cooldown`；任意状态可进入 `paused`（后台、中断、拍照处理中）或 `off`（手动接管、密钥错误）。

### 7.2 调度规则（`DirectorScheduler`，纯函数，可测试）
- scout：AI 开启；`sceneChange` 持续 0.5 s 超过 0.18；主体丢失 > 1 s；15 s 心跳。最短间隔 2 s。
- judge：scout 返回 `planStillValid == false` 或题材变化（新方案）；`tracking` 且拍摄条件已全部满足、或最多一项未满足且距阈值不超过 20%，并持续 0.5 s（请求放行）；`armed` 超过 10 s 或相对放行帧的 `sceneChange` > 0.08（重新确认）。最短间隔 4 s。
- 全局只有一个请求在途；`generation` 令牌；取消与现状一致。
- 过期丢弃：响应对应帧超过 12 s 或 `sceneChange` > 0.18。
- 错误：网络错误退避（5→30 s）；401/402/403 停止并提示；严格 schema 失败或方案校验失败视为一次失败并把原因回传下一次 judge。

### 7.3 执行层（相机串行队列）
- 对焦：`continuousAutoFocus`，对焦点跟随主体中心，位移 > 0.05 才更新。
- 曝光：10 Hz 比例控制，步长 ≤ 0.1 EV，死区 ±0.1 EV；测光点在主体上；EV 补偿使主体亮度趋近 `subjectEV`，并保证高光溢出 ≤ `highlightClipMax`；光圈按方案（光圈优先）；仅当自动快门慢于 `shutterFloor` 时切换为「固定快门 + 自动 ISO」，并遵守 `isoCeiling`。
- 构图：每帧求解裁切框，发布给 UI 与拍摄。
- 条件：`TriggerEvaluator` 每个测量周期更新；在 `armed` 且全部满足持续 `holdMs` 时直接触发拍摄。
- 拍摄时冻结当前裁切框；`PhotoFraming` 扩展为任意裁切框（不再只居中）；EXIF 与方向处理沿用。

### 7.4 安全语义
保留：单请求在途、可取消、手动调参即停止 AI、后台与中断暂停、硬件超时恢复自动曝光、密钥错误停止。
新增：**没有 judge 放行永不自动拍摄**；放行有时效（10 s）且绑定画面（漂移即失效）；模型无快门与硬件权限；断网时执行层按题材默认方案辅助对焦/曝光/构图但不自动拍摄；每个场景自动拍一张，进入 `cooldown`，场景变化后自动恢复，同一场景需「再拍一张」。

### 7.5 记录
DEBUG 构建记录有上限的诊断（不含图像）：方案、测量摘要、评分、调度事件、触发时刻。每张照片附带一份 `CaptureRecord`（方案 + 测量 + 评分），存在本地，供子项目 2、4 使用；不上传。

## 8. 界面

在 UI 改版基础上：
- AI 开启时取景切换为全画幅 3:4；裁切框以青色细线 + 四角刻线显示，框外压暗 55%；裁切框随求解器平滑移动；`ViewfinderFrame` 的角标绘制在裁切框上。
- 主体括号：淡青色细括号框住当前主体。
- 状态线：阶段（侦察 / 制定方案 / 跟踪 / 复核 / 就绪 / 拍摄 / 冷却）＋ 条件小标记（满足 ✓、未满足 ○）。
- 就绪：快门外圈青色常亮并呼吸；点快门 = 解除就绪；倒计时环移除。
- 新方案标注：`题材 · 理由`。
- 详情面板：方案（题材、构图、曝光意图）、条件实时状态、七项评分条与证据、最近决策记录。
- 手动画幅选择仍是接管；AI 模式下画幅与裁切由方案决定（青色）。

## 9. 离线评测 LogitEval

- CameraCore 新增可执行目标 `LogitEval`，与 App 共用提示词、知识库与 `DeepSeekAdapter`。
- 输入：`eval/manifest-spaq.json`、`eval/manifest-tad66k.json`（仓库内，仅 ID 与标签），本地图片目录（开发者自行下载）、API 密钥（环境变量）。
- 抽样：每个 SPAQ 场景类别 20 张，按 MOS 高低各半；TAD66K 选与 10 个题材对应的主题各 20 张。
- 输出：题材识别准确率与混淆矩阵（SPAQ）；judge 加权总分与人工分的 Spearman 相关；高/低分组 AUC；单次延迟与 token 统计。结果写入 `eval/results/<date>.json`（git 忽略）。
- 不在 CI 中运行（消耗额度）。
- 微调：DeepSeek 文档未提供微调接口，本期不做；记录为后续选项（可用数据集人工分或模型标注生成训练数据）。

## 10. 测试

- CameraCore 单元测试：ShotPlan 校验；TriggerEvaluator（每种条件的边界、holdMs、抖动）；CompositionSolver（靠边夹取、最小裁切、无主体、弹簧收敛）；Rubric.verdict（门槛、加权）；MeasurementMath（合成图）；Knowledge（全部文件可解析、权重和为 1、条件类型存在、SPAQ 映射完整）；DeepSeekAdapter（录制样本：请求体字段、严格 schema、`reasoning_content` 回传、错误码、超时）；DirectorScheduler（事件序列 → 调用决策与状态迁移，注入时钟）。
- App：Perception 以协议注入固定检测结果；演示模式扩展为方案场景（跟踪、就绪、冷却、无主体风光），截图测试覆盖；现有 UI 测试按新状态更新。
- 真机：每个题材实拍若干组，检查延迟、功耗与诊断记录；真实 API 的 UI 测试在用户同意后运行。

## 11. 交付阶段（实施计划将按此拆分）

1. CameraCore 核心类型、求解器、条件判定、量表、知识库（含首批 11 个打法）。
2. 感知层。
3. 模型层：`VisionModel` 协议、`DeepSeekAdapter`、提示词。
4. 执行层、调度器与 `AgentController`，替换 `CameraAgent`；`PhotoFraming` 支持任意裁切框。
5. 界面接入（全画幅 + 裁切框、条件标记、就绪态、详情面板）。
6. `LogitEval` 与评测清单。

## 12. 不在本期

意图输入与风格预设（子项目 3）、连拍与选片（2）、偏好学习（4）、动态滤镜（5）、其他模型服务商适配器、模型微调、横屏、多镜头切换。

## 13. 风险

- **工具调用 + 图像 + 思考的组合**文档未明确：第 3 阶段先做真机最小验证；若不可用，judge 退化为「思考 + JSON 输出」并在客户端严格校验。
- **judge 延迟**（思考模式可能 5–10 s）：放行带时效、本地抓时机，延迟只影响方案更新速度。
- **感知功耗与发热**：分档调度、热状态降级；真机测量。
- **48MP 裁切画质**：`minCropArea` 默认 0.25（约 12MP）。
- **数据集许可未声明**：不分发图片；如需分发须获得作者许可。
- **审美知识质量**：首批打法为 v0，以评测基线驱动迭代，欢迎社区贡献。
