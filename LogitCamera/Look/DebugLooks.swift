#if DEBUG
import CameraCore
import Foundation

/// 仅调试版：`-LogitLook warm|vignette` 用来在 C2 预设库之前验证实时取景、自定义着色器与成片管线。
enum DebugLooks {
    static let warm = LookRecipe(
        name: "暖调测试",
        correction: [.whiteBalance(temperature: 0.35, tint: 0.05)],
        style: [.toneCurve([CurvePoint(0, 0.04), CurvePoint(0.5, 0.53), CurvePoint(1, 0.96)]), .saturation(-0.1), .fade(0.3)])

    static let vignette = LookRecipe(
        name: "暗角测试",
        style: [.contrast(0.2), .custom(CustomShader(name: "暗角", body: """
            float d = distance(uv, float2(0.5, 0.5));
            float v = 1.0 - p.v[0] * smoothstep(0.25, 0.75, d);
            return float4(color.rgb * v, color.a);
            """, params: [0.7]))])

    static var current: LookRecipe? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-LogitLook"), index + 1 < arguments.count else { return nil }
        switch arguments[index + 1] {
        case "warm": return warm
        case "vignette": return vignette
        default: return nil
        }
    }
}
#endif
