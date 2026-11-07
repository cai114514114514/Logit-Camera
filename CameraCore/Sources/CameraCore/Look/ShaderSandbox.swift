import Foundation

/// 自定义着色器沙箱（规格 §2）：AI 只写 `logit_shade` 的函数体，逐像素、无循环、不能访问纹理或设备内存。
public enum ShaderSandbox {
    public static let maxLength = 2000
    public static let maxParams = 8
    /// 符号类禁用标记（子串匹配）。
    static let forbiddenSymbols = ["#", "[[", "__"]
    /// 关键字类禁用标记（整词匹配）。
    static let forbiddenWords = ["texture", "texture2d", "device", "threadgroup", "atomic", "kernel", "for", "while",
                                 "goto", "asm", "sampler", "do", "volatile", "thread"]

    public static func validate(_ body: String) throws(LookValidationError) {
        guard body.count <= maxLength else { throw .shader("长度超过 \(maxLength) 字符") }
        for symbol in forbiddenSymbols where body.contains(symbol) { throw .shader("不允许使用「\(symbol)」") }
        let words = Set(body.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init))
        for word in forbiddenWords where words.contains(word) { throw .shader("不允许使用「\(word)」") }
        guard words.contains("return") else { throw .shader("必须返回 float4") }
    }

    /// 完整的 Metal 源码：参数结构、`logit_shade`（AI 的函数体）与逐像素 kernel。
    public static func wrap(_ body: String) -> String {
        """
        #include <metal_stdlib>
        using namespace metal;

        struct LookParams {
            float v[8];
            float time;
        };

        static float4 logit_shade(float4 color, float2 uv, constant LookParams& p) {
        \(body)
        }

        kernel void logit_custom(texture2d<float, access::read> source [[texture(0)]],
                                 texture2d<float, access::write> destination [[texture(1)]],
                                 constant LookParams& params [[buffer(0)]],
                                 constant float4& extent [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) { return; }
            float4 color = source.read(gid);
            // extent = (原点 x, 原点 y, 全图宽, 全图高)：uv 相对整张图，左上原点。
            float2 uv = (float2(gid) + extent.xy + 0.5) / max(extent.zw, float2(1.0));
            float4 result = logit_shade(color, uv, params);
            bool finite = all(isfinite(result));
            destination.write(finite ? clamp(result, 0.0, 1.0) : color, gid);
        }
        """
    }
}
