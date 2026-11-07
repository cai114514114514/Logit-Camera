import CameraCore
import Foundation

/// 取景渲染读取的当前状态（线程安全）：AI 修正层 + 用户滤镜。
/// 修正参数每秒更新约 10 次，直接写这里，不经过 SwiftUI。
final class LookPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var recipeValue = LookRecipe.identity
    private var correctionValue: [LookOp] = []

    var recipe: LookRecipe {
        get { lock.withLock { recipeValue } }
        set { lock.withLock { recipeValue = newValue } }
    }

    var correction: [LookOp] {
        get { lock.withLock { correctionValue } }
        set { lock.withLock { correctionValue = newValue } }
    }

    var snapshot: (correction: [LookOp], recipe: LookRecipe) { lock.withLock { (correctionValue, recipeValue) } }
}
