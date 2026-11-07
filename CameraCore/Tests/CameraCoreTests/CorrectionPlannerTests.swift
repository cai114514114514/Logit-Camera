import Foundation
import Testing
@testable import CameraCore

private func measurement(mean: Double = 0.45, subjectMean: Double? = nil, clipHigh: Double = 0, clipLow: Double = 0,
                         subjects: [Subject] = [], chroma: ChromaStats? = nil) -> SceneMeasurement {
    var m = sampleMeasurement(subjects: subjects, primary: subjects.first?.id)
    m.luminance = LuminanceStats(histogram: Array(repeating: 1.0 / 64, count: 64), clipHigh: clipHigh, clipLow: clipLow,
                                 mean: mean, subjectMean: subjectMean)
    m.chroma = chroma
    return m
}

private let neutral = ChromaStats(cb: 0, cr: 0, saturation: 0.1, topLuma: 0.4, topCb: 0)

@Test func backlitSubjectGetsLight() {
    let p = CorrectionPlanner.plan(measurement(mean: 0.6, subjectMean: 0.25, subjects: [face()], chroma: neutral), genre: .portrait)
    #expect(p.subjectEV > 0.4)
    #expect(p.subjectIsFace)
    #expect(abs(p.subjectCenter.x - 0.5) < 1e-9)
    #expect(p.note == "逆光，提亮了人脸")
}

@Test func clippedHighlightsRecover() {
    let p = CorrectionPlanner.plan(measurement(clipHigh: 0.02, chroma: neutral), genre: .general)
    #expect(abs(p.highlights + 0.45) < 1e-9)
}

@Test func nightKeepsColorCast() {
    let warm = ChromaStats(cb: -0.08, cr: 0.08, saturation: 0.1, topLuma: 0.2, topCb: 0)
    #expect(CorrectionPlanner.plan(measurement(chroma: warm), genre: .night).temperature == 0)
    #expect(CorrectionPlanner.plan(measurement(chroma: warm), genre: .general).temperature < 0)
}

@Test func sunsetLandscapeKeepsWarmth() {
    let warm = ChromaStats(cb: -0.06, cr: 0.06, saturation: 0.1, topLuma: 0.7, topCb: -0.05)
    #expect(CorrectionPlanner.plan(measurement(chroma: warm), genre: .landscape).temperature == 0)
}

@Test func skyRecoveredWhenBrightBlueTop() {
    let sky = ChromaStats(cb: 0, cr: 0, saturation: 0.1, topLuma: 0.85, topCb: 0.06)
    let p = CorrectionPlanner.plan(measurement(chroma: sky), genre: .landscape)
    #expect(abs(p.sky - 0.6) < 1e-9)
    #expect(p.ops().contains { if case .skyRecover(let amount, let horizon) = $0 { abs(amount - 0.6) < 1e-9 && horizon == 0.45 } else { false } })
}

@Test func facesProtectSkin() {
    let p = CorrectionPlanner.plan(measurement(subjects: [face()], chroma: neutral), genre: .portrait)
    #expect(p.skin == 1)
    #expect(p.ops().contains(.hsl([HSLBand(.orange, saturation: -0.06, luminance: 0.05)])))
}

@Test func smootherConverges() {
    var smoother = CorrectionSmoother()
    _ = smoother.step(.none, dt: 0)
    var target = CorrectionParams()
    target.sky = 0.6
    var value = CorrectionParams()
    for _ in 0..<30 { value = smoother.step(target, dt: 0.1) }
    #expect(abs(value.sky - 0.6) < 0.01)
    let half = { () -> Double in
        var s = CorrectionSmoother()
        _ = s.step(.none, dt: 0)
        return s.step(target, dt: 0.6).sky
    }()
    #expect(abs(half - 0.6 * (1 - exp(-1))) < 1e-6)
}

@Test func opsMapIntoCrop() {
    var p = CorrectionParams()
    p.subjectEV = 0.5
    p.subjectCenter = NormalizedPoint(x: 0.6, y: 0.4)
    p.subjectRadius = 0.2
    p.sky = 0.4
    p.horizon = 0.45
    let crop = NormalizedRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
    let ops = p.ops(for: crop, sensorAspect: 0.75)
    guard case .subjectLight(let x, let y, let radius, _) = ops.first(where: { if case .subjectLight = $0 { true } else { false } }) else {
        Issue.record("missing subject light"); return
    }
    #expect(abs(x - 2.0 / 3) < 1e-9)
    #expect(abs(y - 1.0 / 3) < 1e-9)
    #expect(abs(radius - 0.2 * 0.75 / 0.45) < 1e-9)
    #expect(ops.contains(.skyRecover(amount: 0.4, horizon: 0.25 / 0.6)))
}

@Test func subjectOutsideCropSkipped() {
    var p = CorrectionParams()
    p.subjectEV = 0.5
    p.subjectCenter = NormalizedPoint(x: 0.05, y: 0.5)
    let ops = p.ops(for: NormalizedRect(x: 0.3, y: 0, width: 0.7, height: 1))
    #expect(!ops.contains { if case .subjectLight = $0 { true } else { false } })
}

@Test func chromaStatsMeasureCast() {
    let width = 4, height = 10
    let luma = [UInt8](repeating: 128, count: width * height)
    let cb = [UInt8](repeating: 118, count: width * height)
    let cr = [UInt8](repeating: 140, count: width * height)
    let stats = MeasurementMath.chroma(cb: cb, cr: cr, luma: luma, width: width, height: height)
    #expect(abs(stats.cb - (-10.0 / 255)) < 1e-9)
    #expect(abs(stats.cr - 12.0 / 255) < 1e-9)
    #expect(abs(stats.topLuma - 128.0 / 255) < 1e-9)
}

@Test func newCorrectionOpsValidate() throws {
    try LookRecipe(name: "c", correction: [.subjectLight(x: 0.5, y: 0.4, radius: 0.3, amount: 0.5),
                                           .skyRecover(amount: 0.5, horizon: 0.4)]).validate()
    #expect(throws: LookValidationError.self) {
        try LookRecipe(name: "c", correction: [.subjectLight(x: 1.5, y: 0.4, radius: 0.3, amount: 0.5)]).validate()
    }
    #expect(throws: LookValidationError.self) {
        try LookRecipe(name: "c", correction: [.skyRecover(amount: 1.5, horizon: 0.4)]).validate()
    }
    let json = #"{"name":"c","correction":[{"op":"subjectLight","x":0.5,"y":0.4,"radius":0.3,"amount":0.5}]}"#
    let recipe = try JSONDecoder().decode(LookRecipe.self, from: Data(json.utf8))
    #expect(recipe.correction == [.subjectLight(x: 0.5, y: 0.4, radius: 0.3, amount: 0.5)])
}

@Test func correctionNoteCaption() {
    var director = CaptionDirector()
    #expect(director.update(CaptionSnapshot(phase: .composing, correctionNote: "压了压天空"), now: 0) == "压了压天空")
    #expect(director.update(CaptionSnapshot(phase: .scouting, correctionNote: "提亮了暗部"), now: 3) != "提亮了暗部")
}
