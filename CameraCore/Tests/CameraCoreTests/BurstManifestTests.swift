import Foundation
import Testing
@testable import CameraCore

private func manifest(daysAgo: Double, from now: Date) -> BurstManifest {
    BurstManifest(photoID: UUID(), date: now.addingTimeInterval(-daysAgo * 24 * 3600), genre: .general,
                  chosen: 0, files: ["0.jpg"], scores: [1])
}

@Test func expiresOlderThan7Days() {
    let now = Date()
    let old = manifest(daysAgo: 7.5, from: now), fresh = manifest(daysAgo: 6.5, from: now)
    #expect(BurstManifest.expired([old, fresh], now: now) == [old.photoID])
}

@Test func keepsNewest30() {
    let now = Date()
    let all = (0..<32).map { manifest(daysAgo: Double($0) * 0.01, from: now) }
    let expired = Set(BurstManifest.expired(all, now: now))
    #expect(expired == Set([all[30].photoID, all[31].photoID]))
}

@Test func emptyIsEmpty() {
    #expect(BurstManifest.expired([], now: Date()).isEmpty)
}
