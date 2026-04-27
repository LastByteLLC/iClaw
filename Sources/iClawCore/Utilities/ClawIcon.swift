import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Provides the iClaw icon as a SwiftUI Image, rendered from SVG path data.
/// Used in place of `brain.head.profile` SF Symbol across the app.
public enum ClawIcon {

    /// SwiftUI Image of the claw icon, suitable for use as a template image.
    public static var image: Image {
        #if os(macOS)
        Image(nsImage: nsImage)
        #else
        Image(uiImage: uiImage)
        #endif
    }

    #if os(macOS)
    /// NSImage of the claw icon (template mode).
    public static var nsImage: NSImage {
        let img = NSImage(size: NSSize(width: 746, height: 746), flipped: true) { _ in
            drawPaths()
            return true
        }
        img.isTemplate = true
        return img
    }
    #else
    /// UIImage of the claw icon (template mode).
    public static var uiImage: UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 746, height: 746))
        let img = renderer.image { ctx in
            // Flip coordinate system to match SVG (origin top-left)
            ctx.cgContext.translateBy(x: 0, y: 746)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            drawPathsCG(ctx.cgContext)
        }
        return img.withRenderingMode(.alwaysTemplate)
    }
    #endif

    // MARK: - Path Drawing

    #if os(macOS)
    private static func drawPaths() {
        NSColor.black.setFill()

        let path1 = buildPath1()
        path1.fill()

        let path2 = buildPath2()
        path2.fill()
    }

    private static func buildPath1() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 200, y: 712))
        p.line(to: NSPoint(x: 116, y: 712))
        p.curve(to: NSPoint(x: 76, y: 686), controlPoint1: NSPoint(x: 98, y: 712), controlPoint2: NSPoint(x: 82, y: 694.667))
        p.curve(to: NSPoint(x: 73, y: 671), controlPoint1: NSPoint(x: 74, y: 681.333), controlPoint2: NSPoint(x: 73, y: 676.333))
        p.line(to: NSPoint(x: 73, y: 587))
        p.curve(to: NSPoint(x: 99, y: 549), controlPoint1: NSPoint(x: 73.667, y: 568.333), controlPoint2: NSPoint(x: 82.333, y: 555.667))
        p.line(to: NSPoint(x: 134, y: 538))
        p.curve(to: NSPoint(x: 140, y: 540), controlPoint1: NSPoint(x: 136.667, y: 537.333), controlPoint2: NSPoint(x: 138.667, y: 538))
        p.curve(to: NSPoint(x: 200, y: 576), controlPoint1: NSPoint(x: 155.333, y: 560.667), controlPoint2: NSPoint(x: 175.333, y: 572.667))
        p.line(to: NSPoint(x: 208, y: 577))
        p.line(to: NSPoint(x: 181, y: 558))
        p.curve(to: NSPoint(x: 140, y: 490), controlPoint1: NSPoint(x: 159, y: 540.667), controlPoint2: NSPoint(x: 145.333, y: 518))
        p.curve(to: NSPoint(x: 149, y: 421), controlPoint1: NSPoint(x: 136.667, y: 466), controlPoint2: NSPoint(x: 139.667, y: 443))
        p.curve(to: NSPoint(x: 171, y: 381), controlPoint1: NSPoint(x: 154.333, y: 406.333), controlPoint2: NSPoint(x: 161.667, y: 393))
        p.line(to: NSPoint(x: 247, y: 260))
        p.curve(to: NSPoint(x: 311, y: 161), controlPoint1: NSPoint(x: 267.667, y: 226.667), controlPoint2: NSPoint(x: 289, y: 194.333))
        appendArc(to: p, from: CGPoint(x: 311, y: 161), end: CGPoint(x: 491, y: 45), rx: 308, ry: 308, sweep: true)
        p.curve(to: NSPoint(x: 628, y: 61), controlPoint1: NSPoint(x: 538.333, y: 35.667), controlPoint2: NSPoint(x: 584, y: 41))
        p.curve(to: NSPoint(x: 640, y: 69), controlPoint1: NSPoint(x: 633.333, y: 63), controlPoint2: NSPoint(x: 637.333, y: 65.667))
        p.curve(to: NSPoint(x: 637, y: 95), controlPoint1: NSPoint(x: 649, y: 77), controlPoint2: NSPoint(x: 647, y: 89))
        p.line(to: NSPoint(x: 626, y: 100))
        p.curve(to: NSPoint(x: 596, y: 133), controlPoint1: NSPoint(x: 610.667, y: 106), controlPoint2: NSPoint(x: 600.667, y: 117))
        p.line(to: NSPoint(x: 592, y: 146))
        p.curve(to: NSPoint(x: 556, y: 179), controlPoint1: NSPoint(x: 586, y: 163.333), controlPoint2: NSPoint(x: 574, y: 174.333))
        p.line(to: NSPoint(x: 539, y: 185))
        p.curve(to: NSPoint(x: 528, y: 199), controlPoint1: NSPoint(x: 532.333, y: 187), controlPoint2: NSPoint(x: 528.667, y: 191.667))
        p.curve(to: NSPoint(x: 517, y: 230), controlPoint1: NSPoint(x: 526, y: 210), controlPoint2: NSPoint(x: 525, y: 221))
        p.curve(to: NSPoint(x: 499, y: 242), controlPoint1: NSPoint(x: 511.667, y: 234.667), controlPoint2: NSPoint(x: 505.667, y: 238.667))
        p.line(to: NSPoint(x: 493, y: 246))
        p.curve(to: NSPoint(x: 476, y: 269), controlPoint1: NSPoint(x: 483, y: 250), controlPoint2: NSPoint(x: 477.333, y: 257.667))
        p.curve(to: NSPoint(x: 460, y: 360), controlPoint1: NSPoint(x: 472, y: 299.667), controlPoint2: NSPoint(x: 466.667, y: 330))
        p.curve(to: NSPoint(x: 471, y: 400), controlPoint1: NSPoint(x: 457.333, y: 374.667), controlPoint2: NSPoint(x: 461, y: 388))
        p.curve(to: NSPoint(x: 497, y: 420), controlPoint1: NSPoint(x: 479, y: 407.333), controlPoint2: NSPoint(x: 487.667, y: 414))
        p.curve(to: NSPoint(x: 513, y: 440), controlPoint1: NSPoint(x: 505, y: 424.667), controlPoint2: NSPoint(x: 510.333, y: 431.333))
        p.curve(to: NSPoint(x: 504, y: 473), controlPoint1: NSPoint(x: 515.667, y: 453.333), controlPoint2: NSPoint(x: 512.667, y: 464.333))
        p.line(to: NSPoint(x: 455, y: 519))
        p.curve(to: NSPoint(x: 386, y: 570), controlPoint1: NSPoint(x: 434.333, y: 538.333), controlPoint2: NSPoint(x: 409.333, y: 555.333))
        p.curve(to: NSPoint(x: 315, y: 598), controlPoint1: NSPoint(x: 364, y: 584), controlPoint2: NSPoint(x: 338.333, y: 593.333))
        p.curve(to: NSPoint(x: 274, y: 599), controlPoint1: NSPoint(x: 301.667, y: 600.667), controlPoint2: NSPoint(x: 287.333, y: 601))
        p.curve(to: NSPoint(x: 268, y: 603), controlPoint1: NSPoint(x: 271.333, y: 598.333), controlPoint2: NSPoint(x: 269.333, y: 599.667))
        p.line(to: NSPoint(x: 240, y: 681))
        p.curve(to: NSPoint(x: 200, y: 712), controlPoint1: NSPoint(x: 233.333, y: 699.667), controlPoint2: NSPoint(x: 220, y: 710))
        return p
    }

    private static func buildPath2() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 615, y: 347))
        p.curve(to: NSPoint(x: 552, y: 414), controlPoint1: NSPoint(x: 594.333, y: 370.333), controlPoint2: NSPoint(x: 572.667, y: 392.667))
        p.curve(to: NSPoint(x: 532, y: 428), controlPoint1: NSPoint(x: 546.667, y: 419.333), controlPoint2: NSPoint(x: 540, y: 424))
        p.curve(to: NSPoint(x: 528, y: 427), controlPoint1: NSPoint(x: 530.667, y: 430), controlPoint2: NSPoint(x: 529.333, y: 429.667))
        p.curve(to: NSPoint(x: 498, y: 398), controlPoint1: NSPoint(x: 520.667, y: 415), controlPoint2: NSPoint(x: 510.667, y: 405.333))
        p.curve(to: NSPoint(x: 483, y: 385), controlPoint1: NSPoint(x: 492.667, y: 395.333), controlPoint2: NSPoint(x: 487.667, y: 391))
        p.curve(to: NSPoint(x: 479, y: 356), controlPoint1: NSPoint(x: 477.667, y: 375.667), controlPoint2: NSPoint(x: 476.333, y: 366))
        p.line(to: NSPoint(x: 491, y: 297))
        p.curve(to: NSPoint(x: 494, y: 292), controlPoint1: NSPoint(x: 491, y: 295), controlPoint2: NSPoint(x: 492, y: 293.333))
        p.curve(to: NSPoint(x: 531, y: 277), controlPoint1: NSPoint(x: 504.667, y: 282), controlPoint2: NSPoint(x: 517, y: 277))
        p.curve(to: NSPoint(x: 545, y: 270), controlPoint1: NSPoint(x: 537, y: 277), controlPoint2: NSPoint(x: 541.667, y: 274.333))
        p.curve(to: NSPoint(x: 601, y: 217), controlPoint1: NSPoint(x: 560, y: 248), controlPoint2: NSPoint(x: 581, y: 233))
        p.curve(to: NSPoint(x: 647, y: 171), controlPoint1: NSPoint(x: 619, y: 203.667), controlPoint2: NSPoint(x: 634.333, y: 188.333))
        p.curve(to: NSPoint(x: 664, y: 140), controlPoint1: NSPoint(x: 653.667, y: 161), controlPoint2: NSPoint(x: 659.333, y: 150.667))
        p.line(to: NSPoint(x: 667, y: 134))
        p.curve(to: NSPoint(x: 680, y: 135), controlPoint1: NSPoint(x: 670, y: 129), controlPoint2: NSPoint(x: 677, y: 130))
        p.curve(to: NSPoint(x: 687, y: 163), controlPoint1: NSPoint(x: 684, y: 143.667), controlPoint2: NSPoint(x: 686.333, y: 153))
        p.curve(to: NSPoint(x: 657, y: 286), controlPoint1: NSPoint(x: 692, y: 207), controlPoint2: NSPoint(x: 679, y: 247))
        p.curve(to: NSPoint(x: 615, y: 347), controlPoint1: NSPoint(x: 645, y: 306.667), controlPoint2: NSPoint(x: 631, y: 326.667))
        return p
    }
    #endif

    // MARK: - CoreGraphics (cross-platform)

    private static func drawPathsCG(_ ctx: CGContext) {
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))

        let path1 = CGMutablePath()
        path1.move(to: CGPoint(x: 200, y: 712))
        path1.addLine(to: CGPoint(x: 116, y: 712))
        path1.addCurve(to: CGPoint(x: 76, y: 686), control1: CGPoint(x: 98, y: 712), control2: CGPoint(x: 82, y: 694.667))
        path1.addCurve(to: CGPoint(x: 73, y: 671), control1: CGPoint(x: 74, y: 681.333), control2: CGPoint(x: 73, y: 676.333))
        path1.addLine(to: CGPoint(x: 73, y: 587))
        path1.addCurve(to: CGPoint(x: 99, y: 549), control1: CGPoint(x: 73.667, y: 568.333), control2: CGPoint(x: 82.333, y: 555.667))
        path1.addLine(to: CGPoint(x: 134, y: 538))
        path1.addCurve(to: CGPoint(x: 140, y: 540), control1: CGPoint(x: 136.667, y: 537.333), control2: CGPoint(x: 138.667, y: 538))
        path1.addCurve(to: CGPoint(x: 200, y: 576), control1: CGPoint(x: 155.333, y: 560.667), control2: CGPoint(x: 175.333, y: 572.667))
        path1.addLine(to: CGPoint(x: 208, y: 577))
        path1.addLine(to: CGPoint(x: 181, y: 558))
        path1.addCurve(to: CGPoint(x: 140, y: 490), control1: CGPoint(x: 159, y: 540.667), control2: CGPoint(x: 145.333, y: 518))
        path1.addCurve(to: CGPoint(x: 149, y: 421), control1: CGPoint(x: 136.667, y: 466), control2: CGPoint(x: 139.667, y: 443))
        path1.addCurve(to: CGPoint(x: 171, y: 381), control1: CGPoint(x: 154.333, y: 406.333), control2: CGPoint(x: 161.667, y: 393))
        path1.addLine(to: CGPoint(x: 247, y: 260))
        path1.addCurve(to: CGPoint(x: 311, y: 161), control1: CGPoint(x: 267.667, y: 226.667), control2: CGPoint(x: 289, y: 194.333))
        appendArcCG(to: path1, from: CGPoint(x: 311, y: 161), end: CGPoint(x: 491, y: 45), rx: 308, ry: 308, sweep: true)
        path1.addCurve(to: CGPoint(x: 628, y: 61), control1: CGPoint(x: 538.333, y: 35.667), control2: CGPoint(x: 584, y: 41))
        path1.addCurve(to: CGPoint(x: 640, y: 69), control1: CGPoint(x: 633.333, y: 63), control2: CGPoint(x: 637.333, y: 65.667))
        path1.addCurve(to: CGPoint(x: 637, y: 95), control1: CGPoint(x: 649, y: 77), control2: CGPoint(x: 647, y: 89))
        path1.addLine(to: CGPoint(x: 626, y: 100))
        path1.addCurve(to: CGPoint(x: 596, y: 133), control1: CGPoint(x: 610.667, y: 106), control2: CGPoint(x: 600.667, y: 117))
        path1.addLine(to: CGPoint(x: 592, y: 146))
        path1.addCurve(to: CGPoint(x: 556, y: 179), control1: CGPoint(x: 586, y: 163.333), control2: CGPoint(x: 574, y: 174.333))
        path1.addLine(to: CGPoint(x: 539, y: 185))
        path1.addCurve(to: CGPoint(x: 528, y: 199), control1: CGPoint(x: 532.333, y: 187), control2: CGPoint(x: 528.667, y: 191.667))
        path1.addCurve(to: CGPoint(x: 517, y: 230), control1: CGPoint(x: 526, y: 210), control2: CGPoint(x: 525, y: 221))
        path1.addCurve(to: CGPoint(x: 499, y: 242), control1: CGPoint(x: 511.667, y: 234.667), control2: CGPoint(x: 505.667, y: 238.667))
        path1.addLine(to: CGPoint(x: 493, y: 246))
        path1.addCurve(to: CGPoint(x: 476, y: 269), control1: CGPoint(x: 483, y: 250), control2: CGPoint(x: 477.333, y: 257.667))
        path1.addCurve(to: CGPoint(x: 460, y: 360), control1: CGPoint(x: 472, y: 299.667), control2: CGPoint(x: 466.667, y: 330))
        path1.addCurve(to: CGPoint(x: 471, y: 400), control1: CGPoint(x: 457.333, y: 374.667), control2: CGPoint(x: 461, y: 388))
        path1.addCurve(to: CGPoint(x: 497, y: 420), control1: CGPoint(x: 479, y: 407.333), control2: CGPoint(x: 487.667, y: 414))
        path1.addCurve(to: CGPoint(x: 513, y: 440), control1: CGPoint(x: 505, y: 424.667), control2: CGPoint(x: 510.333, y: 431.333))
        path1.addCurve(to: CGPoint(x: 504, y: 473), control1: CGPoint(x: 515.667, y: 453.333), control2: CGPoint(x: 512.667, y: 464.333))
        path1.addLine(to: CGPoint(x: 455, y: 519))
        path1.addCurve(to: CGPoint(x: 386, y: 570), control1: CGPoint(x: 434.333, y: 538.333), control2: CGPoint(x: 409.333, y: 555.333))
        path1.addCurve(to: CGPoint(x: 315, y: 598), control1: CGPoint(x: 364, y: 584), control2: CGPoint(x: 338.333, y: 593.333))
        path1.addCurve(to: CGPoint(x: 274, y: 599), control1: CGPoint(x: 301.667, y: 600.667), control2: CGPoint(x: 287.333, y: 601))
        path1.addCurve(to: CGPoint(x: 268, y: 603), control1: CGPoint(x: 271.333, y: 598.333), control2: CGPoint(x: 269.333, y: 599.667))
        path1.addLine(to: CGPoint(x: 240, y: 681))
        path1.addCurve(to: CGPoint(x: 200, y: 712), control1: CGPoint(x: 233.333, y: 699.667), control2: CGPoint(x: 220, y: 710))
        ctx.addPath(path1)
        ctx.fillPath()

        let path2 = CGMutablePath()
        path2.move(to: CGPoint(x: 615, y: 347))
        path2.addCurve(to: CGPoint(x: 552, y: 414), control1: CGPoint(x: 594.333, y: 370.333), control2: CGPoint(x: 572.667, y: 392.667))
        path2.addCurve(to: CGPoint(x: 532, y: 428), control1: CGPoint(x: 546.667, y: 419.333), control2: CGPoint(x: 540, y: 424))
        path2.addCurve(to: CGPoint(x: 528, y: 427), control1: CGPoint(x: 530.667, y: 430), control2: CGPoint(x: 529.333, y: 429.667))
        path2.addCurve(to: CGPoint(x: 498, y: 398), control1: CGPoint(x: 520.667, y: 415), control2: CGPoint(x: 510.667, y: 405.333))
        path2.addCurve(to: CGPoint(x: 483, y: 385), control1: CGPoint(x: 492.667, y: 395.333), control2: CGPoint(x: 487.667, y: 391))
        path2.addCurve(to: CGPoint(x: 479, y: 356), control1: CGPoint(x: 477.667, y: 375.667), control2: CGPoint(x: 476.333, y: 366))
        path2.addLine(to: CGPoint(x: 491, y: 297))
        path2.addCurve(to: CGPoint(x: 494, y: 292), control1: CGPoint(x: 491, y: 295), control2: CGPoint(x: 492, y: 293.333))
        path2.addCurve(to: CGPoint(x: 531, y: 277), control1: CGPoint(x: 504.667, y: 282), control2: CGPoint(x: 517, y: 277))
        path2.addCurve(to: CGPoint(x: 545, y: 270), control1: CGPoint(x: 537, y: 277), control2: CGPoint(x: 541.667, y: 274.333))
        path2.addCurve(to: CGPoint(x: 601, y: 217), control1: CGPoint(x: 560, y: 248), control2: CGPoint(x: 581, y: 233))
        path2.addCurve(to: CGPoint(x: 647, y: 171), control1: CGPoint(x: 619, y: 203.667), control2: CGPoint(x: 634.333, y: 188.333))
        path2.addCurve(to: CGPoint(x: 664, y: 140), control1: CGPoint(x: 653.667, y: 161), control2: CGPoint(x: 659.333, y: 150.667))
        path2.addLine(to: CGPoint(x: 667, y: 134))
        path2.addCurve(to: CGPoint(x: 680, y: 135), control1: CGPoint(x: 670, y: 129), control2: CGPoint(x: 677, y: 130))
        path2.addCurve(to: CGPoint(x: 687, y: 163), control1: CGPoint(x: 684, y: 143.667), control2: CGPoint(x: 686.333, y: 153))
        path2.addCurve(to: CGPoint(x: 657, y: 286), control1: CGPoint(x: 692, y: 207), control2: CGPoint(x: 679, y: 247))
        path2.addCurve(to: CGPoint(x: 615, y: 347), control1: CGPoint(x: 645, y: 306.667), control2: CGPoint(x: 631, y: 326.667))
        ctx.addPath(path2)
        ctx.fillPath()
    }

    // MARK: - SVG Arc Approximation

    #if os(macOS)
    private static func appendArc(to path: NSBezierPath, from start: CGPoint, end: CGPoint, rx: Double, ry: Double, sweep: Bool) {
        let x1p = (start.x - end.x) / 2, y1p = (start.y - end.y) / 2
        var rxA = rx, ryA = ry
        let lambda = (x1p * x1p) / (rxA * rxA) + (y1p * y1p) / (ryA * ryA)
        if lambda > 1 { let s = sqrt(lambda); rxA *= s; ryA *= s }
        let rxAs = rxA * rxA, ryAs = ryA * ryA, x1ps = x1p * x1p, y1ps = y1p * y1p
        let sq = sqrt(max(0, (rxAs * ryAs - rxAs * y1ps - ryAs * x1ps) / (rxAs * y1ps + ryAs * x1ps)))
        let sign: Double = sweep ? 1 : -1
        let cxp = sign * sq * (rxA * y1p / ryA)
        let cyp = sign * sq * (-(ryA * x1p / rxA))
        let cx = cxp + (start.x + end.x) / 2, cy = cyp + (start.y + end.y) / 2
        let theta1 = atan2((y1p - cyp) / ryA, (x1p - cxp) / rxA)
        var dTheta = atan2((-y1p - cyp) / ryA, (-x1p - cxp) / rxA) - theta1
        if sweep && dTheta < 0 { dTheta += 2 * .pi }
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        let segs = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let seg = dTheta / Double(segs)
        let a = sin(seg) * (sqrt(4 + 3 * pow(tan(seg / 2), 2)) - 1) / 3
        var t = theta1, px = cx + rxA * cos(t), py = cy + ryA * sin(t)
        for _ in 0..<segs {
            let dx1 = -rxA * sin(t), dy1 = ryA * cos(t)
            let tN = t + seg
            let ex = cx + rxA * cos(tN), ey = cy + ryA * sin(tN)
            let dx2 = -rxA * sin(tN), dy2 = ryA * cos(tN)
            path.curve(to: NSPoint(x: ex, y: ey),
                controlPoint1: NSPoint(x: px + a * dx1, y: py + a * dy1),
                controlPoint2: NSPoint(x: ex - a * dx2, y: ey - a * dy2))
            px = ex; py = ey; t = tN
        }
    }
    #endif

    private static func appendArcCG(to path: CGMutablePath, from start: CGPoint, end: CGPoint, rx: Double, ry: Double, sweep: Bool) {
        let x1p = (start.x - end.x) / 2, y1p = (start.y - end.y) / 2
        var rxA = rx, ryA = ry
        let lambda = (x1p * x1p) / (rxA * rxA) + (y1p * y1p) / (ryA * ryA)
        if lambda > 1 { let s = sqrt(lambda); rxA *= s; ryA *= s }
        let rxAs = rxA * rxA, ryAs = ryA * ryA, x1ps = x1p * x1p, y1ps = y1p * y1p
        let sq = sqrt(max(0, (rxAs * ryAs - rxAs * y1ps - ryAs * x1ps) / (rxAs * y1ps + ryAs * x1ps)))
        let sign: Double = sweep ? 1 : -1
        let cxp = sign * sq * (rxA * y1p / ryA)
        let cyp = sign * sq * (-(ryA * x1p / rxA))
        let cx = cxp + (start.x + end.x) / 2, cy = cyp + (start.y + end.y) / 2
        let theta1 = atan2((y1p - cyp) / ryA, (x1p - cxp) / rxA)
        var dTheta = atan2((-y1p - cyp) / ryA, (-x1p - cxp) / rxA) - theta1
        if sweep && dTheta < 0 { dTheta += 2 * .pi }
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        let segs = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let seg = dTheta / Double(segs)
        let a = sin(seg) * (sqrt(4 + 3 * pow(tan(seg / 2), 2)) - 1) / 3
        var t = theta1, px = cx + rxA * cos(t), py = cy + ryA * sin(t)
        for _ in 0..<segs {
            let dx1 = -rxA * sin(t), dy1 = ryA * cos(t)
            let tN = t + seg
            let ex = cx + rxA * cos(tN), ey = cy + ryA * sin(tN)
            let dx2 = -rxA * sin(tN), dy2 = ryA * cos(tN)
            path.addCurve(to: CGPoint(x: ex, y: ey),
                control1: CGPoint(x: px + a * dx1, y: py + a * dy1),
                control2: CGPoint(x: ex - a * dx2, y: ey - a * dy2))
            px = ex; py = ey; t = tN
        }
    }
}
