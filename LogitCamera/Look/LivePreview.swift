import CameraCore
import CoreImage
import Metal
import QuartzCore
import SwiftUI

/// 实时取景渲染（规格 §3）：在帧队列上把每一帧按当前配方渲染到 CAMetalLayer。最多 2 帧在途，忙时丢帧。
final class LiveRenderer: @unchecked Sendable {
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let context: CIContext?
    private let lock = NSLock()
    private let inFlight = DispatchSemaphore(value: 2)
    private var pipeline = LookPipeline()
    private weak var layer: CAMetalLayer?
    private var drawableSize: CGSize = .zero
    private var imageSize: CGSize = .zero
    private let start = ProcessInfo.processInfo.systemUptime

    init() {
        device = ShaderCompiler.shared.device
        queue = device?.makeCommandQueue()
        context = queue.map { CIContext(mtlCommandQueue: $0, options: [.cacheIntermediates: false]) }
    }

    func attach(_ layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        lock.withLock { self.layer = layer }
    }

    func setDrawableSize(_ size: CGSize) { lock.withLock { drawableSize = size } }
    func setPipeline(_ pipeline: LookPipeline) { lock.withLock { self.pipeline = pipeline } }
    /// 最近一帧的像素尺寸（直立），用于点按坐标换算。
    var latestImageSize: CGSize { lock.withLock { imageSize } }

    /// 帧队列上调用。
    func render(_ buffer: CVPixelBuffer) {
        let (layer, size, pipeline) = lock.withLock { (self.layer, drawableSize, self.pipeline) }
        let (correction, recipe) = pipeline.snapshot
        let image = CIImage(cvPixelBuffer: buffer)
        lock.withLock { imageSize = image.extent.size }
        guard let layer, let queue, let context, size.width > 0, size.height > 0 else { return }
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = layer.nextDrawable(), let commandBuffer = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        // 等比铺满：先缩到可绘制尺寸再调色，滤镜只处理屏幕上看得见的像素。
        let scale = max(size.width / image.extent.width, size.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (scaled.extent.width - size.width) / 2, dy = (scaled.extent.height - size.height) / 2
        let framed = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX - dx, y: -scaled.extent.minY - dy))
            .cropped(to: CGRect(origin: .zero, size: size))
        let time = ProcessInfo.processInfo.systemUptime - start
        // AI 修正在前（全画幅坐标），用户滤镜在后；滤镜强度不影响修正。
        let corrected = correction.isEmpty ? framed
            : LookRenderer.apply(LookRecipe(name: "AI 修正", correction: correction), to: framed, time: time)
        let graded = LookRenderer.apply(recipe, to: corrected, time: time)
        let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: commandBuffer)
        destination.isFlipped = true
        destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        do {
            try context.startTask(toRender: graded, to: destination)
        } catch {
            inFlight.signal()
            return
        }
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        commandBuffer.commit()
    }
}

/// 用 Metal 实时取景替代系统预览层；点按对焦、对焦标记与无障碍标识与原来一致。
struct LivePreview: UIViewRepresentable {
    let frames: FrameGrabber
    let pipeline: LookPipeline
    let onFocus: (CGPoint) -> Void
    var markerColor: UIColor = .white

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        let renderer = view.renderer
        frames.onFrame = { buffer in renderer.render(buffer) }
        update(view)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) { update(view) }

    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {}

    private func update(_ view: PreviewView) {
        view.onFocus = onFocus
        view.markerColor = markerColor
        view.renderer.setPipeline(pipeline)
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }
        let renderer = LiveRenderer()
        var onFocus: ((CGPoint) -> Void)?
        var markerColor: UIColor = .white

        init() {
            super.init(frame: .zero)
            backgroundColor = .black
            renderer.attach(layer as! CAMetalLayer)
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focus)))
            isAccessibilityElement = true
            accessibilityLabel = "相机实时取景"
            accessibilityIdentifier = "camera.preview"
            accessibilityHint = "轻点画面设置对焦和测光位置"
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            let scale = window?.screen.scale ?? traitCollection.displayScale
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            (layer as? CAMetalLayer)?.drawableSize = size
            renderer.setDrawableSize(size)
        }

        /// 视图坐标 → 直立全画幅归一化坐标（考虑等比铺满裁掉的边）。
        func normalizedPoint(for location: CGPoint) -> CameraCore.NormalizedPoint {
            let image = renderer.latestImageSize
            guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else {
                return CameraCore.NormalizedPoint(x: location.x / max(bounds.width, 1), y: location.y / max(bounds.height, 1))
            }
            let scale = max(bounds.width / image.width, bounds.height / image.height)
            let shown = CGSize(width: image.width * scale, height: image.height * scale)
            let offset = CGPoint(x: (bounds.width - shown.width) / 2, y: (bounds.height - shown.height) / 2)
            return CameraCore.NormalizedPoint(x: min(max((location.x - offset.x) / shown.width, 0), 1),
                                              y: min(max((location.y - offset.y) / shown.height, 0), 1))
        }

        @objc private func focus(_ gesture: UITapGestureRecognizer) {
            let location = gesture.location(in: self)
            onFocus?(CaptureSession.devicePoint(normalizedPoint(for: location)))
            let marker = UIView(frame: CGRect(x: location.x - 24, y: location.y - 24, width: 48, height: 48))
            marker.isUserInteractionEnabled = false
            marker.layer.borderWidth = 1
            marker.layer.borderColor = markerColor.cgColor
            addSubview(marker)
            UIView.animate(withDuration: 0.3, delay: 0.7, animations: { marker.alpha = 0 }) { _ in
                marker.removeFromSuperview()
            }
        }
    }
}
