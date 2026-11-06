# Logit Camera UI 改版设计：「精密仪器 · 安静副驾驶」

日期：2026-11-06
状态：待审阅

## 1. 目标与边界

**目标**：让 Logit Camera 看起来和用起来都像一台「AI 原生相机」，而不是系统相机外加一块 AI 浮层。取景优先；AI 存在但安静；用户随时能看懂 AI 做了什么、为什么。要有自己的视觉辨识度，并有一个让人记住的时刻。

**用户已确认**
- AI 形态：安静副驾驶（HUD 式状态 + 轻量标注，点开看详情）。
- 视觉调性：精密仪器（纯黑、细线、等宽读数、单一品牌色）。
- 本轮一起修复与 UI 相关的交互 bug。

**本轮不做**：AI 服务商抽象（OpenAI 兼容接口）、多语言 String Catalog、横屏、多镜头切换、Agent 决策逻辑与提示词的改动。

**成功标准**
1. 取景画面在任何状态下都不被 AI 信息遮挡超过一行文字的高度（详情面板除外，由用户主动打开）。
2. 只看颜色就能分辨参数是 AI 设定（青）还是用户/系统设定（白）。
3. 点按对焦、点 AI 标注不会意外关闭 AI。
4. 现有安全语义全部保留：单请求在途、过期丢弃、两次确认 + 稳定 + 倒计时、可取消、手动调参接管。
5. 真机构建通过，演示模式下各状态截图齐全，核心测试 32 项仍通过。

## 2. 视觉语言

### 2.1 颜色（`Theme.Color`）

| Token | 值 | 用途 |
|---|---|---|
| `background` | `#000000` | 全局背景 |
| `ink` | white 92% | 主要文字、读数 |
| `inkSecondary` | white 60% | 标签、次要信息 |
| `inkTertiary` | white 38% | 未激活、单位 |
| `hairline` | white 18% | 细线、刻度、分隔 |
| `accent`（Logit 青） | `#3DF5C8` | **仅** AI 相关：AI 设定的参数、AI 状态点、取景角标、扫描线、AI 按钮激活态 |
| `accentDim` | accent 35% | 呼吸低谷、光晕 |
| `warning` | `#FFB547` | 仅错误/警告（密钥失效、硬件超时） |

规则：用户手动设定的值为 `ink` 白色；AI 设定的值为 `accent`；系统自动值为 `inkSecondary`。不再使用黄色和彩虹渐变。

### 2.2 字体（`Theme.Font`）
- 读数：SF Mono，medium，13pt，`relativeTo: .footnote`，等宽数字。
- 标签/单位：SF Pro，semibold，10pt 大写字距 +0.6，`relativeTo: .caption2`。
- 倒计时数字：SF Pro Rounded，ultraLight，44pt。
- 全部字体使用 `relativeTo` 跟随动态字体，并限制最大到 `.accessibility1`，防止 HUD 撑破布局。

### 2.3 形状与动效
- 0.5–1pt 细线；取景框不画完整边框，只画四角 L 形刻线（长 18pt）。
- 圆角仅用于缩略图（6pt）和详情面板（系统 sheet）。不再使用毛玻璃卡片。
- 动效遵守「由真实状态驱动」：只在状态真的变化时动；系统「减少动态效果」开启时全部改为淡入淡出或静态。

## 3. 主界面布局（竖屏，自上而下）

```
┌───────────────────────────────┐
│ 3:4 ▾   ƒ1.8 ISO100 1/120 ±0.0  ⚙ │  ← HUD 读数条（44pt）
│ ┌                           ┐ │
│                                 │
│           [ 取 景 ]             │  ← 四角刻线；AI 开启时变青并呼吸
│                                 │
│     +0.3 EV · 主体逆光偏暗        │  ← AI 标注（出现 4 秒后淡出）
│ └                           ┘ │
│           [1×]   2×   3×        │  ← 变焦选择（仅显示可用倍率）
│ ● 观察中 · 第 3 轮 · 确认 ●○      │  ← AI 状态线（可点开详情）
│  [▣]        ( ◯ )        [ AI ] │  ← 缩略图 / 快门 / AI 开关
└───────────────────────────────┘
```

