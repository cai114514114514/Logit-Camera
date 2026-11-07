# AI 修正（C3）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal：** 本机每帧自动算出修正层（白平衡、高光、阴影、主体补光、天空恢复、肤色、自然饱和度），放在用户滤镜之前。
**Spec：** `docs/superpowers/specs/2026-11-07-ai-correction-design.md`
**约束：** 测试放到最后统一运行。

## Review Focus

1. 修正参数不能闪烁：主体检测时有时无时，补光要淡入淡出。
2. 成片里的局部修正位置必须和取景看到的一致（裁切换算）。
3. 日落、夜景这类有氛围的场景不能被「纠正」成中性色。
4. 关闭修正开关后，取景和成片都立即恢复为没有修正的状态。

### Task 1（CameraCore）
- `ChromaStats` 加入 `SceneMeasurement`（可选，向后兼容），并实现 `MeasurementMath.chroma(cbcr:width:height:luma:)`。
- 新增 `LookOp.subjectLight`、`LookOp.skyRecover`。
- 新增 `CorrectionInput`、`CorrectionParams`、`CorrectionPlanner.plan`、`CorrectionSmoother`、`CorrectionParams.ops(for:)`、`note`。
- `CaptionSnapshot.correctionNote`。
- 测试：
  - `backlitSubjectGetsLight`
  - `clippedHighlightsRecover`
  - `nightKeepsColorCast`
  - `sunsetLandscapeKeepsWarmth`
  - `skyRecoveredWhenBrightBlueTop`
  - `facesProtectSkin`
  - `smootherConverges`
  - `opsMapIntoCrop`
  - `subjectOutsideCropSkipped`
  - `chromaStatsMeasureCast`
  - `newCorrectionOpsValidate`
  - `correctionNoteCaption`

### Task 2（App）
- Perception 采样 CbCr。
- `BuiltinShaders.subjectLight`、`BuiltinShaders.skyRecover`，以及对应的渲染。
- LiveRenderer 增加修正层的预处理。
- AgentController 产出 `correction`，并提供 `smartCorrection` 开关。
- CameraModel 在拍摄时冻结修正参数，并用裁切框换算坐标。
- 详情面板加入开关；字幕接入修正说明。

### Task 3：统一测试
- 运行 `swift test` 和真机全部用例；离线导演下的修正截图需要人工检查。
