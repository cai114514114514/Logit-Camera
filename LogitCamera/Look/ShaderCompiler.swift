import CameraCore
import Foundation
import Metal
import os

/// 自定义着色器的运行时编译（规格 §2）。按函数体缓存 pipeline；编译失败的函数体记下来，不再重试。
/// 取景用异步编译（编译完成前该节点按恒等处理）；成片用同步编译。
final class ShaderCompiler: @unchecked Sendable {
    static let shared = ShaderCompiler()

    let device = MTLCreateSystemDefaultDevice()
    private let lock = NSLock()
    private var cache: [String: MTLComputePipelineState] = [:]
    private var failed: Set<String> = []
    private var pending: Set<String> = []
    private let log = Logger(subsystem: "com.logitcamera", category: "shader")

    /// 已编译则返回；否则在后台开始编译并返回 nil。`trusted` 为内置着色器，跳过沙箱校验。
    func pipeline(for body: String, trusted: Bool = false) -> MTLComputePipelineState? {
        let state = lock.withLock { () -> (MTLComputePipelineState?, Bool) in
            if let cached = cache[body] { return (cached, false) }
            if failed.contains(body) || pending.contains(body) { return (nil, false) }
            pending.insert(body)
            return (nil, true)
        }
        if state.1 {
            DispatchQueue.global(qos: .userInitiated).async { _ = self.compile(body, trusted: trusted) }
        }
        return state.0
    }

    /// 同步编译（成片使用）。
    func pipelineNow(for body: String, trusted: Bool = false) -> MTLComputePipelineState? {
        if let cached = lock.withLock({ cache[body] }) { return cached }
        if lock.withLock({ failed.contains(body) }) { return nil }
        return compile(body, trusted: trusted)
    }

    func didFail(_ body: String) -> Bool { lock.withLock { failed.contains(body) } }

    private func compile(_ body: String, trusted: Bool) -> MTLComputePipelineState? {
        defer { _ = lock.withLock { pending.remove(body) } }
        do {
            if !trusted { try ShaderSandbox.validate(body) }
            guard let device else { throw LookValidationError.shader("没有 Metal 设备") }
            let library = try device.makeLibrary(source: ShaderSandbox.wrap(body), options: nil)
            guard let function = library.makeFunction(name: "logit_custom") else {
                throw LookValidationError.shader("缺少入口函数")
            }
            let state = try device.makeComputePipelineState(function: function)
            lock.withLock { cache[body] = state }
            return state
        } catch {
            lock.withLock { _ = failed.insert(body) }
            log.error("自定义着色器编译失败：\(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
