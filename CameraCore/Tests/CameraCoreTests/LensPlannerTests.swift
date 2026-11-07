import Foundation
import Testing
@testable import CameraCore

private let deviceStops = LensStop.stops(switchOver: [2, 8], displayMultiplier: 0.5, hasUltraWide: true, hasTele: true)
private let wideStops = [LensStop(focalLength: 13, zoomFactor: 0.5, lens: .ultraWide),
                         LensStop(focalLength: 24, zoomFactor: 1, lens: .wide),
                         LensStop(focalLength: 48, zoomFactor: 2, lens: .wide),
                         LensStop(focalLength: 120, zoomFactor: 5, lens: .telephoto)]

@Test func stopsFromTripleCamera() {
    #expect(deviceStops.map(\.focalLength) == [13, 24, 48, 96])
    #expect(deviceStops.map(\.zoomFactor) == [0.5, 1, 2, 4])
    #expect(deviceStops.map(\.lens) == [.ultraWide, .wide, .wide, .telephoto])
}

/// iPhone 12 Pro：超广角 + 主摄 + 2× 长焦（虚拟设备 switch-over [2, 4]，显示倍率 0.5）。
@Test func twoTimesTelephotoReplacesMainCrop() {
    let stops = LensStop.stops(switchOver: [2, 4], displayMultiplier: 0.5, hasUltraWide: true, hasTele: true)
    #expect(stops.map(\.zoomFactor) == [0.5, 1, 2])
    #expect(stops.map(\.lens) == [.ultraWide, .wide, .telephoto])
}

/// iPhone 12 Pro Max：2.5× 长焦，保留主摄 2× 裁切。
@Test func twoAndHalfTelephotoKeepsMainCrop() {
    let stops = LensStop.stops(switchOver: [2, 5], displayMultiplier: 0.5, hasUltraWide: true, hasTele: true)
    #expect(stops.map(\.zoomFactor) == [0.5, 1, 2, 2.5])
    #expect(stops.map(\.focalLength) == [13, 24, 48, 60])
}

/// iPhone 12 / 13 / 14 / 15 / 16（非 Pro）：超广角 + 主摄。
@Test func dualWideHasNoTelephoto() {
    let stops = LensStop.stops(switchOver: [2], displayMultiplier: 0.5, hasUltraWide: true, hasTele: false)
    #expect(stops.map(\.zoomFactor) == [0.5, 1, 2])
    #expect(stops.map(\.lens) == [.ultraWide, .wide, .wide])
}

@Test func stopsWithoutTripleCamera() {
    let stops = LensStop.stops(switchOver: [], displayMultiplier: 1, hasUltraWide: false, hasTele: false)
    #expect(stops.map(\.focalLength) == [24, 48])
}

@Test func snapsByLogDistance() {
    // 24 与 48 的几何中点约 33.9 mm。
    #expect(LensPlanner.nearest(30, in: wideStops)?.focalLength == 24)
    #expect(LensPlanner.nearest(35, in: wideStops)?.focalLength == 48)
    #expect(LensPlanner.nearest(40, in: wideStops)?.focalLength == 48)
    #expect(LensPlanner.nearest(100, in: wideStops)?.focalLength == 120)
}

@Test func zeroUsesGenreDefault() {
    var planner = LensPlanner(stops: wideStops)
    #expect(planner.plan(for: LensIntent(focalLength: 0), genreDefault: 48, planID: UUID())?.focalLength == 48)
}

@Test func samePlanDoesNotSwitchAgain() {
    var planner = LensPlanner(stops: wideStops)
    let id = UUID()
    #expect(planner.plan(for: LensIntent(focalLength: 120), genreDefault: 24, planID: id)?.focalLength == 120)
    #expect(planner.plan(for: LensIntent(focalLength: 13), genreDefault: 24, planID: id) == nil)
}

@Test func starvationFallsBackToMainOnce() {
    var planner = LensPlanner(stops: wideStops)
    let id = UUID()
    _ = planner.plan(for: LensIntent(focalLength: 120), genreDefault: 24, planID: id)
    #expect(planner.reportStarved(true, now: 0) == nil)
    #expect(planner.reportStarved(true, now: 0.5) == nil)
    #expect(planner.reportStarved(true, now: 1.0)?.focalLength == 24)
    #expect(planner.plan(for: LensIntent(focalLength: 120), genreDefault: 24, planID: id) == nil)
    #expect(planner.reportStarved(true, now: 3) == nil)
    #expect(planner.current?.focalLength == 24)
}

@Test func starvationResetsWhenLightReturns() {
    var planner = LensPlanner(stops: wideStops)
    _ = planner.plan(for: LensIntent(focalLength: 120), genreDefault: 24, planID: UUID())
    _ = planner.reportStarved(true, now: 0)
    _ = planner.reportStarved(false, now: 0.6)
    #expect(planner.reportStarved(true, now: 1.0) == nil)
}

@Test func starvationOnMainDoesNothing() {
    var planner = LensPlanner(stops: wideStops)
    _ = planner.plan(for: LensIntent(focalLength: 24), genreDefault: 24, planID: UUID())
    #expect(planner.reportStarved(true, now: 0) == nil)
    #expect(planner.reportStarved(true, now: 5) == nil)
}

@Test func newPlanClearsFallback() {
    var planner = LensPlanner(stops: wideStops)
    _ = planner.plan(for: LensIntent(focalLength: 120), genreDefault: 24, planID: UUID())
    _ = planner.reportStarved(true, now: 0)
    _ = planner.reportStarved(true, now: 1)
    #expect(planner.plan(for: LensIntent(focalLength: 120), genreDefault: 24, planID: UUID())?.focalLength == 120)
}

@Test func steplessZoomLensHysteresis() {
    func lens(_ zoom: Double, _ current: LensStop.Lens) -> LensStop.Lens {
        LensStop.lens(forDisplayZoom: zoom, current: current, teleBase: 4, hasUltraWide: true)
    }
    #expect(lens(0.7, .wide) == .ultraWide)
    #expect(lens(1.02, .ultraWide) == .ultraWide)   // 滞回：超广角继续到 1.05×
    #expect(lens(1.1, .ultraWide) == .wide)
    #expect(lens(4.1, .wide) == .wide)              // 滞回：主摄数码到 4.2×
    #expect(lens(4.3, .wide) == .telephoto)
    #expect(lens(4.1, .telephoto) == .telephoto)
    #expect(lens(3.9, .telephoto) == .wide)         // 长焦不能低于 4×
    #expect(lens(0.8, .telephoto) == .ultraWide)
    #expect(lens(30, .ultraWide) == .telephoto)
    #expect(LensStop.lens(forDisplayZoom: 0.7, current: .wide, teleBase: nil, hasUltraWide: false) == .wide)
    #expect(LensStop.lens(forDisplayZoom: 20, current: .wide, teleBase: nil, hasUltraWide: true) == .wide)
}
