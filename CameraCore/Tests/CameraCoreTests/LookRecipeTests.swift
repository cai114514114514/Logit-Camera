import Foundation
import Testing
@testable import CameraCore

@Test func decodesRecipeJSON() throws {
    let json = #"""
    {"version":1,"name":"暖调","strength":0.8,
     "correction":[{"op":"whiteBalance","temperature":0.2,"tint":-0.1},{"op":"exposure","ev":0.3}],
     "style":[{"op":"toneCurve","points":[[0,0.03],[0.5,0.52],[1,0.97]]},{"op":"saturation","amount":-0.1},
              {"op":"custom","name":"暗角","body":"return color * (1.0 - p.v[0] * distance(uv, float2(0.5)));","params":[0.4]}]}
    """#
    let recipe = try JSONDecoder().decode(LookRecipe.self, from: Data(json.utf8))
    #expect(recipe.correction == [.whiteBalance(temperature: 0.2, tint: -0.1), .exposure(ev: 0.3)])
    #expect(recipe.style.count == 3)
    #expect(recipe.strength == 0.8)
    try recipe.validate()
    let roundTrip = try JSONDecoder().decode(LookRecipe.self, from: JSONEncoder().encode(recipe))
    #expect(roundTrip == recipe)
}

@Test func rejectsOutOfRangeOps() {
    #expect(throws: LookValidationError.self) { try LookRecipe(name: "x", correction: [.exposure(ev: 3)]).validate() }
    #expect(throws: LookValidationError.self) { try LookRecipe(name: "x", style: [.fade(-0.1)]).validate() }
    #expect(throws: LookValidationError.self) {
        try LookRecipe(name: "x", style: [.toneCurve([CurvePoint(0.5, 0.5), CurvePoint(0.4, 0.6)])]).validate()
    }
    #expect(throws: LookValidationError.self) { try LookRecipe(name: "x", strength: 1.5).validate() }
    #expect(throws: LookValidationError.self) {
        try LookRecipe(name: "x", style: Array(repeating: .contrast(0.1), count: 17)).validate()
    }
}

@Test func curveIsMonotoneAndHitsEndpoints() {
    let points = [CurvePoint(0, 0.05), CurvePoint(0.3, 0.25), CurvePoint(0.7, 0.8), CurvePoint(1, 0.95)]
    #expect(abs(ToneCurveMath.sample(points, at: 0) - 0.05) < 1e-9)
    #expect(abs(ToneCurveMath.sample(points, at: 1) - 0.95) < 1e-9)
    #expect(abs(ToneCurveMath.sample(points, at: 0.3) - 0.25) < 1e-9)
    var previous = -1.0
    for i in 0...100 {
        let y = ToneCurveMath.sample(points, at: Double(i) / 100)
        #expect(y >= previous - 1e-12)
        previous = y
    }
    #expect(ToneCurveMath.fivePoints(points).count == 5)
}

@Test func sandboxRejectsForbiddenTokens() {
    for body in ["#include <x>\nreturn color;", "for (int i = 0; i < 3; i++) {} return color;",
                 "while (true) {} return color;", "device float* x; return color;", "return color; [[x]]",
                 "float __x = 1; return color;", "return texture.read(uint2(0));"] {
        #expect(throws: LookValidationError.self) { try ShaderSandbox.validate(body) }
    }
    #expect(throws: LookValidationError.self) { try ShaderSandbox.validate("float4 c = color;") }
    // 子串中含有禁用词的普通标识符可以使用（format、before 不等于 for）。
    #expect(throws: Never.self) { try ShaderSandbox.validate("float format = 1.0; float before = 0.5; return color * format * before;") }
}

@Test func sandboxRejectsLongBody() {
    let body = "return color;" + String(repeating: " ", count: 2000)
    #expect(throws: LookValidationError.self) { try ShaderSandbox.validate(body) }
}

@Test func wrapContainsBodyAndFallback() {
    let source = ShaderSandbox.wrap("return color * 0.5;")
    #expect(source.contains("return color * 0.5;"))
    #expect(source.contains("kernel void logit_custom"))
    #expect(source.contains("isfinite"))
}

@Test func identityRecipe() {
    #expect(LookRecipe.identity.isIdentity)
    #expect(LookRecipe(name: "x", strength: 0, style: [.contrast(0.3)]).isIdentity)
    #expect(LookRecipe(name: "x", style: [.contrast(0.3)]).isIdentity == false)
}
