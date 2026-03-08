import AppKit

extension NSImage {
    static var clawApple: NSImage {
        let size = NSSize(width: 20, height: 20)
        let image: NSImage = NSImage(size: size, flipped: true) { rect in
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            
            // Apple body
            path.move(to: NSPoint(x: 10, y: 7))
            path.curve(to: NSPoint(x: 3, y: 12), controlPoint1: NSPoint(x: 7, y: 6.5), controlPoint2: NSPoint(x: 3, y: 8))
            path.curve(to: NSPoint(x: 10, y: 18), controlPoint1: NSPoint(x: 3, y: 16), controlPoint2: NSPoint(x: 7, y: 18.5))
            path.curve(to: NSPoint(x: 17, y: 12), controlPoint1: NSPoint(x: 13, y: 18.5), controlPoint2: NSPoint(x: 17, y: 16))
            path.curve(to: NSPoint(x: 10, y: 7), controlPoint1: NSPoint(x: 17, y: 8), controlPoint2: NSPoint(x: 13, y: 6.5))
            
            // Claw leaf
            path.move(to: NSPoint(x: 10, y: 6))
            path.curve(to: NSPoint(x: 14, y: 0), controlPoint1: NSPoint(x: 10, y: 3), controlPoint2: NSPoint(x: 12, y: 0))
            path.curve(to: NSPoint(x: 12, y: 4), controlPoint1: NSPoint(x: 13, y: 2), controlPoint2: NSPoint(x: 12, y: 3))
            path.curve(to: NSPoint(x: 16, y: 3), controlPoint1: NSPoint(x: 14, y: 3.5), controlPoint2: NSPoint(x: 15, y: 3))
            path.curve(to: NSPoint(x: 11, y: 6.5), controlPoint1: NSPoint(x: 14, y: 5), controlPoint2: NSPoint(x: 13, y: 6))
            path.close()
            
            NSColor.black.setStroke()
            path.stroke()
            
            return true
        }
        image.isTemplate = true
        return image
    }
}
