# Agent 内核：导演给意图，相机由本机掌控

实现日期：2026-11-07。设计文档：[superpowers/specs/2026-11-07-camera-control-design.md](superpowers/specs/2026-11-07-camera-control-design.md)。前一版（导演 + 放行）的设计见 [2026-11-06-agent-core-design.md](superpowers/specs/2026-11-06-agent-core-design.md)。

## 为什么又改

真机试用的结论有两条：
- AI 只是在「辅助」，并没有真正去调曝光、ISO、快门和焦段。
- 对着房间这类没有明确主体的场景，它一直拍不下来。

根因有两个：
- 云端评审被放在了快门路径上。它要 9–13 秒才回复，而且评分不到 3.0 分永远不放行。
- 本机只做 EV 补偿和最慢快门，没有真正控制参数。

参考业界做法（Pixel Camera Coach、Top Shot、Vidhance、Arsenal、CameraBench），云端大模型普遍只负责看懂场景、给出方向；毫秒级的参数控制都在本机完成；「时机」靠连拍加事后挑选，而不是等一个许可。

## 分工

| 角色 | 在哪里 | 做什么 |
|---|---|---|
| 侦察 | `deepseek-flash`，关思考，低清 | 识别题材，判断现有意图是否仍适用（约 1.5 s） |
| 导演 | `deepseek-flash`，思考 high，原图 | 用唯一的工具 `set_plan` 给出完整意图，并按七项量表点评当前画面（约 9–13 s）。**没有放行权** |
| 感知 | 本机，约 10 Hz | 主体跟踪、人脸朝向与睁眼、地平线、显著区域、直方图与高光溢出、清晰度、手抖、场景变化、系统美学分 |
| LensPlanner | 本机 | 意图焦距吸附到物理镜头档（13 / 24 / 48 / 96 mm）；非主摄弱光时回退主摄 |
| ExposureProgram | 本机，约 10 Hz | 线性测光；按动作意图选快门，按景深意图选光圈，再算 ISO；全手动写入 |
| MomentScorer | 本机，逐帧 | 时机信号（加分项）的几何平均得分；完美即拍，否则耐心 4 秒后拍下接近最高分的一刻 |
| 连拍选片 | 本机 | 每次拍摄连拍 6 张（约 0.4 秒），按清晰度、睁眼、人脸质量和美学分挑出最好的一张 |
| 调度 | `DirectorScheduler`（纯状态机） | 何时侦察、何时请导演、何时拍；请求编号单调递增；断网 3 秒后回退为本机取景 |

## 意图（ShotPlan v2）

```json
{ "genre": "portrait", "subject": "face",
  "composition": { "ratio": "3:4", "anchor": {"x": 0.5, "y": 0.36}, "subjectSize": {"min": 0.14, "max": 0.24}, "minCropArea": 0.25, "levelHorizon": false },
  "lens": { "focalLength": 48 },
  "exposure": { "meter": "subject", "subjectEV": 0.5, "highlightClipMax": 0.01, "motion": "freeze", "depth": "shallow", "shutterFloor": 0, "isoCeiling": 0 },
  "moment": [ {"kind": "eyesOpen", "threshold": 0.6}, {"kind": "faceToward", "threshold": 25} ] }
```

模型不直接写 ISO 或 f 值：多模态大模型不擅长相机参数的数值推理，这些由本机程序计算。校验失败的方案会把带字段名和范围的错误文字反馈给模型，最多重试一次；之后保持题材默认意图，直到场景变化。

## 一次拍摄的过程

1. 开启 AI 后，本机先用「通用」默认意图开始测量，同时发出侦察请求。
2. 侦察回复题材后，立即换成该题材的默认意图，接管镜头和曝光；此时自动拍摄已经可用，同时请导演给出更具体的意图。
3. 导演意图到达后平滑替换。执行层每帧做以下几件事：
   - 移动裁切框；
   - 对焦；
   - 运行曝光程序；
   - 给当前时刻打分。
4. 时机分满足以下任一条件就自动连拍：
   - 达到 1，并持续 `holdMs`；
   - 进入取景 4 秒后，分数不低于 0.6，且不低于近 4 秒最高分的 95%。
5. 连拍完成后立即进入冷却，选片在后台进行。最好的一张存入系统相册，其余存为备选（7 天）。场景变化后自动重新侦察。
6. 用户随时可以按快门：AI 开启时同样连拍并选片，之后进入冷却。

## 曝光程序

