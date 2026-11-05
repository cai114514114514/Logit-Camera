import Foundation
import Testing
@testable import CameraCore

@Test func preservesOriginalBytesInPersistentStorage() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = PhotoArchive(directory: directory)
    let original = Data([0xff, 0xd8, 0x12, 0x34, 0xff, 0xd9])
    let url = try archive.store(original)
    try #require(FileManager.default.fileExists(atPath: url.path))
    #expect(try Data(contentsOf: url) == original)
}

@Test func subsequentPhotosCannotOverwritePendingOriginals() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = PhotoArchive(directory: directory)
    let first = try archive.store(Data([1, 2, 3]))
    let second = try archive.store(Data([4, 5, 6]))
    try #require(first != second)
    #expect(try Data(contentsOf: first) == Data([1, 2, 3]))
    #expect(try Data(contentsOf: second) == Data([4, 5, 6]))
}

@Test func emptyPhotosAreRejected() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(throws: (any Error).self) {
        try PhotoArchive(directory: directory).store(Data())
    }
}