### 3.1 HUD 读数条 `HUDReadoutBar`
- 左：画幅菜单 `3:4 ▾`（保留 `camera.ratio`）。
- 中：读数按钮 `ƒ1.8  ISO 100  1/120  ±0.0`。每个值按「谁设定」着色（见 2.1）。值变化时用 `.contentTransition(.numericText())`。点按展开/收起手动拨盘（保留 `camera.controls`）。光圈读数保留 `camera.aperture` 静态文本标识，内容格式不变（`ƒ/1.48`）以兼容现有测试。
- 右：设置按钮 `⚙`（保留 `camera.aiSettings`），打开合并后的设置页。
- 原「相机能力与使用说明」按钮删除，内容并入设置页。

### 3.2 取景框 `ViewfinderFrame`
- 预览尺寸逻辑保留（宽度优先、保持比例）；去掉魔数 `132`，改为根据底部控制区实际高度（`onGeometryChange` 测量）计算居中区域。9:16 时允许延伸到控制区下方，但控制区背景改为底部渐隐，保证快门区域可读。
- 四角刻线：AI 关闭时 `hairline`；AI 开启时 `accent`，透明度在 `accentDim`↔`accent` 之间 3 秒一周期缓慢呼吸。
- **扫描线（惊艳时刻）**：每当 Agent 真正截取一帧发给模型时（`CameraAgent.observationTick` 自增），一条 1pt 青色横线带 24pt 渐隐尾迹，从取景框顶部扫到底部，耗时 0.9 秒。它和网络请求一一对应，不循环播放、不表示进度。减少动态效果时改为四角刻线闪亮一次。
- 点按对焦标记改为青色/白色细线方框（按 AI 是否开启），保留 0.7 秒后淡出。

### 3.3 AI 标注 `AIAnnotation`
- 位置：取景框内底部居中，单行，最多两行。
- 内容：只列**真正变化**的参数（等宽字体，青色），后接 `·` 与理由（`inkSecondary`）。例：`ƒ2.8 → ƒ4  ISO 400 → 200 · 主体逆光偏暗`。
- 出现条件：一次 adjust 成功回读后（`CameraAgent.adjustmentID` 变化）。4 秒后淡出；下一次调整会替换它。
- 不拦截取景点击（标注本身 `allowsHitTesting(false)`），但它不再位于可点击 UI 之上，因此不会把点击「穿透」成误操作。

### 3.4 AI 状态线 `AIStatusLine`
- 仅在 AI 开启或有错误时显示，单行高 28pt：
  - 状态点：观察/分析时青色呼吸，调整时青色实心，就绪时青色 + 外圈，暂停时 `inkTertiary`，错误时 `warning`。
  - 文本：阶段（观察中 / 分析中 / 调整中 / 复核中 / 准备拍摄 / 已暂停）· 第 N 轮 · 确认 `●○`（两枚小点表示 0/1/2 次确认）。
- 整行是一个按钮，点按打开 `AIDetailSheet`。保留 `camera.agent` 标识与「第 N 轮」的 accessibilityValue 以兼容测试。

### 3.5 AI 详情面板 `AIDetailSheet`（`.medium` / `.large` detent）
- 当前阶段与上一次理由（完整文本）。
- 最近一次参数变化表：前 → 后（只显示变化项）。
- 自动拍摄开关（保留 `camera.autoCapture`）与「再拍一张」（保留 `camera.rearm`）。
- 模型名称与「图像会发送至服务商」的简短提示。
- 面板打开时 Agent 照常运行。

### 3.6 变焦选择 `ZoomSelector`
- 主摄数字变焦，可选档位为 `[1, 2, 3]` 中落在 `minAvailableVideoZoomFactor...min(3, max)` 内的值；当前档位白色加粗显示，AI 设定时为青色并显示精确倍率（如 `1.4×`）。
- 取景区域支持双指缩放（`MagnifyGesture`），范围同上。
- 用户变焦 = 手动接管（见 4.2）。变焦使用 `ramp(toVideoZoomFactor:withRate:)` 平滑过渡；AI 的变焦同样改为 ramp。