1. 测光值先按 sRGB 曲线线性化，目标亮度为 `0.18 × 2^subjectEV`。
2. 每步只校正误差的 0.6 倍，并限制在 ±1 EV 以内；死区为 1/6 EV。上一次写入生效之前不再校正。
3. 光圈：可变光圈主摄上，浅景深和常规景深用最大光圈，大景深取最接近 f/4 的档；其他镜头的光圈固定。
4. 快门：
   - 手持安全快门为 `1/(2 × 等效焦距)`，限制在 1/500 到 1/30 之间；手机静止时放宽到 4 倍，最慢 1/8 秒。
   - `freeze`：`0.0015 / 主体速度`，限制在 1/2000 到 1/250 之间。
   - `blur`：手机稳定时为 1/15 秒。
5. ISO 上限默认 1600，夜景 6400。到顶后先放慢快门，仍不够就报告 `starved`。非主摄持续 starved 1 秒时，回退到主摄。
6. 高光保护：溢出超过上限时强制压暗，接近上限时不再提亮。

物理镜头逐个作为会话输入：在 iPhone 18 Pro Max 上，虚拟三摄报告不支持全手动曝光。AI 的曝光写入不会阻塞快门。

## AI 在界面上怎么表达自己

设计见 [2026-11-07-ai-presence-design.md](superpowers/specs/2026-11-07-ai-presence-design.md)。

- **极光边缘**（`AuroraEdge`）：AI 构图框的边缘有一圈青色极光。观察时慢速流转；认出主体后最亮的一段转向主体；时机越好流得越快，好时机时开始呼吸；拍下时收拢并闪白。
- **呼吸光晕**（`AttentionHalo`）：画面里的淡青光晕，表示 AI 的视线落在哪里。
- **字幕**（`CaptionDirector`）：一次一句人话，最多 16 字，2.5 秒后淡出，同一句话 8 秒内不重复。高优先级的事件可以打断低优先级，从高到低依次是：选片、拍下、换镜头、新意图、题材、弱光或离线、等待信号、观察、冷却。
- **看得见的动作**：认出主体时角框析出；换镜头时画面真实推拉；拍下时闪白；选片时 6 张缩略图弹出，选中的那张标出「AI 选择」。
- 支持减少动态效果：光不流转、不呼吸，状态变化用淡入淡出表示。

## 审美从哪里来

- **题材打法**（`CameraCore/Sources/CameraCore/Resources/Knowledge/genres/*.json`）：识别线索、五组原则、量表权重、题材特有项和默认意图（包括默认焦段、动作和景深）。
- **七项量表**（`rubric.json`）：导演按量表逐项点评，每项都必须给出证据，用来找出意图应该修正什么。点评只用于展示，不参与是否拍摄的判断。
- **测量优先**：能测量的项目交给本机判定，编译成时机信号；系统美学分只作参考输入。
- **评测**：见 [eval/README.md](../eval/README.md)，用公开数据集的人工评分衡量题材准确率、Spearman 相关与 AUC。

## DeepSeek 接口事实

- 能看图的模型只有 `deepseek-flash`。
- 思考模式下使用工具调用时，必须回传上一轮的 `reasoning_content`。
- 思考模式不支持 `tool_choice: required`，所以导演请求使用 `auto`。
- 使用严格工具（`/beta` 端点）时不能用 `null` 类型；0 表示「由程序决定」或「题材默认」。

## 安全与隐私

- 手动调参会停止 AI，点按对焦除外。
- 切到后台或相机被中断时暂停。
- 密钥或额度错误时停止并提示。
- 断网时用本机默认意图继续取景和拍摄。
- 密钥保存在 Keychain。
- 开启 AI 时，取景图和测量通过 HTTPS 发送给 DeepSeek；连拍分析与选片完全在本机进行。
- 拍摄依据（`CaptureRecords.json`）和连拍备选（`Bursts/`）只保存在本机。

## 调研依据

- [Pixel Camera Coach](https://blog.google/products/pixel/how-to-use-camera-coach/)：云端 Gemini 只给构图和光线建议。
- [Top Shot](https://androidauthority.com/google-pixel-3-top-shot-blog-936664)：保存快门前后的多帧，事后挑选。
- [Vidhance AI Composition](https://vidhance.com/products/ai-composition/)、[Arsenal](https://witharsenal.com/features)：本机专用模型做实时控制。
- [CameraBench](https://arxiv.org/pdf/2504.10090)：测试多模态大模型能否从图片推断相机参数的基准。
- [Learning-based Adaptive Camera Parameter Network](https://arxiv.org/pdf/2510.20550)：轻量网络实时预测 ISO、白平衡和增益。
- DeepSeek 官方文档：[Vision](https://api-docs.deepseek.com/guides/vision/)、[Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode)、[Tool Calls](https://api-docs.deepseek.com/guides/tool_calls)。
