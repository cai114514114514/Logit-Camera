import AVFoundation
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onFocus: (CGPoint) -> Void
    var markerColor: UIColor = .white

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onFocus = onFocus
        view.markerColor = markerColor
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.onFocus = onFocus
        view.markerColor = markerColor
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onFocus: ((CGPoint) -> Void)?
        var markerColor: UIColor = .white

        init() {
            super.init(frame: .zero)
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focus)))
            isAccessibilityElement = true
            accessibilityLabel = "相机实时取景"
            accessibilityIdentifier = "camera.preview"
            accessibilityHint = "轻点画面设置对焦和测光位置"
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }

        @objc private func focus(_ gesture: UITapGestureRecognizer) {
            let location = gesture.location(in: self)
            onFocus?(previewLayer.captureDevicePointConverted(fromLayerPoint: location))
            let marker = UIView(frame: CGRect(x: location.x - 24, y: location.y - 24, width: 48, height: 48))
            marker.isUserInteractionEnabled = false
            marker.layer.borderWidth = 1
            marker.layer.borderColor = markerColor.cgColor
            marker.layer.cornerRadius = 0
            addSubview(marker)
            UIView.animate(withDuration: 0.3, delay: 0.7, animations: { marker.alpha = 0 }) { _ in
                marker.removeFromSuperview()
            }
        }
    }
}
