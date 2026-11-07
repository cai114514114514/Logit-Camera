import CameraCore
import SwiftUI

/// 镜头档位（0.5× 超广角、1× 主摄、2× 主摄裁切、长焦）。只有一个可用档位时隐藏。
/// 点按跳到镜头档；在档位上左右拖动可无极变焦（0.5×–40×，对数刻度，向右放大）。
struct ZoomSelector: View {
    let model: CameraModel
    @State private var scrubStart: Double?

    private var zoom: Double { Double(model.state.zoom) }
    private var stops: [Double] {
        let lenses = model.state.lensStops.map(\.zoomFactor)
        return lenses.isEmpty ? ZoomStops.available(min: Double(model.state.minZoom), max: Double(model.state.maxZoom)) : lenses
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
                    .accessibilityIdentifier("zoom.\(stop == stop.rounded() ? String(Int(stop)) : String(stop))")
                }
            }
            .animation(.snappy(duration: 0.2), value: activeStop)
            .overlay(alignment: .top) {
                if scrubStart != nil {
                    Text(CameraText.zoom(Float(zoom)))
                        .font(.system(.callout, design: .monospaced, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .offset(y: -34)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .highPriorityGesture(scrub)
            .accessibilityAdjustableAction { direction in
                let factor = direction == .increment ? 1.25 : 0.8
                model.setZoom(zoom * factor, animated: true)
            }
            .hudTypeSize()
        }
    }

    /// 拖动 80 pt 变焦一倍（对数刻度），移动超过 8 pt 才开始，点按仍然切档。
    private var scrub: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let start = scrubStart ?? zoom
                if scrubStart == nil { withAnimation(.easeOut(duration: 0.15)) { scrubStart = start } }
                let target = start * pow(2, Double(value.translation.width) / 80)
                model.setZoom(min(max(target, Double(model.state.minZoom)), Double(model.state.maxZoom)), animated: false)
            }
            .onEnded { _ in withAnimation(.easeOut(duration: 0.3)) { scrubStart = nil } }
    }

    /// 当前倍率所在的档位：不小于该档且小于下一档。
    private var activeStop: Double? {
        stops.last { zoom >= $0 - 0.05 } ?? stops.first
    }

    private var origin: ValueOrigin { model.origin(isManual: model.agentOwnsSettings || abs(zoom - 1) > 0.05) }
}
