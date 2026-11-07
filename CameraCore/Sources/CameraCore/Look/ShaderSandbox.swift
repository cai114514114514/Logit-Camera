import Foundation

/// 自定义着色器沙箱（规格 §2）：AI 只写 `logit_shade` 的函数体，逐像素、无循环、不能访问纹理或设备内存。
public enum ShaderSandbox {
    public static let maxLength = 2000
    public static let maxParams = 8
    /// `LookParams.v` 的长度：自定义着色器只用前 8 个，内置着色器可以用全部 32 个。
    public static let paramCount = 32

    /// 模板中提供的辅助函数（自定义与内置着色器都可以调用）。
    public static let helpers = """
    static float logit_luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

    static float logit_hash(float2 p) {
        float3 q = fract(float3(p.xyx) * 0.1031);
        q += dot(q, q.yzx + 33.33);
        return fract((q.x + q.y) * q.z);
    }

    /// 色相（0…1）→ 饱和的 RGB。
    static float3 logit_hue_rgb(float h) {
        float3 k = clamp(abs(fract(h + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
        return k;
    }

    /// 色相段权重：与段中心（度）的环形距离在 width 内线性衰减。
    static float logit_band(float hueDegrees, float center, float width) {
        float d = abs(fmod(hueDegrees - center + 540.0, 360.0) - 180.0);
        return max(0.0, 1.0 - d / width);
    }

    /// 平滑值噪声（双线性插值的哈希），用于颗粒。
    static float logit_noise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        float a = logit_hash(i), b = logit_hash(i + float2(1.0, 0.0));
        float c = logit_hash(i + float2(0.0, 1.0)), d = logit_hash(i + float2(1.0, 1.0));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    /// RGB → HSL（各 0…1）。
    static float3 logit_rgb2hsl(float3 c) {
        float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
        float l = (mx + mn) * 0.5;
        float d = mx - mn;
        if (d < 1e-5) { return float3(0.0, 0.0, l); }
        float s = l > 0.5 ? d / (2.0 - mx - mn) : d / (mx + mn);
        float h;
        if (mx == c.r) { h = (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0); }
        else if (mx == c.g) { h = (c.b - c.r) / d + 2.0; }
        else { h = (c.r - c.g) / d + 4.0; }
        return float3(h / 6.0, s, l);
    }

    /// HSL → RGB。
    static float3 logit_hsl2rgb(float3 hsl) {
        float3 rgb = logit_hue_rgb(hsl.x);
        float c = (1.0 - abs(2.0 * hsl.z - 1.0)) * hsl.y;
        return (rgb - 0.5) * c + hsl.z;
    }
    """
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
            float v[32];
            float time;
        };

        \(helpers)

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
