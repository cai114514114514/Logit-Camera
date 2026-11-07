import Foundation

public struct PhotoArchive: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func store(_ data: Data, fileExtension: String = "jpg") throws -> URL {
        guard !data.isEmpty else { throw ArchiveError.emptyPhoto }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        try data.write(to: destination, options: .atomic)
        return destination
    }
}

private enum ArchiveError: LocalizedError {
    case emptyPhoto
    var errorDescription: String? { "照片数据为空，无法保存。" }
}
