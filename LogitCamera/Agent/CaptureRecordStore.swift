import CameraCore
import Foundation

/// 每张 AI 照片的拍摄依据（方案、测量、评分），只存在本机，供后续选片与偏好学习使用。
struct CaptureRecord: Codable, Sendable {
    let photoID: UUID
    let date: Date
    let plan: ShotPlan?
    let measurement: SceneMeasurement?
    let rubric: RubricResult?
    let automatic: Bool
}

enum CaptureRecordStore {
    static let limit = 200

    static func append(_ record: CaptureRecord) {
        Task.detached(priority: .utility) {
            let url = URL.applicationSupportDirectory.appendingPathComponent("CaptureRecords.json")
            try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            var records = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([CaptureRecord].self, from: $0) } ?? []
            records.append(record)
            if let data = try? JSONEncoder().encode(Array(records.suffix(limit))) { try? data.write(to: url, options: .atomic) }
        }
    }
}
