import Foundation
import Testing
@testable import CameraCore

@Test func decodesNewOps() throws {
    let json = #"""
    {"name":"t","style":[
      {"op":"highlightsShadows","highlights":-0.3,"shadows":0.2},
      {"op":"hsl","bands":[{"band":"green","hue":0.2,"saturation":-0.3},{"band":"orange","luminance":0.1}]},
      {"op":"colorGrade","shadows":{"hue":190,"amount":0.2},"highlights":{"hue":40,"amount":0.1},"balance":0.1},
      {"op":"grain","amount":0.3,"size":0.4},{"op":"vignette","amount":-0.2,"midpoint":0.5},
      {"op":"mono","red":0.4,"green":0.45,"blue":0.15},{"op":"bloom","amount":0.2}]}
    """#
    let recipe = try JSONDecoder().decode(LookRecipe.self, from: Data(json.utf8))
    try recipe.validate()
    #expect(recipe.style.count == 7)
    #expect(recipe.style[1] == .hsl([HSLBand(.green, hue: 0.2, saturation: -0.3), HSLBand(.orange, luminance: 0.1)]))
    let back = try JSONDecoder().decode(LookRecipe.self, from: JSONEncoder().encode(recipe))
    #expect(back == recipe)
}

@Test func rejectsOutOfRangeNewOps() {
    let bad: [LookOp] = [
        .highlightsShadows(highlights: 0.3, shadows: 0),
        .hsl([HSLBand(.red, hue: 1.5)]),
        .hsl([HSLBand(.red), HSLBand(.red)]),
        .colorGrade(ColorGrade(shadows: GradeWheel(hue: 400, amount: 0.1))),
        .grain(amount: 1.2, size: 0.5),
        .vignette(amount: -1.5, midpoint: 0.5),
        .mono(red: 0, green: 0, blue: 0),
        .bloom(2)
    ]
    for op in bad {
        #expect(throws: LookValidationError.self) { try LookRecipe(name: "x", style: [op]).validate() }
    }
}

@Test func presetsLoadAndValidate() throws {
    let looks = Knowledge.looks()
    #expect(looks.count == 9)
    #expect(looks.first?.name == "原片")
    #expect(looks.first?.isIdentity == true)
    for look in looks { try look.validate() }
    #expect(looks.map(\.name).contains("胶片暖"))
}

@Test func presetNamesUnique() {
    let names = Knowledge.looks().map(\.name)
    #expect(Set(names).count == names.count)
}

@Test func adjustmentsAppendToCorrectLayers() {
    var adjustments = LookAdjustments()
    adjustments.exposure = 0.3
    adjustments.temperature = 0.2
    adjustments.highlights = -0.4
    adjustments.contrast = 0.1
    adjustments.grain = 0.2
    let base = LookRecipe(name: "b", correction: [.exposure(ev: 0.1)], style: [.saturation(0.1)])
    let result = adjustments.apply(to: base)
    #expect(result.correction == [.exposure(ev: 0.1), .exposure(ev: 0.3), .whiteBalance(temperature: 0.2, tint: 0),
                                  .highlightsShadows(highlights: -0.4, shadows: 0)])
    #expect(result.style == [.saturation(0.1), .contrast(0.1), .grain(amount: 0.2, size: 0.5)])
}

@Test func zeroAdjustmentsAreNoOp() {
    let base = LookRecipe(name: "b", style: [.saturation(0.1)])
    #expect(LookAdjustments.zero.apply(to: base) == base)
    #expect(LookAdjustments.zero.isZero)
}

@Test func wrapIncludesHelpers() {
    let source = ShaderSandbox.wrap("return color;")
    #expect(source.contains("logit_rgb2hsl"))
    #expect(source.contains("float v[32]"))
    #expect(ShaderSandbox.paramCount == 32)
}
