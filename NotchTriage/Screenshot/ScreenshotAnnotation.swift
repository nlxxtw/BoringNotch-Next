import AppKit

enum ScreenshotTool: String, CaseIterable, Identifiable {
    case move, rect, ellipse, arrow, pen, mosaic, text
    var id: String { rawValue }

    var title: String {
        switch self {
        case .move: return "移动"
        case .rect: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .mosaic: return "马赛克"
        case .text: return "文字"
        }
    }

    var symbol: String {
        switch self {
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .rect: return "rectangle"
        case .ellipse: return "oval"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil"
        case .mosaic: return "squareshape.squareshape.dashed"
        case .text: return "textformat"
        }
    }

    var drawsAnnotation: Bool {
        switch self {
        case .move, .text: return false
        default: return true
        }
    }
}

enum ScreenshotAnnotation {
    case rect(CGRect, NSColor, CGFloat)
    case ellipse(CGRect, NSColor, CGFloat)
    case arrow(CGPoint, CGPoint, NSColor, CGFloat)
    case pen([CGPoint], NSColor, CGFloat)
    case mosaic(CGRect)
    case text(CGPoint, String, NSColor, CGFloat)
}

enum ScreenshotAnnotationRenderer {
    /// Annotations use selection-local coords with top-left origin (flipped view).
    static func render(
        base: CGImage,
        annotations: [ScreenshotAnnotation],
        selectionSize: CGSize
    ) -> CGImage {
        let w = base.width
        let h = base.height
        let space = base.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return base }

        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        let sx = CGFloat(w) / max(selectionSize.width, 1)
        let sy = CGFloat(h) / max(selectionSize.height, 1)

        for ann in annotations {
            switch ann {
            case let .rect(r, c, lw):
                ctx.setStrokeColor(c.cgColor)
                ctx.setLineWidth(lw * sx)
                ctx.stroke(scale(r, sx, sy))
            case let .ellipse(r, c, lw):
                ctx.setStrokeColor(c.cgColor)
                ctx.setLineWidth(lw * sx)
                ctx.strokeEllipse(in: scale(r, sx, sy))
            case let .arrow(a, b, c, lw):
                drawArrow(
                    ctx,
                    from: CGPoint(x: a.x * sx, y: a.y * sy),
                    to: CGPoint(x: b.x * sx, y: b.y * sy),
                    color: c,
                    width: lw * sx
                )
            case let .pen(pts, c, lw):
                guard pts.count > 1 else { continue }
                ctx.setStrokeColor(c.cgColor)
                ctx.setLineWidth(lw * sx)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: pts[0].x * sx, y: pts[0].y * sy))
                for p in pts.dropFirst() {
                    ctx.addLine(to: CGPoint(x: p.x * sx, y: p.y * sy))
                }
                ctx.strokePath()
            case let .mosaic(r):
                applyMosaic(ctx: ctx, base: base, rect: scale(r, sx, sy), imageHeight: h)
            case let .text(origin, string, c, size):
                let fontSize = max(8, size * sx)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: c
                ]
                let ns = NSAttributedString(string: string, attributes: attrs)
                ctx.saveGState()
                ctx.interpolationQuality = .high
                ctx.scaleBy(x: 1, y: -1)
                ns.draw(at: NSPoint(x: origin.x * sx, y: -(origin.y * sy + fontSize)))
                ctx.restoreGState()
            }
        }
        return ctx.makeImage() ?? base
    }

    private static func scale(_ r: CGRect, _ sx: CGFloat, _ sy: CGFloat) -> CGRect {
        CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy)
    }

    private static func drawArrow(
        _ ctx: CGContext, from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat
    ) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.move(to: from)
        ctx.addLine(to: to)
        ctx.strokePath()
        let angle = atan2(to.y - from.y, to.x - from.x)
        let head = max(10, width * 4)
        let p1 = CGPoint(x: to.x - head * cos(angle - .pi / 7), y: to.y - head * sin(angle - .pi / 7))
        let p2 = CGPoint(x: to.x - head * cos(angle + .pi / 7), y: to.y - head * sin(angle + .pi / 7))
        ctx.beginPath()
        ctx.move(to: to)
        ctx.addLine(to: p1)
        ctx.addLine(to: p2)
        ctx.closePath()
        ctx.fillPath()
    }

    private static func applyMosaic(ctx: CGContext, base: CGImage, rect: CGRect, imageHeight: Int) {
        // `rect` is already in the renderer's flipped (top-left) space.
        let drawRect = rect.integral
        guard drawRect.width > 2, drawRect.height > 2 else { return }

        let cropRect = CGRect(
            x: drawRect.minX,
            y: CGFloat(imageHeight) - drawRect.maxY,
            width: drawRect.width,
            height: drawRect.height
        ).integral
        guard cropRect.width > 2, cropRect.height > 2,
              let cropped = base.cropping(to: cropRect) else {
            ctx.setFillColor(NSColor.darkGray.withAlphaComponent(0.85).cgColor)
            ctx.fill(drawRect)
            return
        }

        let block = max(8, min(24, min(drawRect.width, drawRect.height) / 10))
        let sw = max(1, Int(ceil(drawRect.width / block)))
        let sh = max(1, Int(ceil(drawRect.height / block)))
        let space = base.colorSpace ?? CGColorSpaceCreateDeviceRGB()

        guard let small = CGContext(
            data: nil, width: sw, height: sh,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        small.interpolationQuality = .none
        small.draw(cropped, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let tiny = small.makeImage() else { return }

        // Annotation CTM is already y-flipped to top-left; draw without another flip.
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.draw(tiny, in: drawRect)
        ctx.restoreGState()
    }
}
