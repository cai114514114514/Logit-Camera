import Foundation
import Testing
@testable import CameraCore

private let portraitSensor = 0.75

private func composition(ratio: FrameRatio = .standard, anchor: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5),
                         size: SizeRange = SizeRange(min: 0.4, max: 0.4), minArea: Double = 0.25) -> Composition {
    Composition(ratio: ratio, anchor: anchor, subjectSize: size, minCropArea: minArea, levelHorizon: false)
}

private func inside(_ r: NormalizedRect) -> Bool {
    r.x >= -1e-9 && r.y >= -1e-9 && r.x + r.width <= 1 + 1e-9 && r.y + r.height <= 1 + 1e-9
}

@Test func centeredSubjectLandsOnAnchor() {
    let subject = NormalizedRect(x: 0.45, y: 0.4, width: 0.1, height: 0.2)
    let anchor = NormalizedPoint(x: 0.67, y: 0.38)
    let target = CompositionSolver.solve(subject: subject, composition: composition(anchor: anchor),
                                         sensorAspect: portraitSensor, salientCenter: nil)
    #expect(target.placementError < 1e-6)
    let c = subject.center
    #expect(abs((c.x - target.crop.x) / target.crop.width - anchor.x) < 1e-6)
    #expect(abs((c.y - target.crop.y) / target.crop.height - anchor.y) < 1e-6)
    #expect(abs(target.crop.height - 0.5) < 1e-6)
}

@Test func cropKeepsRatio() {
    for ratio in FrameRatio.allCases {
        let target = CompositionSolver.solve(subject: NormalizedRect(x: 0.4, y: 0.4, width: 0.1, height: 0.2),
                                             composition: composition(ratio: ratio),
                                             sensorAspect: portraitSensor, salientCenter: nil)
        #expect(abs(target.crop.width * portraitSensor / target.crop.height - ratio.widthToHeight) < 1e-6)
        #expect(inside(target.crop))
    }
}

@Test func respectsMinCropArea() {
    let tiny = NormalizedRect(x: 0.49, y: 0.49, width: 0.02, height: 0.02)
    let target = CompositionSolver.solve(subject: tiny, composition: composition(minArea: 0.25),
                                         sensorAspect: portraitSensor, salientCenter: nil)
    #expect(target.crop.area >= 0.25 - 1e-9)
}

@Test func clampsAtSensorEdge() {
    let subject = NormalizedRect(x: 0.9, y: 0.4, width: 0.1, height: 0.2)
    let target = CompositionSolver.solve(subject: subject,
                                         composition: composition(anchor: NormalizedPoint(x: 0.33, y: 0.5)),
                                         sensorAspect: portraitSensor, salientCenter: nil)
    #expect(inside(target.crop))
    #expect(target.placementError > 0)
}

@Test func noSubjectUsesLargestCrop() {
    let target = CompositionSolver.solve(subject: nil, composition: composition(ratio: .standard),
                                         sensorAspect: portraitSensor, salientCenter: nil)
    #expect(abs(target.crop.area - 1) < 1e-6)
    #expect(target.placementError == 0)
    let square = CompositionSolver.solve(subject: nil, composition: composition(ratio: .square),
                                         sensorAspect: portraitSensor, salientCenter: NormalizedPoint(x: 0.5, y: 0.2))
    #expect(abs(square.crop.width - 1) < 1e-6)
    #expect(inside(square.crop))
    #expect(square.crop.y < 0.125)
}

@Test func springConvergesWithoutOvershoot() {
    var spring = CropSpring(timeConstant: 0.35)
    let start = NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)
    let goal = NormalizedRect(x: 0.3, y: 0.2, width: 0.5, height: 0.5)
    spring.reset(to: start)
    var last = 1.0
    var current = start
    for _ in 0..<60 {
        current = spring.step(toward: goal, dt: 1.0 / 30)
        let distance = hypot(current.x - goal.x, current.y - goal.y)
        #expect(distance <= last + 1e-12)
        #expect(current.x <= goal.x + 1e-12)
        last = distance
    }
    #expect(last < 0.01)
}

@Test func springStaysInsideSensor() {
    var spring = CropSpring()
    spring.reset(to: NormalizedRect(x: 0.4, y: 0.4, width: 0.6, height: 0.6))
    let goal = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
    for _ in 0..<30 {
        #expect(inside(spring.step(toward: goal, dt: 1.0 / 30)))
    }
}
