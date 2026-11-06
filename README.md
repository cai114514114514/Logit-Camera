# Logit Camera

<img src="LogitCamera/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="88" alt="Logit Camera icon">

**让 AI 看见取景画面，并直接调整相机。**

面向 iPhone 18 Pro Max 的原生相机实验项目，使用 SwiftUI、AVFoundation 和 DeepSeek 视觉 API。当前聚焦有依据的 AI 审美判断：题材知识库与七项评分量表、本地实时感知、偏心裁切构图与「就绪即拍」。

> 当前为实验性 MVP。已有真实设备和真实 API 的成功记录，但最新真机回归尚未全部通过，后续测试和修复仍在进行中。

## 功能

- **硬件控制**：主摄光圈、ISO、快门、曝光补偿、变焦与点按对焦；界面显示硬件实际读数。
- **AI 构图**：AI 选择 3:4、9:16 或 1:1，并在全画幅中放置裁切框（可偏心，主体可放在三分线上）；裁切框跟随主体移动，成片与取景框一致。
- **导演 + 本地摄影助理**：模型（DeepSeek）按题材打法与七项量表写出拍摄方案并给出有证据的评分；手机本地实时测量主体、睁眼、朝向、地平线、清晰度、高光与手抖，负责对焦、曝光、构图与拍摄时机。
- **安静的 AI 副驾驶**：AI 每截取一帧，取景框扫过一道青色细线；调整后浮出变化参数与理由；读数颜色区分 AI（青）、你（白）和系统自动（灰）；支持系统“减少动态效果”。
- **就绪即拍**：评审放行后，拍摄条件全部满足的瞬间自动拍摄；每个场景拍一张，场景变化后继续。
- **照片保留**：JPEG 拍摄、图库保存、原图分享和 EXIF 查看。图库写入失败时保留应用内原图。

界面只展示真实运行状态。评分来自模型按量表的判断并附证据，放行规则由客户端强制执行；它不代表照片审美已达到最优，审美水平用离线评测衡量（见 [eval/README.md](eval/README.md)）。

## Agent 如何工作

```text
 取景帧 → 本地感知（Vision / 直方图 / 陀螺仪）→ 测量
                     │                    ↑
        场景变化 / 接近就绪              执行层：对焦 · 曝光 · 裁切框 · 拍摄条件
                     ↓                    │
   侦察（deepseek-flash，低清，~1.5 s）→ 题材
                     ↓                    │
   评审（deepseek-flash，思考 + 原图，~10 s）→ 拍摄方案 + 七项评分 → 放行？
                     ↓ 放行
   条件全部满足的瞬间 → 拍一张 → 冷却，场景变化后继续
```

- 模型只给方案与评分，没有硬件与快门权限；**没有评审放行永不自动拍摄**，放行 10 秒或画面漂移后失效。
- 事件驱动：画面静止、方案仍有效时不发请求；同一时间只有一个请求在途，过期回复丢弃。
- 题材打法与量表随包分发（`CameraCore/Sources/CameraCore/Resources/Knowledge`），欢迎贡献。
- 手动调参会关闭 AI，点按对焦不会；切后台与相机中断时暂停。
- 暂时的网络错误退避重试；密钥或额度错误停止并提示。

完整说明及官方研究来源：[Agent loop 设计](docs/agent-loop.md)。

## 运行要求

- Xcode 27 或更新版本。
- iOS 27 或更新版本。
- 推荐 iPhone 18 Pro / Pro Max；真实可变光圈取决于设备和当前拍摄格式。
- Apple 开发签名，以及自行申请的 DeepSeek API 密钥。

项目固定使用后置物理主摄。固定光圈设备会禁用可变光圈控件；模拟器不能验证物理光圈。

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
- 变焦：`1× 2× 3×` 档位或双指缩放（主摄数字变焦）。
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
- 真实 API 探针：侦察约 1.5 s；评审（思考 + 原图 + 严格工具）约 9–13 s，评分逐项附证据；带思考内容回传的复核约 3.4 s。
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
