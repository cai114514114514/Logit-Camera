# 离线审美评测

用公开美学数据集检验 AI 的审美判断：题材识别准不准、评审分与人工评分是否一致、能否区分好照片与差照片。每次修改题材打法、量表或提示词后都应运行一次，用数字判断改动是否变好。

评测会调用真实的 DeepSeek API（每张图 2 次调用：scout + judge），按你的账户计费；不在 CI 中运行。

## 数据集

| 数据集 | 内容 | 用途 | 官方页面 |
|---|---|---|---|
| SPAQ | 11,125 张手机照片；MOS、5 项属性分、EXIF、9 类场景 | 题材识别 + 质量/美学一致性 | https://github.com/h4nwei/SPAQ |
| TAD66K | 约 66,000 张，47 个主题，每张至少 1200 人评分 | 主题化审美一致性 | https://github.com/woshidandan/TANet-image-aesthetics-and-quality-assessment |

**两个数据集都没有声明图片的再分发许可，本仓库不包含任何数据集图片。** 请从官方页面下载到本地（`eval/images/` 已被 Git 忽略），仓库只保存抽样清单（文件名 + 标签）。

## 步骤

1. 下载 SPAQ 图片与标注，把 MOS 与场景类别整理成一个 CSV（Excel/Numbers 导出即可），表头包含三列：图片名（`Image`）、人工分（`MOS`）、类别（`Category`，取值如 `human`、`landscape`、`night scene`）。
2. 生成抽样清单（每个类别取人工分最高与最低各一半）：

   ```sh
   swift run --package-path CameraCore LogitEval sample --labels spaq.csv --out eval/manifest-spaq.json --per-category 20
   ```

3. 运行评测（密钥从环境变量 `DEEPSEEK_API_KEY` 或 `.env` 中的 `deepseek_api` 读取）：

   ```sh
   set -a; . ./.env; set +a
   swift run --package-path CameraCore LogitEval run --manifest eval/manifest-spaq.json --images eval/images/spaq --limit 40
   ```

输出：

- **题材准确率**：预测题材落在类别对应题材内的比例（对应关系来自各打法的 `spaqCategories`），以及混淆矩阵。
- **Spearman**：AI 加权分与人工分的等级相关，越接近 1 越一致。
- **AUC**：按人工分中位数分成好/差两组，AI 分能否把它们区分开（0.5 = 随机，1 = 完美）。
- 平均延迟与 token 用量。逐图结果写入 `eval/results/`（已被 Git 忽略）。

`eval/fixtures/manifest-sample.json` 是清单格式示例。

## 其他工具

- `LogitEval probe <image>`：对一张图依次调用 scout、judge、带记忆的 judge，检查真实 API 的工具调用与思考内容回传。
- `swift run -c release --package-path CameraCore LogitEval bench`：测量快档感知计算的耗时。

## 关于微调

DeepSeek 文档未提供微调接口，当前通过题材打法与量表「教」模型审美。若以后支持微调，可用数据集人工分（或模型标注）生成训练数据，并继续用本评测对比效果。
