import Testing
@testable import CameraCore

@Test func rejectsInvalidHardwareRanges() {
    #expect(ApertureRange(minimum: 0, maximum: 4, stops: []) == nil)
    #expect(ApertureRange(minimum: 4, maximum: 1.48, stops: []) == nil)
    #expect(ApertureRange(minimum: .nan, maximum: 4, stops: []) == nil)
    #expect(ApertureRange(minimum: 1.48, maximum: .infinity, stops: []) == nil)
}

@Test func fixedLensDoesNotOfferApertureAdjustment() throws {
    let range = try #require(ApertureRange(minimum: 2.2, maximum: 2.2, stops: [2.2]))
    #expect(!range.isVariable)
    #expect(range.contains(2.2))
    #expect(!range.contains(1.8))
}

@Test func acceptsEndpointsButRejectsUnsafeRequests() throws {
    let range = try #require(ApertureRange(minimum: 1.48, maximum: 4, stops: []))
    #expect(range.isVariable)
    #expect(range.contains(1.48))
    #expect(range.contains(4))
    #expect(range.contains(2.5))
    #expect(!range.contains(1.47))
    #expect(!range.contains(4.01))
    #expect(!range.contains(.nan))
    #expect(!range.contains(.infinity))
}

@Test func onlyOffersValidUniqueHardwareStops() throws {
    let range = try #require(ApertureRange(
        minimum: 1.48, maximum: 4,
        stops: [4, 1.8, .nan, 0, 1.48, 1.8, 2.8, 8, .infinity]
    ))
    #expect(range.stops == [1.48, 1.8, 2.8, 4])
}

@Test func doesNotInventStopsWhenDeviceReportsNone() throws {
    let range = try #require(ApertureRange(minimum: 1.48, maximum: 4, stops: []))
    #expect(range.stops.isEmpty)
    #expect(range.isVariable)
}