### 3.7 底部操作栏
- 左：缩略图 44×44，圆角 6pt，细线描边（保留 `camera.photo`）。
- 中：快门 `ShutterButton`，外圈 2pt 白环 + 内圆。拍摄/保存中内圆缩小并显示进度。**倒计时**时外圈变为青色进度环（3 秒走完），环内显示剩余秒数；此时快门变成「取消」按钮（保留 `camera.cancelCapture`；倒计时元素保留 `camera.countdown`）。原全屏 100pt 倒计时浮层删除。
- 右：AI 按钮，48pt 圆形。关闭时细线圆环 + `inkSecondary` 字形；开启时青色细环 + 青色字形 + 轻微外发光（保留 `camera.ai`，accessibilityValue 保持「已开启/已关闭」）。文案从「DeepSeek」改为「AI」，上方是用 SwiftUI `Shape` 自绘的 Logit 字形：一个细线圆（镜头）内含偏心实心小圆（瞳孔），AI 开启时小圆随阶段缓慢移动到中心表示「对准」。

### 3.8 手动拨盘 `ManualDial`
- 点 HUD 读数后，从操作栏上方展开一条 56pt 高的拨盘区，取景画面始终可见；再点读数或点取景区收起。
- 顶部分段：`光圈` / `EV`。
- 光圈：显示硬件推荐档位的刻度按钮横排（`自动`、`ƒ1.48`…`ƒ4`），每个档位是独立按钮并保留 `aperture.auto`、`aperture.<值>` 标识；无推荐档位时退化为连续刻度滑杆。
- EV：-2…+2 的横向刻度尺（每 0.1 一个小刻度，每 1.0 一个大刻度），拖动吸附；松手才应用。
- 底部一个「全部自动」文字按钮（恢复自动参数）。
- 原 `CameraControlsSheet` 删除。

### 3.9 设置页 `SettingsView`
合并现有 `AISettingsView` 与 `CameraInfoView`，使用分组 `Form`，主题色为 accent：
1. AI：模型、API 端点、密钥状态、输入/移除密钥。
2. AI 如何工作：持续构图与自动拍摄说明。
3. 相机：镜头、光圈优先支持、硬件光圈范围。
4. 隐私与费用。
5. 照片找回位置。

### 3.10 状态浮层与提示
- 相机未就绪/拒绝/中断：保留现有逻辑，视觉改为居中细线图标 + 文本 + 细线描边按钮。
- `notice`：改为状态线位置上方的单行 toast（细线描边胶囊），4 秒后自动消失；错误类为 `warning` 色。接管提示带「恢复 AI」按钮（见 4.2）。

## 4. 交互与状态修正

### 4.1 Bug 修复（来自代码审查）
1. **AI 面板点击穿透导致 AI 关闭**：新的状态线和标注不再覆盖在取景之上接收穿透点击；状态线是独立按钮。
2. **点按对焦关闭 AI**：`CameraModel.focus` 不再调用 `agent.stop()`。`CaptureSession.focus` 只更新对焦/测光点；若当前为 AI 设定的全手动或部分手动曝光，保留这些参数，仅在自动/光圈优先模式下重新应用以使测光点生效。
3. **主线程解码整张照片**：拍摄后在后台用 ImageIO `CGImageSourceCreateThumbnailAtIndex` 生成 ≤ 600px 缩略图，以及 ≤ 2400px 的详情预览图；尺寸文本改为读取原图像素尺寸（不解码），保留 `photo.dimensions`。
4. **手动快门让自动拍摄失效**：仅自动拍摄触发时才设 `captureArmed = false`。
5. **硬件超时后每秒触发 4 次暂停**：`CameraModel.receive` 仅在阶段从 ready 变为非 ready 时调用一次 `agent.pause()`。
6. **AI 关闭时显示「观察」**：`setAutoCapture` 只在 `isEnabled` 时修改 `stage`。
7. **裁切后 TIFF 方向未同步**：`PhotoFraming.crop` 同时把 `{TIFF}.Orientation` 设为 1。

