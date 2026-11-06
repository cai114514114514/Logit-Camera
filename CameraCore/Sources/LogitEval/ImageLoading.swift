import CameraCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 在 Mac 上把图片文件变成与 App 一致的输入：长边 1600 的 JPEG + 灰度测量。
enum ImageLoading {
    struct Loaded {
        let jpeg: Data
        let luma: LumaImage
    }

    static func load(_ url: URL) throws -> Loaded {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600
              ] as CFDictionary) else { throw EvalError.message("无法读取图片：\(url.path)") }
        let output = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw EvalError.message("无法编码 JPEG")
        }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw EvalError.message("无法编码 JPEG") }
        return Loaded(jpeg: output as Data, luma: try luma(image))
    }

    private static func luma(_ image: CGImage) throws -> LumaImage {
        let scale = 320 / Double(max(image.width, image.height))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw EvalError.message("无法生成灰度图") }
        return LumaImage(width: width, height: height, bytes: bytes)
    }
}

enum EvalError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let text) = self { text } else { "" } }
}

/// 离线评测使用的典型设备能力（iPhone 主摄）。
let evalLimits = CameraLimits(
    minAperture: 1.48, maxAperture: 4.0, apertureStops: [1.48, 2.0, 2.8, 4.0],
    minISO: 50, maxISO: 6400, minShutter: 1.0 / 8000, maxShutter: 1.0,
    minZoom: 1, maxZoom: 3, minBias: -2, maxBias: 2,
    exposureModes: [ExposureModeSupport(apertureAuto: true, shutterAuto: true, isoAuto: true),
                    ExposureModeSupport(apertureAuto: false, shutterAuto: true, isoAuto: true)])

func evalFrame(_ loaded: ImageLoading.Loaded) -> ModelFrame {
    let luma = loaded.luma
    let measurement = SceneMeasurement(
        timestamp: 0, subjects: [], primarySubjectID: nil,
        luminance: MeasurementMath.luminance(luma, subject: nil),
        sharpness: Sharpness(global: MeasurementMath.sharpness(luma, region: nil), subject: nil),
        horizonDegrees: nil, deviceAngularSpeed: 0, subjectSpeed: 0, sceneChange: 0, aesthetics: nil)
    return ModelFrame(jpeg: loaded.jpeg, measurement: measurement, limits: evalLimits, timestamp: 0)
}

func apiKey() throws -> String {
    let environment = ProcessInfo.processInfo.environment
    guard let key = environment["DEEPSEEK_API_KEY"] ?? environment["deepseek_api"], !key.isEmpty else {
        throw EvalError.message("请设置环境变量 DEEPSEEK_API_KEY")
    }
    return key
}

/// 非 200 响应时打印服务端错误信息，便于诊断（不打印请求体与密钥）。
struct DiagnosticTransport: HTTPTransport {
    let base = URLSessionTransport()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await base.send(request)
        if response.statusCode != 200 {
            let text = String(decoding: data.prefix(800), as: UTF8.self)
            FileHandle.standardError.write(Data("HTTP \(response.statusCode)：\(text)\n".utf8))
        }
        return (data, response)
    }
}
