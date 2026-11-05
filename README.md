# Logit Camera

<img src="LogitCamera/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="88" alt="Logit Camera icon">

**让 AI 看见取景画面，并直接调整相机。**

面向 iPhone 18 Pro Max 的原生相机实验项目，使用 SwiftUI、AVFoundation 和 DeepSeek 视觉 API。当前聚焦真实可变光圈控制、自动构图和可解释的拍摄流程。

> 当前为实验性 MVP。已有真实设备和真实 API 的成功记录，但最新真机回归尚未全部通过，后续测试和修复仍在进行中。

## 功能

- **硬件控制**：主摄光圈、ISO、快门、曝光补偿、变焦与点按对焦；界面显示硬件实际读数。
- **自动画幅**：AI 根据画面选择 3:4、9:16 或 1:1，预览与照片使用同一种中心裁切比例。
- **持续 Agent loop**：观察当前画面，决定调整或保持，执行后读取实际结果，再进行下一轮观察。
- **明确的 AI 窗口**：虹彩流光边框、运行阶段、调整原因、参数前后变化；支持系统“减少动态效果”。
- **条件式自动拍照**：两次模型确认、画面稳定和硬件就绪后开始可取消的 3 秒倒计时；每次只自动拍一张。
- **照片保留**：JPEG 拍摄、图库保存、原图分享和 EXIF 查看。图库写入失败时保留应用内原图。

AI 窗口展示真实运行状态，不使用虚构评分或进度。自动拍照的“就绪”表示满足当前检查条件，不代表照片审美已达到最优。

## Agent 如何工作

```text
新取景图 + 设备能力 + 实际读数
               ↓
       DeepSeek 视觉与工具调用
               ↓
         参数校验 / 过期检查
               ↓
       调整相机，或保持当前状态
               ↓
      硬件回读 + 新画面 → 再次观察
               ↓
 两次确认且稳定 → 3 秒倒计时 → 拍一张
```

- 每次只允许一个 API 请求，两轮之间至少间隔 5 秒。
- 不支持的参数、过期响应和明显变化的画面不会直接执行。
- 手动调参会关闭 AI；拍照和切后台会暂停循环。
- 自动拍照后解除快门准备，点击“再拍一张”才会重新确认。
- 暂时的网络错误采用退避重试；密钥或额度错误需要检查配置。

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

在相机右上角打开 **DeepSeek 设置**，输入 API 密钥即可使用 AI。

### 从本机 .env 导入开发密钥

```sh
cp .env.example .env
# 编辑 .env，填写 DEEPSEEK_API_KEY
python3 scripts/configure-ai.py --device 你的设备UDID
```

重新打开已安装的开发版 App 后，密钥会写入 iPhone Keychain，临时导入文件随即删除。脚本也识别已有的 `deepseek_api` 配置名。

`Signing.xcconfig`、`.env`、签名证书、描述文件和构建产物均被 Git 忽略。请勿提交真实密钥。

## 操作

- 顶部画幅菜单：手动选择比例。
- 顶部滑杆按钮：展开光圈和曝光补偿等手动控制。
- **DeepSeek** 按钮：开启或关闭持续 AI。
- AI 窗口中的 **自动拍摄**：选择由 AI 倒计时拍摄，或自己按快门。
- 倒计时中的 **取消拍摄**：中止本次自动快门。
- **再拍一张**：重新进行稳定性与模型确认。
- 缩略图：查看照片、EXIF、尺寸或分享。

图库写入失败时，可在“文件 → 我的 iPhone → Logit Camera → 待保存照片”中找回原图。

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

### 当前验证状态

截至 2026-11-05：

- 核心测试：**32 项通过**。
- 已完成 iOS arm64 开发签名构建与真机安装。
- 已有物理光圈切换、DeepSeek 多轮分析、一次完整自动拍照的成功记录。
- **最新完整真机回归未全部通过**：自动拍照、持续循环和画幅断言仍有失败或超时，保留待后续排查。
- 弱光画质、预览与成片边界、系统中断和取消竞态仍需持续真机验证。

已有记录不能替代稳定性验收，项目暂不宣称优于系统相机。

## 隐私与 API 费用

普通拍摄在本机完成。开启 AI 后，会通过 HTTPS 将压缩取景图和相机参数发送到 `api.deepseek.com`，按你的 DeepSeek 账户计费；关闭 AI 后停止发送新请求。

密钥保存在本机 Keychain，不写入源码、安装包或诊断日志。开发版仅保留有上限的参数诊断记录，不记录取景图或凭据。

本版采用个人密钥直连，适合个人开发验证。公开商业分发需要另行实现服务端鉴权、账户和额度管理。

## 项目结构

```text
LogitCamera/       原生界面、相机会话、DeepSeek 客户端、Agent 循环
CameraCore/        画幅几何、参数校验、拍摄就绪策略和核心测试
CameraUITests/     真机工作流测试
Config/           应用配置
scripts/          构建、密钥导入和自绘图标生成
docs/             Agent loop 设计与研究依据
```

代码按取景、曝光、AI、图片处理和保存拆分，硬件读写统一在专用串行队列执行。

## 许可证

[Apache License 2.0](LICENSE)。版权和第三方说明见 [NOTICE](NOTICE)。

Apple 平台能力与 DeepSeek 服务不包含在本项目许可证中；本项目不隶属于 Apple 或 DeepSeek。
