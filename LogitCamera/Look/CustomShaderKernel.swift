import CameraCore
import CoreImage
import Metal

/// 在 Core Image 图中执行 AI 写的逐像素着色器（`ShaderSandbox.wrap` 生成的 `logit_custom`）。
final class CustomShaderKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }

    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }

    override class func process(with inputs: [any CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: any CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let source = input.metalTexture,
              let destination = output.metalTexture, let commandBuffer = output.metalCommandBuffer,
              let pipeline = arguments?["pipeline"] as? MTLComputePipelineState,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var params = (arguments?["params"] as? [Float]) ?? []
        let count = ShaderSandbox.paramCount
        params += Array(repeating: 0, count: max(0, count - params.count))
        params = Array(params.prefix(count)) + [(arguments?["time"] as? Float) ?? 0]
        let full = (arguments?["full"] as? CGRect) ?? output.region
        let region = output.region
        // uv 以整张图为参照、左上原点。
        var extent = SIMD4<Float>(Float(region.minX - full.minX), Float(full.maxY - region.maxY),
                                  Float(full.width), Float(full.height))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        params.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.setBytes(&extent, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(MTLSize(width: destination.width, height: destination.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
    }
}
