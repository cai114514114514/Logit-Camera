import Foundation
@testable import CameraCore

/// 一组典型的 iPhone 主摄能力，供 Agent 相关测试复用。
let typicalLimits = CameraLimits(
    minAperture: 1.48, maxAperture: 4.0, apertureStops: [1.48, 2.0, 2.8, 4.0],
    minISO: 50, maxISO: 6400, minShutter: 1.0 / 8000, maxShutter: 1.0,
    minZoom: 1, maxZoom: 3, minBias: -2, maxBias: 2,
    exposureModes: [
        ExposureModeSupport(apertureAuto: true, shutterAuto: true, isoAuto: true),
        ExposureModeSupport(apertureAuto: false, shutterAuto: true, isoAuto: true),
        ExposureModeSupport(apertureAuto: false, shutterAuto: false, isoAuto: true),
        ExposureModeSupport(apertureAuto: true, shutterAuto: false, isoAuto: true)
    ]
)

func samplePlan(subject: SubjectKind = .face, triggers: [Trigger] = [.eyesOpen(min: 0.6)], holdMs: Int = 200) -> ShotPlan {
    ShotPlan(
        genre: .portrait, genreConfidence: 0.9, subject: subject,
        composition: Composition(ratio: .standard, anchor: NormalizedPoint(x: 0.67, y: 0.38),
                                 subjectSize: SizeRange(min: 0.35, max: 0.55), minCropArea: 0.25, levelHorizon: false),
        exposure: ExposureIntent(meter: .subject, subjectEV: 0.3, highlightClipMax: 0.01,
                                 aperture: ApertureIntent(mode: .prefer, value: 2.0),
                                 shutterFloor: 1.0 / 125, isoCeiling: 1600),
        triggers: triggers, holdMs: holdMs, rationale: "逆光人像，主体放右三分")
}

func sampleMeasurement(at time: TimeInterval = 0, subjects: [Subject] = [], primary: Int? = nil,
                       horizon: Double? = nil, angularSpeed: Double = 0, clipHigh: Double = 0,
                       subjectSharpness: Double? = 0.8) -> SceneMeasurement {
    SceneMeasurement(
        timestamp: time, subjects: subjects, primarySubjectID: primary,
        luminance: LuminanceStats(histogram: Array(repeating: 1.0 / 64, count: 64), clipHigh: clipHigh,
                                  clipLow: 0, mean: 0.45, subjectMean: 0.45),
        sharpness: Sharpness(global: 0.7, subject: subjectSharpness),
        horizonDegrees: horizon, deviceAngularSpeed: angularSpeed, subjectSpeed: 0, sceneChange: 0,
        aesthetics: nil)
}

func face(id: Int = 1, box: NormalizedRect = NormalizedRect(x: 0.4, y: 0.3, width: 0.2, height: 0.25),
          yaw: Double = 0, eyes: Double = 0.9) -> Subject {
    Subject(id: id, kind: .face, box: box, confidence: 0.95, yaw: yaw, pitch: 0, roll: 0,
            eyeOpenness: eyes, faceQuality: 0.7)
}
