import CameraCore
import Foundation

/// 连拍中没进相册的备选，只存在本机 `Application Support/Bursts/<photoID>/`，7 天或超过 30 组后清理。
struct BurstAlternate: Identifiable, Sendable {
    let index: Int
    let url: URL
    let isAIChoice: Bool
    var id: Int { index }
}

enum BurstStore {
    private static var root: URL { URL.applicationSupportDirectory.appendingPathComponent("Bursts", isDirectory: true) }

    /// 写入整组照片与清单（后台调用）。
    static func save(_ photos: [CapturedPhoto], chosen: Int, photoID: UUID, genre: GenreID, scores: [Double],
                     look: LookRecipe? = nil) throws {
        let directory = root.appendingPathComponent(photoID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [String] = []
        for (index, photo) in photos.enumerated() {
            let name = "\(index).jpg"
            try photo.data.write(to: directory.appendingPathComponent(name), options: .atomic)
            files.append(name)
        }
        let manifest = BurstManifest(photoID: photoID, date: Date(), genre: genre, chosen: chosen, files: files, scores: scores,
                                     look: look?.isIdentity == false ? look : nil)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    static func load(photoID: UUID) -> [BurstAlternate] {
        let directory = root.appendingPathComponent(photoID.uuidString, isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(BurstManifest.self, from: data) else { return [] }
        return manifest.files.enumerated().map { index, name in
            BurstAlternate(index: index, url: directory.appendingPathComponent(name), isAIChoice: index == manifest.chosen)
        }
    }

    /// 启动时清理过期的组。
    static func purge() {
        let manager = FileManager.default
        guard let directories = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let manifests = directories.compactMap { directory -> BurstManifest? in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else {
                try? manager.removeItem(at: directory)
                return nil
            }
            return try? JSONDecoder().decode(BurstManifest.self, from: data)
        }
        for id in BurstManifest.expired(manifests, now: Date()) {
            try? manager.removeItem(at: root.appendingPathComponent(id.uuidString, isDirectory: true))
        }
    }
}
