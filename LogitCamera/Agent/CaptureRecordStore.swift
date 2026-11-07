import CameraCore
import Foundation

/// 每张 AI 照片的拍摄依据（意图、测量、点评），以及用户在连拍里换选的那一张。
/// 只存在本机，供子项目 4（偏好学习）使用。
struct CaptureRecord: Codable, Sendable {
    let photoID: UUID
    let date: Date
    let plan: ShotPlan?
    let measurement: SceneMeasurement?
    let rubric: RubricResult?
    let automatic: Bool
    /// 用户在照片详情里「换成这张」时选中的连拍序号；nil 表示接受 AI 的选择。
    var chosenIndex: Int?
}

/// 串行读写（actor），避免并发的读-改-写互相覆盖。
actor CaptureRecordStore {
    static let shared = CaptureRecordStore()
    static let limit = 200

    private var url: URL { URL.applicationSupportDirectory.appendingPathComponent("CaptureRecords.json") }

    func append(_ record: CaptureRecord) {
        var records = load()
        records.append(record)
        save(records)
    }

    private func load() -> [CaptureRecord] {
        // 旧格式（v1 方案）解码失败时从空开始。
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([CaptureRecord].self, from: $0) } ?? []
    }

    private func save(_ records: [CaptureRecord]) {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(records.suffix(Self.limit))) { try? data.write(to: url, options: .atomic) }
    }
}
