# 渲染底座（C1）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal：** 用 Metal 实时取景并套用配方；配方编译成 Core Image 滤镜图；支持沙箱化的自定义着色器；成片按配方渲染成 HEIC。
**Spec：** `docs/superpowers/specs/2026-11-07-look-engine-design.md`
**约束：** 开发过程中不运行测试，测试放到 Task 5 统一运行；Swift 6；不引入第三方依赖。

## Review Focus

1. 预览帧率：配方很重时也不能卡住相机队列，宁可丢帧。
2. 等比铺满时，点按对焦的坐标映射必须正确，四边都要对。
3. 自定义着色器编译失败、或输出 NaN 时，照片照常保存。
4. 配方切换和拍照同时发生时，成片用的必须是按下快门那一刻的配方。

### Task 1：LookRecipe 与 ShaderSandbox（CameraCore）

**Interfaces：**
- `LookRecipe`、`LookOp`、`CurvePoint`、`CustomShader`
- `LookRecipe.validate() throws(LookValidationError)`、`LookRecipe.identity`、`var isIdentity: Bool`
- `ToneCurveMath.sample(_ points: [CurvePoint], at x: Double) -> Double`（单调三次插值）
- `ShaderSandbox.validate(_ body: String) throws(LookValidationError)`、`ShaderSandbox.wrap(_ body: String) -> String`

**测试：**
- `decodesRecipeJSON`
- `rejectsOutOfRangeOps`
- `curveIsMonotoneAndHitsEndpoints`
- `sandboxRejectsForbiddenTokens`
- `sandboxRejectsLongBody`
- `wrapContainsBodyAndFallback`
- `identityRecipe`

### Task 2：LookRenderer、ShaderCompiler、CustomShaderKernel（App）

**Interfaces：**
- `LookRenderer.graph(for recipe: LookRecipe) -> (CIImage) -> CIImage`
- `LookRenderer.renderPhoto(_ data: Data, recipe: LookRecipe) throws -> Data`（输出 HEIC 10-bit）
- `ShaderCompiler.shared.pipeline(for body: String) -> MTLComputePipelineState?`：没有现成结果时在后台开始编译，并先返回 nil。

### Task 3：LivePreview 与 FrameGrabber 回调

- `FrameGrabber.onFrame`
- `LivePreview`（UIViewRepresentable）及其 `LiveRenderer`
- 在 CameraView 中替换掉原来的 `CameraPreview`

### Task 4：成片管线与调试配方

- `CameraModel.look`；拍照时冻结当前配方，成片按它渲染
- `CapturedPhoto(id:)`
- `BurstManifest.look`
- 分享时按数据类型选择格式
- DEBUG 启动参数 `-LogitLook`

### Task 5：统一测试

- `swift test`
- 真机运行截图、交互、画幅尺寸用例，以及新增的自定义着色器拍摄用例
