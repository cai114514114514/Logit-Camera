import Testing
@testable import CameraCore

@Test func availableStopsStayWithinTheDeviceRange() {
    #expect(ZoomStops.available(min: 1, max: 3) == [1, 2, 3])
    #expect(ZoomStops.available(min: 1, max: 1.8) == [1])
    #expect(ZoomStops.available(min: 1, max: 2.005) == [1, 2])
}

@Test func clampKeepsZoomInsideTheDeviceRange() {
    #expect(ZoomStops.clamp(5, min: 1, max: 3) == 3)
    #expect(ZoomStops.clamp(0.5, min: 1, max: 3) == 1)
    #expect(ZoomStops.clamp(.nan, min: 1, max: 3) == 1)
}
