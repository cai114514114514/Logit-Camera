# Logit Camera

<img src="LogitCamera/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="88" alt="Logit Camera icon">

**让 AI 看见取景画面，并直接调整相机。**

面向 iPhone 18 Pro Max 的原生相机实验项目，使用 SwiftUI、AVFoundation 和 DeepSeek 视觉 API：
- 云端导演看懂画面，给出拍摄意图；
- 本机程序实时掌控镜头、光圈、快门、ISO、对焦与构图；
- 每次拍摄都连拍，再在本机选出最好的一张。

> 当前为实验性 MVP。最新一轮改动还没有完成全部真机回归，后续测试和修复仍在进行中。

## 功能

- **AI 掌控相机**：
  - 切换物理镜头（0.5× 超广角、1× 主摄、2×、4× 长焦）；
  - 按意图全手动设定光圈、快门和 ISO；
  - 对焦跟随主体；
  - 界面显示硬件的实际读数。
- **快门永远可用**：你随时可以按，拍到的就是 AI 已经调好的画面。AI 判断时机好时，也会自己拍一组。
- **连拍选片**：AI 开启时，每次拍摄连拍 6 张（约 0.4 秒），在本机按清晰度、睁眼、人脸质量和美学分挑出最好的一张存入相册，其余几张不保存。
- **一眼看得出的 AI**：
  - AI 构图框边缘有一圈流动的青色极光，表示 AI 正在工作；
  - 画面里一团淡青光晕跟着 AI 的视线，落到主体上；
  - 认出主体、换镜头、拍下、选片都有对应的动画；
  - 像字幕一样的一句人话说明 AI 在做什么（「换到 2×，背景虚一点」「等眼睛睁开」）。
- **滤镜**：
  - 9 个精心调过的预设（自然、通透、胶片暖、电影冷调、黑白、夜色、浓郁、柔光人像），取景里实时生效；
  - 滤镜条带实时缩略图，可以调强度，还有 11 项微调，并能存为自己的滤镜；
  - 拍完可以在照片详情里换滤镜，另存为新照片；
  - 预设是 `Resources/Knowledge/looks/*.json`，欢迎贡献。
- **AI 构图**：AI 选择 3:4、9:16 或 1:1，并在全画幅中放置裁切框（可以偏心，比如把主体放在三分线上）。裁切框跟随主体移动，成片与取景框一致。
- **有依据的审美**：导演按题材打法和七项量表点评画面，每一项都附证据，据此修正意图。
- **离线也能用**：断网时用题材默认意图在本机取景和拍摄。
- **照片保留**：JPEG 拍摄、图库保存、原图分享和 EXIF 查看。图库写入失败时，应用内保留原图。

审美水平用离线评测衡量，见 [eval/README.md](eval/README.md)。

## Agent 如何工作

```text
 取景帧 → 本机感知（Vision / 直方图 / 陀螺仪）→ 测量 ─────────────┐
                    │                                             ↓
   侦察（~1.5 s）→ 题材 → 题材默认意图 ──┐          LensPlanner → 物理镜头
   导演（~10 s）→ 意图 + 量表点评 ───────┴→ 意图 → ExposureProgram → 光圈 / 快门 / ISO
                                                    CompositionSolver → 裁切框
                                                    MomentScorer → 时机分 → 自动连拍
   拍摄（你或 AI）→ 连拍 6 张 → 本机选片 → 只存最好的一张 → 冷却，场景变化后继续
```

- 云端只给意图（焦段、构图、动作、景深、亮度、时机信号），不写具体参数，也没有放行权。
- 事件驱动：画面静止、意图仍有效时不发请求；同一时间只有一个请求在途，过期回复会被丢弃。
- 题材打法与量表随包分发（`CameraCore/Sources/CameraCore/Resources/Knowledge`），欢迎贡献。
- 手动调参会停止 AI，点按对焦不会；切后台与相机中断时暂停。

完整说明与研究来源：[Agent loop 设计](docs/agent-loop.md)。

## 运行要求

- Xcode 27 或更新版本。
- iOS 27 或更新版本。
- 推荐 iPhone 18 Pro / Pro Max；真实可变光圈取决于设备和当前拍摄格式。
- Apple 开发签名，以及自行申请的 DeepSeek API 密钥。

项目按镜头切换后置物理摄像头（超广角、主摄、长焦）。只有主摄支持可变光圈，其他镜头的光圈固定；模拟器无法验证物理光圈。

## 快速开始

```sh
git clone https://github.com/cai114514114514/Logit-Camera.git
cd Logit-Camera
cp Signing.example.xcconfig Signing.xcconfig
open LogitCamera.xcodeproj
```

1. 在 `Signing.xcconfig` 中填入自己的 `DEVELOPMENT_TEAM`，或在 Xcode 的 **Signing & Capabilities** 中选择开发团队。
2. 如默认 Bundle ID 不可用，将 `com.logitcamera.aperture` 改为自己的唯一标识。
3. 连接并解锁 iPhone，信任电脑、开启开发者模式，选择该设备并按 **⌘R**。
4. 首次运行允许相机访问，首次保存允许添加照片。开发签名可能需要在手机上手动信任。

