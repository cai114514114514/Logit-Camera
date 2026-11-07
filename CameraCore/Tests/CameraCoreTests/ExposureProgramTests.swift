import Foundation
import Testing
@testable import CameraCore

private let fixedLens = ExposureLimits(minISO: 50, maxISO: 12800, minShutter: 1.0 / 8000, maxShutter: 1,
                                       apertureStops: [1.8], variableAperture: false)
private let mainLens = ExposureLimits(minISO: 50, maxISO: 12800, minShutter: 1.0 / 8000, maxShutter: 1,
                                      apertureStops: [1.6, 2.8, 4, 5.6], variableAperture: true)
private let handheld = ExposureContext(focalLength: 24, deviceAngularSpeed: 0.2, subjectSpeed: 0)

private func luma(_ encoded: Double, clip: Double = 0) -> LuminanceStats {
    LuminanceStats(histogram: Array(repeating: 1.0 / 64, count: 64), clipHigh: clip, clipLow: 0,
                   mean: encoded, subjectMean: encoded)
}

private func intent(_ motion: MotionIntent = .normal, depth: DepthIntent = .normal, ev: Double = 0,
                    floor: Double = 0, ceiling: Double = 0) -> ExposureIntent {
    ExposureIntent(meter: .subject, subjectEV: ev, highlightClipMax: 0.01, motion: motion, depth: depth,
                   shutterFloor: floor, isoCeiling: ceiling)
}

private func light(_ shutter: Double, _ iso: Double, _ aperture: Double) -> Double {
    shutter * iso / (aperture * aperture)
}

@Test func linearizesSRGB() {
    #expect(abs(ExposureProgram.linear(0.4613) - 0.18) < 0.002)
    #expect(ExposureProgram.linear(0) == 0)
    #expect(abs(ExposureProgram.linear(1) - 1) < 1e-9)
}

@Test func holdsAtTargetAndSettles() {
    var program = ExposureProgram()
    let reading = ExposureReading(aperture: 1.8, shutter: 1.0 / 48, iso: 200)
    var decision = program.step(luminance: luma(0.4613), intent: intent(), reading: reading, limits: fixedLens,
                                context: handheld, writePending: false)
    #expect(decision.target == nil)
    decision = program.step(luminance: luma(0.4613), intent: intent(), reading: reading, limits: fixedLens,
                            context: handheld, writePending: false)
    #expect(decision.target == nil)
    #expect(decision.settled)
}

@Test func brightensTowardTarget() throws {
    var program = ExposureProgram()
    let reading = ExposureReading(aperture: 1.8, shutter: 1.0 / 100, iso: 100)
    let decision = program.step(luminance: luma(0.25), intent: intent(), reading: reading, limits: fixedLens,
                                context: handheld, writePending: false)
    let target = try #require(decision.target)
    #expect(abs(target.shutter - 1.0 / 48) < 1e-9)
    let ratio = light(target.shutter, target.iso, 1.8) / light(reading.shutter, reading.iso, 1.8)
    let expected = pow(2, min(0.6 * decision.errorEV, 1))
    #expect(abs(ratio / expected - 1) < 0.01)
}

@Test func starvesInDarkness() throws {
    var program = ExposureProgram()
    let atLimit = ExposureReading(aperture: 1.8, shutter: 1.0 / 48, iso: 1600)
    let held = program.step(luminance: luma(0.01), intent: intent(), reading: atLimit, limits: fixedLens,
                            context: handheld, writePending: false)
    #expect(held.starved)
    #expect(held.target == nil)
    let climbing = ExposureReading(aperture: 1.8, shutter: 1.0 / 48, iso: 1000)
    let decision = program.step(luminance: luma(0.01), intent: intent(), reading: climbing, limits: fixedLens,
                                context: handheld, writePending: false)
    let target = try #require(decision.target)
    #expect(abs(target.shutter - 1.0 / 48) < 1e-9)
    #expect(target.iso == 1600)
    #expect(decision.starved)
}

