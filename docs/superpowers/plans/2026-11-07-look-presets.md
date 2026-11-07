# 配方与预设（C2）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal：** 补齐调色工具，提供 9 个预设、滤镜条、微调与保存、拍后换滤镜。
**Spec：** `docs/superpowers/specs/2026-11-07-look-presets-design.md`
**约束：** 测试放到最后统一运行；不引入第三方依赖。

## Review Focus

1. 取景帧率：滤镜条缩略图与实时取景同时运行时不能掉帧，缩略图要低优先级。
2. 颗粒、暗角、光晕在取景（小图）和成片（4800 万像素）中观感一致。
3. 预设 JSON 写错时 App 不能崩溃：该预设跳过并记日志。
4. 删除「我的滤镜」时如果它正在使用，界面回退到「原片」。

### Task 1：新操作、辅助函数、预设与 LookAdjustments（CameraCore）

**Interfaces：**
- `LookOp` 新增 `.highlightsShadows(highlights:shadows:)`、`.hsl([HSLBand])`、`.colorGrade(ColorGrade)`、`.grain(amount:size:)`、`.vignette(amount:midpoint:)`、`.mono(red:green:blue:)`、`.bloom(Double)`
- `HSLBand { band: HueBand; hue, saturation, luminance: Double }`
- `ColorGrade { shadows, midtones, highlights: GradeWheel; balance: Double }`，其中 `GradeWheel { hue: Double; amount: Double }`
- `Knowledge.looks() throws -> [LookRecipe]`
- `LookAdjustments`（11 项）及 `apply(to:) -> LookRecipe`
- `ShaderSandbox.helpers`、`ShaderSandbox.paramCount = 32`

**测试：**
- `decodesNewOps`
- `rejectsOutOfRangeNewOps`
- `presetsLoadAndValidate`
- `presetNamesUnique`
- `adjustmentsAppendToCorrectLayers`
- `zeroAdjustmentsAreNoOp`
- `wrapIncludesHelpers`

### Task 2：渲染新操作（App）

- `LookRenderer` 实现新操作；把内置着色器的函数体放进 `BuiltinShaders`；`ShaderCompiler` 增加可信编译入口 `pipeline(trusted:)`。
- 曲线和褪色改到 sRGB 编码空间中计算。
- App 启动时预编译所有内置着色器。

### Task 3：滤镜条、调整面板、我的滤镜

- `LookLibrary`（我的滤镜，持久化）
- `LookThumbnailer`（基于最新帧的低频缩略图）
- `LookStrip`、`LookAdjustSheet`
- HUD 滤镜按钮
- CameraModel：`preset`、`adjustments`、`strength` → `look`

### Task 4：照片详情换滤镜

- CameraModel 保留最近一张照片的原片 `latestOriginal`。
- 详情页的滤镜条重新渲染预览；`saveAsNewPhoto(look:)` 把这个版本加进相册。

### Task 5：演示场景、文档、统一测试

- DesignScreenshotTests 增加 `looks` 场景：滤镜条打开并选中「胶片暖」。
- InteractionTests 新增：
  - `testPresetLookCaptures`
  - `testAdjustSheetOpens`
  - `testRelookInPhotoDetail`
- `swift test` 全部通过，真机用例全部通过并检查截图。
