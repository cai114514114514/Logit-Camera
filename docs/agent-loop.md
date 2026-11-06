# Agent 内核：导演 + 本地摄影助理

实现日期：2026-11-07。设计文档：[superpowers/specs/2026-11-06-agent-core-design.md](superpowers/specs/2026-11-06-agent-core-design.md)。

## 为什么重写

旧的 loop 每 5 秒把一张低清图发给模型，让它直接给出一组参数或「保持」，再由模型连续两次说「可以拍」后倒计时 3 秒。它的问题是：模型几乎看不清画面（`detail: low`、关闭思考）；提示词只有泛泛的原则，没有题材与审美标准；没有客观测量；构图只能居中裁切；固定轮询抓不住瞬间。

## 分工

| 角色 | 在哪里 | 做什么 |
|---|---|---|
| 导演（侦察档） | `deepseek-flash`，关思考，512 低清 | 识别题材，判断现有方案是否仍适用（约 1.5 s） |
| 导演（评审档） | `deepseek-flash`，思考 high，原图 | 按题材打法写出拍摄方案，按七项量表逐项打分并给证据（约 9–13 s） |
| 感知 | 手机本地，约 10 Hz | 主体跟踪、人脸朝向与睁眼、地平线、显著区域、直方图与高光溢出、清晰度、手抖、场景变化、系统美学分 |
| 执行 | 手机本地 | 对焦点跟随主体、曝光闭环（EV 补偿与最慢快门）、裁切框求解与平滑、逐帧判定拍摄条件 |
| 调度 | `DirectorScheduler`（纯状态机） | 何时问哪一档、何时放行、何时拍、失败退避 |

模型只产出 `ShotPlan`（构图、曝光意图、拍摄条件）和评分，没有硬件与快门权限。

## 一次拍摄的过程

1. 开启 AI：本地立即以「通用」默认方案辅助对焦和曝光（不会放行），同时侦察。
2. 侦察判断题材 → 评审以该题材打法为起点写出方案（画幅、主体锚点、主体占比、曝光意图、拍摄条件）并打分。
3. 执行层按方案移动裁切框、测光、对焦；拍摄条件逐帧判定。条件全部满足或只差一项（差距 ≤ 20%）时请求评审放行。
4. 放行规则由客户端强制：权重大于 0 的每一项 > 1 分，且加权总分 ≥ 3.0；模型的结论只能更严。
5. 放行后进入「就绪」：拍摄条件全部满足并持续 holdMs（默认 200 ms）的瞬间拍摄，裁切框冻结到成片。
6. 冷却：同一场景不再自动拍摄；场景变化后自动重新侦察，或点「再拍一张」。

放行在 10 秒后或画面漂移（场景变化 > 0.08）时失效。场景变化持续 0.5 秒、主体丢失 1 秒或 15 秒无调用时重新侦察。侦察最短间隔 2 秒、评审 4 秒；同一时间只有一个请求在途；对应帧超过 12 秒或画面已明显变化的回复会被丢弃。

## 审美从哪里来

- **题材打法**（`CameraCore/Sources/CameraCore/Resources/Knowledge/genres/*.json`）：人像、合影、街拍人文、风光、建筑与室内、美食、静物与产品、夜景弱光、宠物与动物、文档与实用、通用。每个打法有识别线索，构图、光线、曝光、时机、常见失误五组可执行的原则，量表权重，题材特有项，以及默认方案。
- **七项量表**（`rubric.json`）：主体清晰、曝光与影调、构图、光线质量、背景与干扰、时机、题材特有项，每项 0 / 2 / 4 分有文字锚定，每个分数必须引用测量值或画面位置作为证据。
- **测量优先**：能测量的（清晰、溢出、地平线、睁眼、朝向、手抖）由本地判定并编译成拍摄条件；模型只评测量覆盖不到的部分（光线质量、背景、表情）。系统美学分只作参考输入。
- **评测**：[eval/README.md](../eval/README.md) 用公开数据集（SPAQ、TAD66K）的人工评分衡量题材准确率、Spearman 相关与 AUC。

## DeepSeek 接口事实（2026-11-06 官方文档 + 真机验证）

- 能看图的模型只有 `deepseek-flash`；`deepseek-v4-pro` 不支持图像输入。
- 思考模式 + 工具调用要求回传上一轮 `reasoning_content`，否则返回 400。评审每个场景只保留最近一次交换，且记忆中不重复发送图像。
- **思考模式不支持 `tool_choice: required`**（文档未写，真机返回 400），评审使用 `auto`，未调用工具视为一次可重试失败。
- 严格工具（Beta，`/beta` 端点）：不使用 `null` 类型，「不限制」用 0 表示；客户端仍用 schema 二次校验回复。

## 安全

没有评审放行永不自动拍摄；手动调参即停止 AI（点按对焦除外）；后台与相机中断暂停；密钥与额度错误停止；断网时只做本地辅助、不自动拍摄。密钥保存在 Keychain；开启 AI 时取景图与测量通过 HTTPS 发送给 DeepSeek；每张 AI 照片的方案、测量与评分只保存在本机（`CaptureRecords.json`），供后续选片与偏好学习使用。

## 调研依据

- [DeepSeek Vision](https://api-docs.deepseek.com/guides/vision/)、[Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode)、[Tool Calls](https://api-docs.deepseek.com/guides/tool_calls)、[Pricing](https://api-docs.deepseek.com/quick_start/pricing)
- Apple Vision（iOS 27 SDK）：`DetectFaceLandmarksRequest`、`DetectFaceCaptureQualityRequest`、`DetectHumanRectanglesRequest`、`DetectHorizonRequest`、`GenerateAttentionBasedSaliencyImageRequest`、`CalculateImageAestheticsScoresRequest`、`ClassifyImageRequest`、`TrackObjectRequest`
- [Anthropic：Building effective agents](https://www.anthropic.com/research/building-effective-agents)：把环境反馈纳入循环；本实现把「判断」与「执行」分离，用确定性的本地状态机约束模型。
