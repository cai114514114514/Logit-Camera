import CameraCore
import CoreImage
import ImageIO
import Metal

/// 把配方编译成 Core Image 滤镜图（规格 §1）。取景与成片共用同一份实现。
enum LookRenderer {
    /// 成片渲染用的半精度浮点上下文。
    static let photoContext: CIContext = {
        let options: [CIContextOption: Any] = [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false]
        if let device = ShaderCompiler.shared.device { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    /// - Parameter synchronous: 成片时为 true：自定义着色器当场编译；取景时为 false：没编译好就先跳过。
    static func apply(_ recipe: LookRecipe, to image: CIImage, time: Double = 0, synchronous: Bool = false) -> CIImage {
        guard !recipe.isIdentity else { return image }
        var output = image
        for op in recipe.allOps {
            output = apply(op, to: output, extent: image.extent, time: time, synchronous: synchronous)
        }
        output = output.cropped(to: image.extent)
        if recipe.strength < 1 {
            output = output.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: output, kCIInputImageKey: image, kCIInputTimeKey: recipe.strength
            ]).cropped(to: image.extent)
        }
        return output
    }

    private static func apply(_ op: LookOp, to image: CIImage, extent: CGRect, time: Double, synchronous: Bool) -> CIImage {
        switch op {
        case .exposure(let ev):
            return image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
        case .whiteBalance(let temperature, let tint):
            // 方向已验证：中性点色温升高 → 画面变暖；中性点 y 为正 → 偏品红。
            return image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + 3000 * temperature, y: 50 * tint),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)
            ])
        case .contrast(let amount):
            return image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + 0.5 * amount])
        case .saturation(let amount):
            return image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + amount])
        case .vibrance(let amount):
            return image.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: amount])
        case .toneCurve(let points):
            let p = ToneCurveMath.fivePoints(points)
            return image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: p[0].x, y: p[0].y), "inputPoint1": CIVector(x: p[1].x, y: p[1].y),
                "inputPoint2": CIVector(x: p[2].x, y: p[2].y), "inputPoint3": CIVector(x: p[3].x, y: p[3].y),
                "inputPoint4": CIVector(x: p[4].x, y: p[4].y)
            ])
        case .fade(let amount):
            let lift = 0.15 * amount
            return image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 - lift, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 - lift, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - lift, w: 0),
                "inputBiasVector": CIVector(x: lift, y: lift, z: lift, w: 0)
            ])
        case .custom(let shader):
            let compiler = ShaderCompiler.shared
            guard let pipeline = synchronous ? compiler.pipelineNow(for: shader.body) : compiler.pipeline(for: shader.body)
            else { return image }
            let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
            do {
                let shaded = try CustomShaderKernel.apply(withExtent: image.extent, inputs: [encoded], arguments: [
                    "pipeline": pipeline, "params": shader.params.map(Float.init), "time": Float(time), "full": extent
                ])
                return shaded.applyingFilter("CISRGBToneCurveToLinear")
            } catch {
                return image
            }
        }
    }

    /// 成片：按配方渲染已裁切的原片，输出 10-bit HEIC（Display P3），保留拍摄元数据。
    static func renderPhoto(_ data: Data, recipe: LookRecipe) throws -> Data {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw CameraFailure.capture }
        let graded = apply(recipe, to: image, synchronous: true)
        var properties = image.properties
        properties[kCGImagePropertyOrientation as String] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        return try photoContext.heif10Representation(
            of: graded.settingProperties(properties), colorSpace: colorSpace,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92])
    }
}
