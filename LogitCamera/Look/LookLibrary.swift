import CameraCore
import Foundation

/// 「我的滤镜」：用户保存的配方，存在 `Application Support/Looks/mine.json`。
enum LookLibrary {
    private static var url: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Looks", isDirectory: true).appendingPathComponent("mine.json")
    }

    static func load() -> [LookRecipe] {
        guard let data = try? Data(contentsOf: url),
              let looks = try? JSONDecoder().decode([LookRecipe].self, from: data) else { return [] }
        return looks.filter { (try? $0.validate()) != nil }
    }

    static func save(_ looks: [LookRecipe]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(looks) { try? data.write(to: url, options: .atomic) }
    }
}
