import Testing
@testable import CameraCore

@Test func freshValueReturned() {
    var cache = TierCache<Int>()
    cache.store(3, at: 10, epoch: 1, current: 1)
    #expect(cache.value(now: 10.4, epoch: 1) == 3)
}

@Test func staleValueDropped() {
    var cache = TierCache<Int>()
    cache.store(3, at: 10, epoch: 1, current: 1)
    #expect(cache.value(now: 10.6, epoch: 1) == nil)
}

@Test func oldEpochIgnored() {
    var cache = TierCache<Int>()
    cache.store(3, at: 10, epoch: 1, current: 2)
    #expect(cache.value(now: 10, epoch: 2) == nil)
    cache.store(4, at: 10, epoch: 2, current: 2)
    #expect(cache.value(now: 10, epoch: 3) == nil)
}

@Test func clearEmpties() {
    var cache = TierCache<Int>()
    cache.store(3, at: 10, epoch: 1, current: 1)
    cache.clear()
    #expect(cache.value(now: 10, epoch: 1) == nil)
}
