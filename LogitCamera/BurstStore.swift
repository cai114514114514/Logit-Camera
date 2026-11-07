import Foundation

/// 早期版本把每组连拍的 6 张原片都留在 `Application Support/Bursts/`。
/// 现在只把最好的一张存进相册，其余不落盘；启动时清掉旧版本留下的目录。
enum BurstStore {
    static func removeAll() {
        let directory = URL.applicationSupportDirectory.appendingPathComponent("Bursts", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }
}