@Test func freezeShutterFromSubjectSpeed() {
    let fast = ExposureProgram.shutterRange(intent: intent(.freeze),
                                            context: ExposureContext(focalLength: 48, deviceAngularSpeed: 0.2, subjectSpeed: 0.5),
                                            limits: fixedLens)
    #expect(abs(fast.preferred / (1.0 / 333) - 1) < 0.02)
    let still = ExposureProgram.shutterRange(intent: intent(.freeze), context: handheld, limits: fixedLens)
    #expect(abs(still.preferred - 1.0 / 250) < 1e-9)
}

@Test func stillDeviceAllowsLongerShutter() {
    let range = ExposureProgram.shutterRange(intent: intent(),
                                             context: ExposureContext(focalLength: 24, deviceAngularSpeed: 0.01, subjectSpeed: 0),
                                             limits: fixedLens)
    #expect(abs(range.slowest - 4.0 / 48) < 1e-9)
    #expect(abs(range.preferred - 1.0 / 48) < 1e-9)
}

@Test func blurMotionUses1_15WhenStill() {
    let still = ExposureProgram.shutterRange(intent: intent(.blur),
                                             context: ExposureContext(focalLength: 24, deviceAngularSpeed: 0.01, subjectSpeed: 0),
                                             limits: fixedLens)
    #expect(abs(still.preferred - 1.0 / 15) < 1e-9)
    let shaky = ExposureProgram.shutterRange(intent: intent(.blur), context: handheld, limits: fixedLens)
    #expect(abs(shaky.preferred - 1.0 / 48) < 1e-9)
}

@Test func clippedHighlightsDarken() throws {
    var program = ExposureProgram()
    let reading = ExposureReading(aperture: 1.8, shutter: 1.0 / 48, iso: 400)
    let decision = program.step(luminance: luma(0.4613, clip: 0.05), intent: intent(), reading: reading,
                                limits: fixedLens, context: handheld, writePending: false)
    #expect(decision.errorEV <= -1.0 / 3)
    let target = try #require(decision.target)
    #expect(light(target.shutter, target.iso, 1.8) < light(reading.shutter, reading.iso, 1.8))
}

@Test func depthChoosesAperture() {
    #expect(ExposureProgram.aperture(for: .deep, limits: mainLens) == 4)
    #expect(ExposureProgram.aperture(for: .shallow, limits: mainLens) == 1.6)
    #expect(ExposureProgram.aperture(for: .normal, limits: mainLens) == 1.6)
    #expect(ExposureProgram.aperture(for: .deep, limits: fixedLens) == nil)
}

@Test func writePendingHolds() {
    var program = ExposureProgram()
    let reading = ExposureReading(aperture: 1.8, shutter: 1.0 / 100, iso: 100)
    let decision = program.step(luminance: luma(0.1), intent: intent(), reading: reading, limits: fixedLens,
                                context: handheld, writePending: true)
    #expect(decision.target == nil)
}

@Test func shutterFloorOverridesSlowest() {
    let range = ExposureProgram.shutterRange(intent: intent(floor: 1.0 / 8), context: handheld, limits: fixedLens)
    #expect(range.slowest == 1.0 / 8)
}

@Test func nightUsesHigherCeiling() throws {
    var program = ExposureProgram()
    let reading = ExposureReading(aperture: 1.8, shutter: 1.0 / 48, iso: 3200)
    let decision = program.step(luminance: luma(0.02), intent: intent(), reading: reading, limits: fixedLens,
                                context: ExposureContext(focalLength: 24, deviceAngularSpeed: 0.2, subjectSpeed: 0, isNight: true),
                                writePending: false)
    let target = try #require(decision.target)
    #expect(target.iso == 6400)
}

@Test func brightSceneUsesMinISOAndFasterShutter() throws {
    var program = ExposureProgram()
    let reading = ExposureReading(aperture: 1.8, shutter: 1.0 / 48, iso: 100)
    let decision = program.step(luminance: luma(0.98), intent: intent(), reading: reading, limits: fixedLens,
                                context: handheld, writePending: false)
    let target = try #require(decision.target)
    #expect(target.iso == 50)
    #expect(target.shutter < reading.shutter)
}
