import Foundation
import Testing
@testable import CameraCore

@Test func defaultPlanValidates() throws {
    try samplePlan().validate(against: typicalLimits)
}

@Test func decodesV2Plan() throws {
    let json = #"""
    {"genre":"portrait","genreConfidence":0.9,"subject":"face",
     "composition":{"ratio":"3:4","anchor":{"x":0.5,"y":0.36},"subjectSize":{"min":0.14,"max":0.24},"minCropArea":0.25,"levelHorizon":false},
     "lens":{"focalLength":48},
     "exposure":{"meter":"subject","subjectEV":0.3,"highlightClipMax":0.01,"motion":"freeze","depth":"shallow","shutterFloor":0,"isoCeiling":0},
     "moment":[{"kind":"eyesOpen","threshold":0.6},{"kind":"faceToward","threshold":25}],
     "holdMs":200,"rationale":"人像"}
    """#
    let plan = try JSONDecoder().decode(ShotPlan.self, from: Data(json.utf8))
    #expect(plan.lens.focalLength == 48)
    #expect(plan.exposure.motion == .freeze)
    #expect(plan.exposure.depth == .shallow)
    #expect(plan.exposure.shutterFloor == 0)
    #expect(plan.moment == [.eyesOpen(min: 0.6), .faceToward(maxYaw: 25)])
    #expect(plan.composition.ratio == .standard)
}

@Test func momentDropsRemovedKinds() throws {
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(samplePlan())) as! [String: Any]
    json["moment"] = [["kind": "exposureSettled"], ["kind": "subjectPresent", "threshold": 0],
                      ["kind": "smile", "threshold": 0.5], ["kind": "eyesOpen", "threshold": 0.7]]
    let plan = try JSONDecoder().decode(ShotPlan.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(plan.moment == [.eyesOpen(min: 0.7)])
}

@Test func validateUsesPerKindRanges() throws {
    #expect {
        try samplePlan(moment: [.eyesOpen(min: 0.6), .faceToward(maxYaw: 50)]).validate(against: typicalLimits)
    } throws: { error in
        guard case .outOfRange(let text) = error as? PlanValidationError else { return false }
        return text.contains("faceToward") && text.contains("moment[1]")
    }
    try samplePlan(moment: [.deviceStill(maxRadPerSec: 1.5)]).validate(against: typicalLimits)
    #expect(throws: PlanValidationError.self) {
        try samplePlan(moment: [.highlightsSafe(maxClip: 0.1)]).validate(against: typicalLimits)
    }
}

@Test func validateFocalLength() throws {
    try samplePlan(focalLength: 0).validate(against: typicalLimits)
    try samplePlan(focalLength: 100).validate(against: typicalLimits)
    #expect(throws: PlanValidationError.self) { try samplePlan(focalLength: 200).validate(against: typicalLimits) }
    #expect(throws: PlanValidationError.self) { try samplePlan(focalLength: 8).validate(against: typicalLimits) }
}

@Test func validateOverrides() throws {
    var plan = samplePlan()
    plan.exposure.shutterFloor = 2
    #expect(throws: PlanValidationError.self) { try plan.validate(against: typicalLimits) }
    plan.exposure.shutterFloor = 0
    plan.exposure.isoCeiling = 50
    #expect(throws: PlanValidationError.self) { try plan.validate(against: typicalLimits) }
    plan.exposure.isoCeiling = 0
    try plan.validate(against: typicalLimits)
}

@Test func anchorOutsideUnitSquareIsRejected() {
    var plan = samplePlan()
    plan.composition.anchor = NormalizedPoint(x: 1.2, y: 0.5)
    #expect(throws: PlanValidationError.outOfRange("composition.anchor.x")) { try plan.validate(against: typicalLimits) }
}

@Test func subjectSizeMinAboveMaxIsRejected() {
    var plan = samplePlan()
    plan.composition.subjectSize = SizeRange(min: 0.6, max: 0.4)
    #expect(throws: PlanValidationError.self) { try plan.validate(against: typicalLimits) }
}

@Test func minCropAreaBelowQuarterIsRejected() {
    var plan = samplePlan()
    plan.composition.minCropArea = 0.2
    #expect(throws: PlanValidationError.outOfRange("composition.minCropArea")) { try plan.validate(against: typicalLimits) }
}

@Test func triggerJSONRoundTrips() throws {
    let all: [Trigger] = [.subjectSharp(min: 0.5), .eyesOpen(min: 0.6), .faceToward(maxYaw: 20),
                          .horizonLevel(maxDegrees: 1), .deviceStill(maxRadPerSec: 0.1),
                          .subjectPlaced(maxError: 0.05), .highlightsSafe(maxClip: 0.01)]
    let data = try JSONEncoder().encode(all)
    #expect(try JSONDecoder().decode([Trigger].self, from: data) == all)
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
