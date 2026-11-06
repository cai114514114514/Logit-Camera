import Foundation
import Testing
@testable import CameraCore

private func image(_ width: Int = 64, _ height: Int = 64, _ pixel: (Int, Int) -> UInt8) -> LumaImage {
    var bytes = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height { for x in 0..<width { bytes[y * width + x] = pixel(x, y) } }
    return LumaImage(width: width, height: height, bytes: bytes)
}

@Test func uniformGrayHasNoClipping() {
    let stats = MeasurementMath.luminance(image { _, _ in 128 }, subject: nil)
    #expect(stats.clipHigh == 0)
    #expect(stats.clipLow == 0)
    #expect(abs(stats.mean - 128.0 / 255) < 1e-9)
    #expect(stats.histogram.count == 64)
    #expect(abs(stats.histogram.reduce(0, +) - 1) < 1e-9)
}

@Test func whiteImageClipsHigh() {
    #expect(MeasurementMath.luminance(image { _, _ in 255 }, subject: nil).clipHigh == 1)
}

@Test func subjectMeanUsesRegion() {
    let img = image { x, _ in x < 32 ? 40 : 200 }
    let stats = MeasurementMath.luminance(img, subject: NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1))
    #expect(abs((stats.subjectMean ?? 0) - 200.0 / 255) < 1e-9)
}

@Test func checkerboardIsSharperThanBlur() {
    let checker = image { x, y in (x + y) % 2 == 0 ? 30 : 220 }
    let ramp = image { x, _ in UInt8(60 + x * 2) }
    #expect(MeasurementMath.sharpness(checker, region: nil) > MeasurementMath.sharpness(ramp, region: nil) + 0.3)
}

@Test func flatImageHasZeroSharpness() {
    #expect(MeasurementMath.sharpness(image { _, _ in 100 }, region: nil) == 0)
}

@Test func openEyeScoresHigherThanClosed() {
    func eye(_ height: Double) -> [NormalizedPoint] {
        (0..<8).map { i in
            let t = Double(i) / 8 * 2 * .pi
            return NormalizedPoint(x: 0.5 + 0.05 * cos(t), y: 0.5 + height / 2 * sin(t))
        }
    }
    let open = MeasurementMath.eyeOpenness(eye: eye(0.035)) ?? 0
    let closed = MeasurementMath.eyeOpenness(eye: eye(0.004)) ?? 1
    #expect(open > 0.9)
    #expect(closed < 0.2)
    #expect(MeasurementMath.eyeOpenness(eye: []) == nil)
}

@Test func sceneChangeIgnoresGlobalBrightness() {
    let base = image { x, y in UInt8(40 + (x * 3 + y) % 120) }
    let brighter = image { x, y in UInt8(70 + (x * 3 + y) % 120) }
    let change = MeasurementMath.sceneChange(MeasurementMath.signature(base), MeasurementMath.signature(brighter))
    #expect(change < 0.01)
}

@Test func sceneChangeDetectsShift() {
    let left = image { x, _ in x < 32 ? 220 : 30 }
    let right = image { x, _ in x < 32 ? 30 : 220 }
    #expect(MeasurementMath.sceneChange(MeasurementMath.signature(left), MeasurementMath.signature(right)) > 0.5)
}
