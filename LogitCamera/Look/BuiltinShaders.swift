import CameraCore
import Foundation

/// 内置调色操作的着色器函数体（可信代码，不经沙箱校验）。输入输出都是 sRGB 编码值。
enum BuiltinShaders {
    /// 八色 HSL：参数按 HueBand.allCases 顺序，每段 3 个（色相、饱和、明度）。
    static let hsl = """
    float3 hsl = logit_rgb2hsl(color.rgb);
    float hue = hsl.x * 360.0;
    float w0 = logit_band(hue, 0.0, 40.0), w1 = logit_band(hue, 30.0, 40.0), w2 = logit_band(hue, 60.0, 40.0);
    float w3 = logit_band(hue, 120.0, 60.0), w4 = logit_band(hue, 180.0, 60.0), w5 = logit_band(hue, 240.0, 50.0);
    float w6 = logit_band(hue, 270.0, 40.0), w7 = logit_band(hue, 300.0, 50.0);
    float total = max(1.0, w0 + w1 + w2 + w3 + w4 + w5 + w6 + w7);
    float dh = (w0 * p.v[0] + w1 * p.v[3] + w2 * p.v[6] + w3 * p.v[9] + w4 * p.v[12] + w5 * p.v[15] + w6 * p.v[18] + w7 * p.v[21]) / total;
    float ds = (w0 * p.v[1] + w1 * p.v[4] + w2 * p.v[7] + w3 * p.v[10] + w4 * p.v[13] + w5 * p.v[16] + w6 * p.v[19] + w7 * p.v[22]) / total;
    float dl = (w0 * p.v[2] + w1 * p.v[5] + w2 * p.v[8] + w3 * p.v[11] + w4 * p.v[14] + w5 * p.v[17] + w6 * p.v[20] + w7 * p.v[23]) / total;
    float protect = smoothstep(0.03, 0.25, hsl.y);
    hsl.x = fract(hsl.x + dh * protect * (30.0 / 360.0));
    hsl.y = clamp(hsl.y * (1.0 + ds * protect), 0.0, 1.0);
    hsl.z = clamp(hsl.z + dl * protect * 0.2 * (1.0 - abs(2.0 * hsl.z - 1.0) * 0.5), 0.0, 1.0);
    return float4(logit_hsl2rgb(hsl), color.a);
    """

    /// 三向色轮：v0 阴影色相 /360、v1 阴影强度、v2/v3 中间调、v4/v5 高光、v6 平衡。
    static let colorGrade = """
    float3 c = color.rgb;
    float l = logit_luma(c);
    float pivot = 0.5 + p.v[6] * 0.25;
    float ws = 1.0 - smoothstep(0.0, pivot, l);
    float wh = smoothstep(pivot, 1.0, l);
    float wm = clamp(1.0 - ws - wh, 0.0, 1.0);
    float3 ts = logit_hue_rgb(p.v[0]); ts -= logit_luma(ts);
    float3 tm = logit_hue_rgb(p.v[2]); tm -= logit_luma(tm);
    float3 th = logit_hue_rgb(p.v[4]); th -= logit_luma(th);
    c += 0.5 * (ts * p.v[1] * ws + tm * p.v[3] * wm + th * p.v[5] * wh);
    return float4(clamp(c, 0.0, 1.0), color.a);
    """

    /// 颗粒：v0 强度、v1 尺寸、v2 宽高比、v3 是否随时间变化（取景 1、成片 0）。颗粒以画面高度为参照。
    static let grain = """
    float cells = mix(1400.0, 500.0, p.v[1]);
    float2 g = uv * float2(cells * p.v[2], cells) + floor(p.time * 24.0) * p.v[3] * float2(17.0, 31.0);
    float n = logit_noise(g) - 0.5;
    float l = logit_luma(color.rgb);
    float weight = 0.35 + 2.6 * l * (1.0 - l);
    float3 c = color.rgb + n * p.v[0] * 0.18 * weight;
    return float4(clamp(c, 0.0, 1.0), color.a);
    """

    /// 暗角：v0 强度（负值压暗、正值提亮）、v1 中点、v2 宽高比。
    static let vignette = """
    float2 d = (uv - 0.5) * float2(p.v[2], 1.0);
    float r = length(d) / length(float2(p.v[2], 1.0) * 0.5);
    float f = smoothstep(p.v[1] * 0.8, 1.05, r);
    float3 c = p.v[0] < 0.0 ? color.rgb * (1.0 + p.v[0] * f) : mix(color.rgb, float3(1.0), p.v[0] * f);
    return float4(c, color.a);
    """

    /// 黑白：v0–v2 为红、绿、蓝权重。
    static let mono = """
    float s = max(p.v[0] + p.v[1] + p.v[2], 0.001);
    float g = dot(color.rgb, float3(p.v[0], p.v[1], p.v[2])) / s;
    return float4(g, g, g, color.a);
    """

    /// 主体补光：v0 x、v1 y（左上原点）、v2 半径（相对短边）、v3 EV、v4 宽高比。
    static let subjectLight = """
    float2 d = (uv - float2(p.v[0], p.v[1])) * float2(p.v[4], 1.0) / min(p.v[4], 1.0);
    float r = length(d);
    float mask = 1.0 - smoothstep(p.v[2] * 0.6, p.v[2] * 1.4, r);
    float3 linear = pow(max(color.rgb, 0.0), float3(2.2));
    linear *= exp2(p.v[3] * mask);
    return float4(clamp(pow(linear, float3(1.0 / 2.2)), 0.0, 1.0), color.a);
    """

    /// 天空恢复：v0 强度、v1 天空下沿（左上原点）。
    static let skyRecover = """
    float l = logit_luma(color.rgb);
    float blue = clamp((color.b - color.r) * 3.0 + 0.4, 0.0, 1.0);
    float above = 1.0 - smoothstep(p.v[1] - 0.12, p.v[1] + 0.08, uv.y);
    float sky = smoothstep(0.35, 0.8, l) * blue * above;
    float3 linear = pow(max(color.rgb, 0.0), float3(2.2)) * exp2(-0.8 * p.v[0] * sky);
    float3 c = pow(linear, float3(1.0 / 2.2));
    float g = logit_luma(c);
    c = mix(float3(g), c, 1.0 + 0.3 * p.v[0] * sky);
    return float4(clamp(c, 0.0, 1.0), color.a);
    """

    static let all = [hsl, colorGrade, grain, vignette, mono, subjectLight, skyRecover]

    /// 启动时在后台预编译，取景打开滤镜时不必等待。
    static func warmUp() {
        for body in all { _ = ShaderCompiler.shared.pipeline(for: body, trusted: true) }
    }
}