### 4.2 手动接管
- 用户改光圈、EV、画幅、变焦、点「全部自动」时：AI 停止（语义不变），并显示 toast：「你接管了<参数> · AI 已停止」+「恢复 AI」按钮（调用 `toggleAI`）。
- 点按对焦、打开详情面板、打开设置不属于接管。

## 5. 代码结构

新增目录 `LogitCamera/Design/`（项目使用文件夹同步分组，新文件自动加入目标）：

| 文件 | 职责 |
|---|---|
| `Theme.swift` | 颜色、字体、尺寸、动效常量；「谁设定」→ 颜色映射 |
| `HUDReadoutBar.swift` | 顶部读数条 + 画幅菜单 |
| `ViewfinderFrame.swift` | 四角刻线、呼吸、扫描线 |
| `AIAnnotation.swift` | 调整标注 |
| `AIStatusLine.swift` | 状态线 |
| `AIDetailSheet.swift` | 详情面板 |
| `ShutterButton.swift` | 快门 + 倒计时环 |
| `AIButton.swift` | AI 开关 + 字形 |
| `ZoomSelector.swift` | 变焦档位 |
| `ManualDial.swift` | 光圈/EV 拨盘 |
| `Toast.swift` | 单行提示 |

修改：
- `CameraView.swift`：只负责布局与组装；测量控制区高度。
- `CameraAgent.swift`：新增 `observationTick`、`adjustmentID`；`changes` 只保留变化项；修复 4.1-6；`modelName` 等不变。
- `CameraModel.swift`：对焦不停 AI、接管 toast、缩略图后台生成、`setZoom`、修复 4.1-4/5。
- `CaptureSession+Exposure.swift`：`setZoom`（ramp）、对焦保留手动曝光。
- `CaptureSession+Agent.swift`：AI 变焦改用 ramp。
- `CameraState.swift`：新增 `minZoom`/`maxZoom`；`CameraText` 增加 EV 格式化。
- `PhotoFraming.swift`：TIFF 方向。
- `PhotoDetailView.swift`：套用新主题，使用预览图。
- 删除：`CameraAgentPanel.swift`、`CameraChrome.swift`、`ApertureControls.swift`（内容迁入新组件）、`AISettingsView.swift` 与 `CameraInfoView`（并入 `SettingsView.swift`）。

## 6. 演示模式（仅 DEBUG）

为在不消耗 API 额度的情况下验证每个 UI 状态：
- 启动参数 `-LogitDemo <scenario>`，场景：`idle`、`observing`、`adjusted`、`ready`、`countdown`、`manual`、`error`。
- `DemoScenario.swift`（`#if DEBUG`）在相机就绪后直接设置 `CameraAgent` 的展示字段（不发网络请求、不改硬件），`observing` 场景每 5 秒自增一次 `observationTick` 以展示扫描线。
- 新增 UI 测试 `DesignScreenshotTests`：逐个场景启动 App 并附加截图，用于设计审阅；不做断言以外的硬件操作。

## 7. 测试与验证

1. `swift test --package-path CameraCore`：32 项仍通过。
2. `bash scripts/build.sh`：无签名 arm64 构建通过，无新增警告（Swift 6 严格并发）。
3. 真机安装（iPhone 18 Pro Max）后运行 `DesignScreenshotTests`，从 `.xcresult` 导出各场景截图审阅。
4. 更新现有 UI 测试的定位方式：自动拍摄开关迁入详情面板（先点 `camera.agent` 打开）；光圈档位迁入拨盘（先点 `camera.controls`，标识不变）。
5. 真实 API 跑一次 `CompositionTests`，观察多轮循环、标注、扫描线与自动拍摄。真机测试会使用 API 额度并可能产生照片，运行前告知用户。

## 8. 风险

- 青色强调在明亮户外的可读性：读数条与状态线下加 40% 黑色渐隐底衬；真机户外复查。
- 扫描线与呼吸动画的耗电：仅 AI 开启时运行，`TimelineView` 限 30fps，扫描线为一次性动画。
- 移除 sheet 式手动控制后，现有 `ApertureTests` 需要适配；标识符保持不变以减少改动。