在相机右上角打开 **设置**（齿轮），输入 API 密钥即可使用 AI。

### 从本机 .env 导入开发密钥

```sh
cp .env.example .env
# 编辑 .env，填写 DEEPSEEK_API_KEY
python3 scripts/configure-ai.py --device 你的设备UDID
```

重新打开已安装的开发版 App 后，密钥会写入 iPhone Keychain，临时导入文件随即删除。脚本也识别已有的 `deepseek_api` 配置名。

`Signing.xcconfig`、`.env`、签名证书、描述文件和构建产物均被 Git 忽略。请勿提交真实密钥。

## 操作

- 顶部画幅（`3:4 ▾`）：手动选择比例。
- 顶部读数或拨盘图标：在快门上方展开光圈档位与 EV 刻度尺，取景画面保持可见；「全部自动」恢复系统参数。
- 右下 **AI** 按钮：开启或关闭持续 AI。手动改光圈、曝光、画幅或变焦会停止 AI，提示条上可一键「恢复 AI」；点按对焦不会停止 AI。
- AI 开启后取景显示全画幅，青色裁切框是 AI 的构图，框外压暗。
- 快门上方的 AI 状态线：显示阶段、题材与拍摄条件（✓ 满足 / ○ 未满足）；点按打开详情，查看方案、条件、七项评分与证据、决策记录，并切换 **自动拍摄** 或 **再拍一张**。
- 就绪：快门外圈青色常亮并呼吸，条件满足即自动拍摄；此时点按快门 = 解除就绪（本场景不再自动拍）。
- 变焦：`0.5× 1× 2× 4×` 镜头档或双指缩放（跨档时切换物理镜头）。
- 缩略图：查看照片、EXIF、尺寸或分享。

图库保存失败时，可在“文件 → 我的 iPhone → Logit Camera → 待保存照片”中找回原图。

## 构建与测试

无签名 arm64 构建：

```sh
bash scripts/build.sh
```

开发签名构建：

```sh
DEVELOPMENT_TEAM=你的TeamID bash scripts/build.sh
```

核心测试可在 Mac 上运行：

```sh
swift test --package-path CameraCore
```

真机工作流测试需要已解锁的设备、相机权限和有效 API 配置：

```sh
xcodebuild -project LogitCamera.xcodeproj -scheme LogitCamera \
  -destination 'id=你的设备UDID' -allowProvisioningUpdates test
```

真机测试包含真实模型请求和自动拍摄，会使用 API 额度并可能生成照片。请对准稳定场景，留意权限提示和系统通知。

界面设计审阅可使用调试版演示模式，不发网络请求：启动参数 `-LogitDemo <idle|observing|adjusted|ready|countdown|manual|error>`，或运行 `-only-testing:CameraUITests/DesignScreenshotTests` 导出各状态截图。

### 当前验证状态

截至 2026-11-07：

- 核心测试：**146 项通过**（方案与条件判定、构图求解、量表与知识库、调度状态机、曝光控制、DeepSeek 适配器、评测指标）。
- 真实 API 探针：侦察约 1.5 s；导演（思考 + 原图 + 严格工具）约 9–13 s，点评逐项附证据；带思考内容回传的后续请求约 3.4 s（2026-11-06 数据）。
- 真机界面测试：演示场景截图、双指缩放接管、点按对焦、物理光圈切换均通过。
- 已完成 iOS arm64 开发签名构建与真机安装。
- **新 Agent 内核尚未在真机上用真实 API 完整跑通自动拍摄**（会消耗额度），待验证。
- 弱光画质、预览与成片边界、系统中断和取消竞态仍需持续真机验证。

已有记录不能替代稳定性验收，项目暂不宣称优于系统相机。

## 隐私与 API 费用

普通拍摄在本机完成。开启 AI 后，会通过 HTTPS 将压缩取景图和相机参数发送到 `api.deepseek.com`，按你的 DeepSeek 账户计费；关闭 AI 后停止发送新请求。

密钥保存在本机 Keychain，不写入源码、安装包或诊断日志。开发版仅保留有上限的参数诊断记录，不记录取景图或凭据。

本版采用个人密钥直连，适合个人开发验证。公开商业分发需要另行实现服务端鉴权、账户和额度管理。

## 项目结构

```text
LogitCamera/       原生界面、相机会话；Agent/ 下为感知、执行与 AgentController
CameraCore/        Agent 内核（方案、条件、构图、量表、调度、曝光控制、DeepSeek 适配器）、
                   题材知识库与提示词、核心测试，以及离线工具 LogitEval
eval/              离线审美评测说明与清单格式
CameraUITests/     真机工作流测试
Config/           应用配置
scripts/          构建、密钥导入和自绘图标生成
docs/             Agent loop 设计与研究依据
```

代码按取景、曝光、AI、图片处理和保存拆分，硬件读写统一在专用串行队列执行。

## 许可证

[Apache License 2.0](LICENSE)。版权和第三方说明见 [NOTICE](NOTICE)。

Apple 平台能力与 DeepSeek 服务不包含在本项目许可证中；本项目不隶属于 Apple 或 DeepSeek。
