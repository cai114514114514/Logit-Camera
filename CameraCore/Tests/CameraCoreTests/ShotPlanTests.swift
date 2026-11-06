import Foundation
import Testing
@testable import CameraCore

@Test func defaultPlanValidates() throws {
    try samplePlan().validate(against: typicalLimits)
}

@Test func anchorOutsideUnitSquareIsRejected() {
    var plan = samplePlan()
    plan.composition.anchor = NormalizedPoint(x: 1.2, y: 0.5)
    #expect(throws: PlanValidationError.outOfRange("anchor")) { try plan.validate(against: typicalLimits) }
}

@Test func subjectSizeMinAboveMaxIsRejected() {
    var plan = samplePlan()
    plan.composition.subjectSize = SizeRange(min: 0.6, max: 0.4)
    #expect(throws: PlanValidationError.invalidRange("subjectSize")) { try plan.validate(against: typicalLimits) }
}

@Test func minCropAreaBelowQuarterIsRejected() {
    var plan = samplePlan()
    plan.composition.minCropArea = 0.2
    #expect(throws: PlanValidationError.outOfRange("minCropArea")) { try plan.validate(against: typicalLimits) }
}

@Test func apertureOutsideLimitsIsRejected() {
    var plan = samplePlan()
    plan.exposure.aperture = ApertureIntent(mode: .prefer, value: 8)
    #expect(throws: PlanValidationError.unsupportedAperture) { try plan.validate(against: typicalLimits) }
}

@Test func triggerThresholdOutOfRangeIsRejected() {
    let plan = samplePlan(triggers: [.eyesOpen(min: 1.5)])
    #expect(throws: PlanValidationError.outOfRange("trigger.eyesOpen")) { try plan.validate(against: typicalLimits) }
}

@Test func triggerJSONRoundTrips() throws {
    let all: [Trigger] = [.subjectSharp(min: 0.5), .eyesOpen(min: 0.6), .faceToward(maxYaw: 20),
                          .horizonLevel(maxDegrees: 1), .deviceStill(maxRadPerSec: 0.1),
                          .subjectPlaced(maxError: 0.05), .highlightsSafe(maxClip: 0.01),
                          .exposureSettled, .subjectPresent]
    let data = try JSONEncoder().encode(all)
    #expect(try JSONDecoder().decode([Trigger].self, from: data) == all)
    let settled = try JSONDecoder().decode(Trigger.self, from: Data(#"{"kind":"exposureSettled"}"#.utf8))
    #expect(settled == .exposureSettled)
    let eyes = try JSONDecoder().decode(Trigger.self, from: Data(#"{"kind":"eyesOpen","threshold":0.6}"#.utf8))
    #expect(eyes == .eyesOpen(min: 0.6))
}

@Test func nullReservedFieldsDecode() throws {
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(samplePlan())) as! [String: Any]
    json["intentWeights"] = NSNull()
    json["look"] = NSNull()
    let plan = try JSONDecoder().decode(ShotPlan.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(plan.intentWeights == nil)
    #expect(plan.look == nil)
}

@Test func primarySubjectFollowsID() {
    let m = sampleMeasurement(subjects: [face(id: 1), face(id: 2)], primary: 2)
    #expect(m.primarySubject?.id == 2)
}
