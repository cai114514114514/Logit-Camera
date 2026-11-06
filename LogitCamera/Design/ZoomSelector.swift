import CameraCore
import SwiftUI

/// 主摄数字变焦档位。只有一个可用档位时隐藏。
struct ZoomSelector: View {
    let model: CameraModel

    private var zoom: Double { Double(model.state.zoom) }
    private var stops: [Double] {
        ZoomStops.available(min: Double(model.state.minZoom), max: Double(model.state.maxZoom))
    }

    var body: some View {
        if stops.count > 1 {
            HStack(spacing: 8) {
                ForEach(stops, id: \.self) { stop in
                    let active = activeStop == stop
                    Button { model.setZoom(stop) } label: {
                        Text(active ? CameraText.zoom(Float(zoom)) : CameraText.zoom(Float(stop)))
                            .font(.system(active ? .caption : .caption2, design: .monospaced,
                                          weight: active ? .semibold : .medium))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .foregroundStyle(active ? Theme.color(for: origin) : Theme.Palette.inkSecondary)
                            .frame(width: active ? 40 : 32, height: active ? 40 : 32)
                            .background(Color.black.opacity(0.5), in: Circle())
                            .overlay(Circle().stroke(active ? Theme.color(for: origin).opacity(0.6) : Theme.Palette.hairline,
                                                     lineWidth: 1))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.state.canCapture)
                    .accessibilityLabel("变焦 \(CameraText.zoom(Float(stop)))")
                    .accessibilityAddTraits(active ? .isSelected : [])
                    .accessibilityIdentifier("zoom.\(Int(stop))")
                }
            }
            .animation(.snappy(duration: 0.2), value: activeStop)
            .hudTypeSize()
        }
    }

    /// 当前倍率所在的档位：不小于该档且小于下一档。
    private var activeStop: Double? {
        stops.last { zoom >= $0 - 0.05 } ?? stops.first
    }

    private var origin: ValueOrigin { model.origin(isManual: abs(zoom - 1) > 0.05) }
}
