import AppKit
import iClawCore

extension NSImage {
    static var clawMenuBar: NSImage {
        let targetSize = NSSize(width: 20, height: 20)
        let source = ClawIcon.nsImage // 746x746

        let scale = min(targetSize.width / source.size.width,
                        targetSize.height / source.size.height)
        let scaledW = source.size.width * scale
        let scaledH = source.size.height * scale

        let image = NSImage(size: targetSize, flipped: false) { _ in
            let x = (targetSize.width - scaledW) / 2
            let y = (targetSize.height - scaledH) / 2
            source.draw(in: NSRect(x: x, y: y, width: scaledW, height: scaledH),
                        from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }

        image.isTemplate = true
        return image
    }
}
