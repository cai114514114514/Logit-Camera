# 子项目 C1：渲染底座 —— 设计规格

日期：2026-11-07　分支：`look-engine`（基于 main 9fe677a）

## 背景

C 的目标是「真正让图像变好看」，用户的选择如下：
- 先修正、再风格；
- AI 写滤镜配方，并可以加一段受限的自定义着色器；
- 取景器里实时生效；
- 默认自动，也能用一句话调整。

C 分成四个子项目：C1 渲染底座 → C2 配方与预设 → C3 AI 修正 → C4 AI 动态滤镜。本文只覆盖 C1。

C1 要交付：
1. 取景器用 Metal 实时渲染滤镜，所见即所得。
2. 配方（`LookRecipe`）能编译成 Core Image 滤镜图，取景和成片共用这一套编译逻辑。
3. 支持自定义着色器节点：在沙箱里运行时编译，失败时自动跳过。
4. 成片按配方渲染，输出 10-bit HEIC 存进相册；未调色的原片和配方保存在本机。

## 1. 配方 `LookRecipe`（CameraCore）

```json
{ "version": 1, "name": "暖调", "strength": 1,
  "correction": [ {"op": "whiteBalance", "temperature": 0.2, "tint": 0} ],
  "style": [ {"op": "toneCurve", "points": [[0,0.03],[0.5,0.52],[1,0.97]]}, {"op": "saturation", "amount": -0.1},
             {"op": "custom", "name": "暗角", "body": "…", "params": [0.4]} ] }
```

配方由两层组成：`correction`（修正层）先执行，`style`（风格层）后执行。`strength` 表示与原图的混合比例，范围 0…1。

| op | 参数与范围 | Core Image 实现 |
|---|---|---|
| exposure | ev −2…2 | CIExposureAdjust |
| whiteBalance | temperature、tint 各 −1…1 | CITemperatureAndTint：中性点 = (6500 + 3000·temperature, 50·tint)，目标中性点 = (6500, 0)。方向已在 Mac 上验证：temperature 为正变暖，tint 为正偏品红 |
| contrast | amount −1…1 | CIColorControls：contrast = 1 + 0.5·amount |
| saturation | amount −1…1 | CIColorControls：saturation = 1 + amount |
| vibrance | amount −1…1 | CIVibrance |
| toneCurve | points 2–8 个，x、y ∈ 0…1，x 严格递增 | 单调三次插值后在 0、0.25、0.5、0.75、1 五处取值，交给 CIToneCurve |
| fade | amount 0…1 | 抬黑：y = 0.15·amount + y·(1 − 0.15·amount)，用 CIColorMatrix 实现 |
| custom | name、body、params（最多 8 个，各 −10…10） | 见 §2 |

校验 `validate()`：
- 所有参数都检查范围；
- 每层最多 16 个操作；
- custom 的 body 必须先通过沙箱检查。

## 2. 自定义着色器沙箱

AI 只写逐像素函数的函数体：

```
float4 logit_shade(float4 color, float2 uv, constant LookParams& p)
```

- `color` 是 sRGB 编码值，范围 0…1；
- `uv` 是左上原点的 0…1 坐标；
- `p.v[0…7]` 是参数，`p.time` 是秒数；
- 必须返回 float4。

`ShaderSandbox`（CameraCore，纯函数）：
- **`validate(body)`**：
  - 长度不超过 2000 字符；
  - 禁用以下标记：`#`、`texture`、`device`、`threadgroup`、`atomic`、`kernel`、`[[`、`for`、`while`、`goto`、`__`、`asm`、`sampler`；
  - 必须包含 `return`。
  - 禁止循环，保证计算时间有上限。
- **`wrap(body)`**：生成完整的 Metal 源码。kernel 逐像素读写；结果不是有限数时回退到输入值；输出夹到 0…1。

App 侧：
- `ShaderCompiler` 在后台用 `MTLDevice.makeLibrary(source:)` 编译，按源码缓存 pipeline。
- 编译期间以及编译失败时，这个节点按恒等处理，界面上不报错，只记日志。
- 执行由 `CIImageProcessorKernel` 负责。节点前后各做一次线性 ↔ sRGB 转换，让 AI 写的代码面对的是显示编码的值。

## 3. 实时取景 `LivePreview`

- 用 `CAMetalLayer` 视图替代 `AVCaptureVideoPreviewLayer`。
- `FrameGrabber` 每收到一帧就通过回调交给 `LiveRenderer`：在帧队列上把 `CIImage(cvPixelBuffer:)` 先缩放到可绘制尺寸（等比铺满），再套用当前配方的滤镜图，然后渲染并上屏。
- 最多 2 帧在途，上一帧没画完就丢弃新帧。
- 配方切换是线程安全的。
- 点按对焦：视图坐标先换算成直立全画幅的归一化坐标（考虑等比铺满造成的裁边），再经 `CaptureSession.devicePoint` 转成设备兴趣点。对焦标记和无障碍标识 `camera.preview` 保持不变。
- 帧本来就是直立的（连接已旋转 90°），坐标系与感知层、裁切框一致。

## 4. 成片

- 选片（或单张拍摄）完成后：如果配方不是恒等，就用 `LookRenderer.renderPhoto` 把裁切好的原片按配方渲染成 10-bit HEIC，保留 EXIF，作为存进相册的照片。原片保留在 BurstStore 中，清单增加 `look` 字段。
- `CapturedPhoto` 允许传入 id，让成片和原片共用同一个 id。
- 分享时按数据类型自动选择 `.heic` 或 `.jpg`。

## 5. C1 的范围之外

- 预设库、手动微调界面、保存滤镜：C2。
- 局部蒙版：C3。
- AI 写配方：C4。

C1 只内置两个调试配方，通过 DEBUG 启动参数 `-LogitLook warm|vignette` 启用，用来验证实时取景、自定义着色器和成片管线。

## 6. 测试

- **CameraCore**：配方的解码、校验和范围；曲线插值的单调性与端点；沙箱的禁用标记和长度限制；模板中包含函数体和回退逻辑。
- **真机**：
  - `DesignScreenshotTests` 用 `-LogitLook warm` 截图，确认取景已经调色；
  - 已有的点按对焦、AI 开拍、画幅尺寸用例继续通过；
  - 新增测试：在 `-LogitLook vignette` 下拍一张，确认能正常出片（自定义着色器编译成功或被安全跳过）。
