import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct ThinkingDotsView: View {
    var time: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                let phase = Float(i) * 0.7
                let scale = reduceMotion ? 1.0 : 0.5 + 0.5 * abs(sin(Double(time * 2.5 + phase)))
                Circle()
                    .fill(.primary.opacity(0.6))
                    .frame(width: 6, height: 6)
                    .scaleEffect(scale)
                    .animation(reduceMotion ? nil : .snappy, value: time)
            }
        }
        .accessibilityHidden(true)
    }
}

struct AudioWaveformView: View {
    var time: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let barCount = 5

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                let phase = Float(i) * 0.8
                let height = reduceMotion ? 0.6 : 0.3 + 0.7 * abs(sin(Double(time * 3.0 + phase)))
                RoundedRectangle(cornerRadius: 2)
                    .fill(.primary.opacity(0.6))
                    .frame(width: 3, height: 24 * height)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: time)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A text view that scrolls horizontally (marquee) when the text is wider than its container.
/// Respects Reduce Motion — shows truncated text instead of scrolling.
struct MarqueeText: View {
    let text: String
    let font: Font

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private let gap: CGFloat = 40
    private let speed: Double = 30 // points per second

    private var needsScroll: Bool { !reduceMotion && textWidth > containerWidth && containerWidth > 0 }

    var body: some View {
        GeometryReader { geo in
            let content = Group {
                if needsScroll {
                    HStack(spacing: gap) {
                        label
                        label
                    }
                    .offset(x: offset)
                } else {
                    label
                }
            }
            content
                .onAppear {
                    containerWidth = geo.size.width
                    restartIfNeeded()
                }
                .onChange(of: geo.size.width) {
                    containerWidth = geo.size.width
                    restartIfNeeded()
                }
        }
        .frame(height: marqueeHeight)
        .clipped()
    }

    private var marqueeHeight: CGFloat {
        #if canImport(AppKit)
        ceil(NSFont.systemFont(ofSize: 12).boundingRectForFont.height)
        #else
        ceil(UIFont.systemFont(ofSize: 12).lineHeight)
        #endif
    }

    private var label: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { textWidth = geo.size.width }
                    .onChange(of: geo.size.width) { textWidth = geo.size.width }
            })
    }

    private func restartIfNeeded() {
        guard needsScroll else {
            offset = 0
            return
        }
        offset = 0
        let totalWidth = textWidth + gap
        let duration = totalWidth / speed
        withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
            offset = -totalWidth
        }
    }
}

#if canImport(AppKit)
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    // Corner radius applied directly to the underlying NSVisualEffectView's
    // layer. SwiftUI's outer `.clipShape` doesn't reliably mask
    // NSViewRepresentable-hosted NSVisualEffectView in a nonactivating panel
    // — on re-show the backing layer renders at full bounds for a frame,
    // producing a solid grey rectangle without rounded corners. Clipping the
    // effect view itself removes that failure mode.
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        applyCorner(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        applyCorner(nsView)
    }

    private func applyCorner(_ view: NSVisualEffectView) {
        guard cornerRadius > 0 else { return }
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }
}
#else
struct VisualEffectView: UIViewRepresentable {
    // On iOS, material/blendingMode are accepted but we use UIVisualEffectView
    let material: Int // unused, kept for API compatibility
    let blendingMode: Int // unused
    var cornerRadius: CGFloat = 0

    init(material: Int = 0, blendingMode: Int = 0, cornerRadius: CGFloat = 0) {
        self.material = material
        self.blendingMode = blendingMode
        self.cornerRadius = cornerRadius
    }

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        if cornerRadius > 0 {
            view.layer.cornerRadius = cornerRadius
            view.layer.cornerCurve = .continuous
            view.layer.masksToBounds = true
        }
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        if cornerRadius > 0 {
            uiView.layer.cornerRadius = cornerRadius
            uiView.layer.cornerCurve = .continuous
            uiView.layer.masksToBounds = true
        }
    }
}
#endif
