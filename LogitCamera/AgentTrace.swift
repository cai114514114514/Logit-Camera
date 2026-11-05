import Foundation
import CameraCore

/// Development evidence only: bounded metadata, never images or credentials.
@MainActor
enum AgentTrace {
    struct Entry: Codable {
        let date: Date
        let round: Int
        let age: Double
        let difference: Double
        let action: String
        let outcome: String
        let requested: CameraSettings?
        let actual: ExposureReading
    }

    static func record(round: Int, age: Double, difference: Double, action: String,
                       outcome: String, requested: CameraSettings?, actual: ExposureReading) {
        #if DEBUG
        let url = URL.cachesDirectory.appendingPathComponent("AgentTrace.json")
        var entries = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries.append(Entry(date: Date(), round: round, age: age, difference: difference,
                             action: action, outcome: outcome, requested: requested, actual: actual))
        entries = Array(entries.suffix(60))
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
        #endif
    }
}
