import Foundation

/// 仅开发版：有上限的决策记录（不含图像与密钥），写入 Caches/AgentTrace.json。
@MainActor
enum AgentTrace {
    private struct Entry: Codable {
        let date: Date
        let text: String
    }

    static func record(_ text: String) {
        #if DEBUG
        let url = URL.cachesDirectory.appendingPathComponent("AgentTrace.json")
        var entries = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries.append(Entry(date: Date(), text: text))
        if let data = try? JSONEncoder().encode(Array(entries.suffix(200))) { try? data.write(to: url, options: .atomic) }
        #endif
    }
}
