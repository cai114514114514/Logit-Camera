import Foundation
import Testing
@testable import CameraCore

@Test func defaultSettingsUseTheSupportedAutomaticExposureMode() throws {
    try CameraSettings().validate(against: testLimits())
}

@Test func hardwareEndpointsRemainUsable() throws {
    let lower = CameraSettings(zoom: 1, aperture: 1.4, iso: 25, shutterSeconds: 0.0001)
    let upper = CameraSettings(zoom: 10, aperture: 4, iso: 3200, shutterSeconds: 1)
    try lower.validate(against: testLimits())
    try upper.validate(against: testLimits())
    try CameraSettings(exposureBias: -3).validate(against: testLimits())
    try CameraSettings(exposureBias: 3).validate(against: testLimits())
}

@Test func unsafeModelNumbersCannotReachHardware() {
    let requests = [
        CameraSettings(zoom: .nan), CameraSettings(zoom: .infinity),
        CameraSettings(zoom: 0), CameraSettings(zoom: 10.01),
        CameraSettings(aperture: -.infinity), CameraSettings(aperture: 0),
        CameraSettings(aperture: 4.01), CameraSettings(iso: .nan),
        CameraSettings(iso: 0), CameraSettings(iso: 3201),
        CameraSettings(shutterSeconds: .infinity), CameraSettings(shutterSeconds: 0),
        CameraSettings(shutterSeconds: 0.00001), CameraSettings(shutterSeconds: 1.01),
        CameraSettings(exposureBias: .nan), CameraSettings(exposureBias: .infinity),
        CameraSettings(exposureBias: -3.01), CameraSettings(exposureBias: 3.01)
    ]
    for settings in requests {
        #expect(throws: (any Error).self) {
            try settings.validate(against: testLimits())
        }
    }
}

@Test func autoAndManualSelectionsMustMatchOneCompleteHardwareMode() throws {
    var limits = testLimits()
    limits.exposureModes = [
        ExposureModeSupport(apertureAuto: true, shutterAuto: true, isoAuto: true),
        ExposureModeSupport(apertureAuto: false, shutterAuto: false, isoAuto: false)
    ]
    #expect(throws: (any Error).self) {
        try CameraSettings(aperture: 2.8).validate(against: limits)
    }
    try CameraSettings(aperture: 2.8, iso: 100, shutterSeconds: 0.01)
        .validate(against: limits)
}

@Test func unsupportedAutoModeIsRejectedEvenWhenValuesAreInRange() {
    var limits = testLimits()
    limits.exposureModes = []
    #expect(throws: (any Error).self) {
        try CameraSettings().validate(against: limits)
    }
}

@Test func fullManualExposureCannotPretendToApplyExposureCompensation() {
    #expect(throws: (any Error).self) {
        try CameraSettings(aperture: 2.8, iso: 100, shutterSeconds: 0.01, exposureBias: 1)
            .validate(against: testLimits())
    }
}

@Test func validationExplainsTheRejectedParameterInChinese() {
    do {
        try CameraSettings(iso: 0).validate(against: testLimits())
        Issue.record("Invalid ISO was accepted")
    } catch {
        #expect(error.localizedDescription.contains("感光度"))
    }
}

@Test func nullableExposureFieldsMustStillBePresentInModelJSON() throws {
    let complete: [String: Any] = [
        "ratio": "3:4", "zoom": 1, "aperture": NSNull(),
        "iso": NSNull(), "shutterSeconds": NSNull(), "exposureBias": 0
    ]

    for missingField in ["aperture", "iso", "shutterSeconds"] {
        var incomplete = complete
        incomplete.removeValue(forKey: missingField)
        let payload = try JSONSerialization.data(withJSONObject: incomplete)
        do {
            _ = try JSONDecoder().decode(CameraSettings.self, from: payload)
            Issue.record("Missing exposure field was accepted: \(missingField)")
        } catch DecodingError.keyNotFound(let key, _) {
            #expect(key.stringValue == missingField)
        } catch {
            Issue.record("Expected a missing-field error, received: \(error)")
        }
    }
}

@Test func automaticExposureRoundTripPreservesExplicitNulls() throws {
    let payload = Data("""
        {"ratio":"1:1","zoom":2,"aperture":null,"iso":null,
        "shutterSeconds":null,"exposureBias":0.5}
        """.utf8)
    let settings = try JSONDecoder().decode(CameraSettings.self, from: payload)
    #expect(settings == CameraSettings(ratio: .square, zoom: 2, exposureBias: 0.5))
    try settings.validate(against: testLimits())

    let encoded = try JSONEncoder().encode(settings)
    let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(fields["aperture"] is NSNull)
    #expect(fields["iso"] is NSNull)
    #expect(fields["shutterSeconds"] is NSNull)
    #expect(try JSONDecoder().decode(CameraSettings.self, from: encoded) == settings)
}

// A device fixture with every exposure combination lets numeric tests fail for
// the invalid value itself instead of an unrelated exposure-mode restriction.
func testLimits() -> CameraLimits {
    let modes = [true, false].flatMap { apertureAuto in
        [true, false].flatMap { shutterAuto in
            [true, false].map { isoAuto in
                ExposureModeSupport(
                    apertureAuto: apertureAuto, shutterAuto: shutterAuto, isoAuto: isoAuto
                )
            }
        }
    }
    return CameraLimits(
        minAperture: 1.4, maxAperture: 4, apertureStops: [1.4, 2, 2.8, 4],
        minISO: 25, maxISO: 3200, minShutter: 0.0001, maxShutter: 1,
        minZoom: 1, maxZoom: 10, minBias: -3, maxBias: 3,
        exposureModes: modes
    )
}
