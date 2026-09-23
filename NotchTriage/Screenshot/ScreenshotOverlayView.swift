import AppKit

/// Live dim overlay — select on the real desktop (no freeze bitmap → no mirror).
final class ScreenshotOverlayView: NSView, NSTextFieldDelegate {
    let scaleFactor: CGFloat
    let displayID: CGDirectDisplayID
    weak var state: ScreenshotOverlayState?
    weak var controller: ScreenshotOverlayController?

    private enum DragMode {
        case none, creating, moving, resizing(ResizeHandle), annotating
    }

    private enum ResizeHandle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private var dragMode: DragMode = .none
    private var dragStart: CGPoint = .zero
    private var selectionAtDragStart: CGRect = .zero
    private var draftPoints: [CGPoint] = []
    private var draftStart: CGPoint = .zero

    private var textEditor: NSTextField?
    private var textOriginInSelection: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(displayID: CGDirectDisplayID, scaleFactor: CGFloat) {
        self.displayID = displayID
        self.scaleFactor = scaleFactor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsScale = scaleFactor
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var ownsSelection: Bool { state?.selectionDisplayID == displayID }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        // Live desktop shows through — only paint a dim mask with a clear hole.
        if ownsSelection, let sel = state?.selection, sel.width > 1, sel.height > 1 {
            ctx.saveGState()
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.addRect(bounds)
            ctx.addRect(sel)
            ctx.clip(using: .evenOdd)
            ctx.fill(bounds)
            ctx.restoreGState()

            // Draw the captured Retina crop into the hole so export/preview match 1:1.
            if let crop = state?.replacementCrop {
                drawCapturedCrop(crop, in: sel)
            }

            ctx.setStrokeColor(NSColor.systemCyan.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(sel)

            let label = "\(Int(sel.width.rounded())) × \(Int(sel.height.rounded()))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let size = label.size(withAttributes: attrs)
            let lr = CGRect(
                x: sel.minX,
                y: max(4, sel.minY - size.height - 6),
                width: size.width + 10,
                height: size.height + 4
            )
            NSColor.black.withAlphaComponent(0.65).setFill()
            NSBezierPath(roundedRect: lr, xRadius: 4, yRadius: 4).fill()
            label.draw(at: CGPoint(x: lr.minX + 5, y: lr.minY + 2), withAttributes: attrs)

            if state?.replacementCrop != nil {
                drawAnnotations(in: sel, ctx: ctx)
            }
            drawHandles(sel)
        } else {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.fill(bounds)
        }

        if case .annotating = dragMode, ownsSelection, let sel = state?.selection {
            drawDraft(in: sel, ctx: ctx)
        }
    }

    private func drawCapturedCrop(_ crop: CGImage, in sel: CGRect) {
        // Draw CGImage directly — avoids NSImage resampling soft-blur on Retina.
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.clip(to: sel)
        // View is flipped (top-left); CGImage draw expects bottom-left unless we flip.
        ctx.translateBy(x: sel.minX, y: sel.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: sel.width, height: sel.height))
        ctx.restoreGState()
    }

    private func drawAnnotations(in sel: CGRect, ctx: CGContext) {
        guard let anns = state?.annotations else { return }
        ctx.saveGState()
        ctx.clip(to: sel)
        for ann in anns {
            drawOne(ann, origin: sel.origin, ctx: ctx)
        }
        ctx.restoreGState()
    }

    private func drawOne(_ ann: ScreenshotAnnotation, origin: CGPoint, ctx: CGContext) {
        switch ann {
        case let .rect(r, c, w):
            ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(w)
            ctx.stroke(r.offsetBy(dx: origin.x, dy: origin.y))
        case let .ellipse(r, c, w):
            ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(w)
            ctx.strokeEllipse(in: r.offsetBy(dx: origin.x, dy: origin.y))
        case let .arrow(a, b, c, w):
            arrow(from: CGPoint(x: a.x + origin.x, y: a.y + origin.y),
                  to: CGPoint(x: b.x + origin.x, y: b.y + origin.y), color: c, width: w, ctx: ctx)
        case let .pen(pts, c, w):
            guard pts.count > 1 else { return }
            ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(w); ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: pts[0].x + origin.x, y: pts[0].y + origin.y))
            for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.x + origin.x, y: p.y + origin.y)) }
            ctx.strokePath()
        case let .mosaic(r):
            let dest = r.offsetBy(dx: origin.x, dy: origin.y)
            if let crop = state?.replacementCrop,
               let sel = state?.selection {
                drawLiveMosaic(
                    from: crop,
                    selectionSize: sel.size,
                    localRect: r,
                    dest: dest,
                    ctx: ctx
                )
            } else {
                NSColor.darkGray.withAlphaComponent(0.8).setFill()
                NSBezierPath(rect: dest).fill()
            }
        case let .text(p, s, c, size):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: c
            ]
            s.draw(at: CGPoint(x: p.x + origin.x, y: p.y + origin.y), withAttributes: attrs)
        }
    }

    private func drawDraft(in sel: CGRect, ctx: CGContext) {
        guard let state else { return }
        let a = CGPoint(x: draftStart.x - sel.minX, y: draftStart.y - sel.minY)
        let cur = draftPoints.last ?? draftStart
        let b = CGPoint(x: cur.x - sel.minX, y: cur.y - sel.minY)
        let color = state.strokeColor
        let w = state.lineWidth
        switch state.tool {
        case .rect:
            ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(w)
            ctx.stroke(CGRect(point: a, and: b).offsetBy(dx: sel.minX, dy: sel.minY))
        case .mosaic:
            let dest = CGRect(point: a, and: b).offsetBy(dx: sel.minX, dy: sel.minY)
            if let crop = state.replacementCrop {
                let local = CGRect(point: a, and: b)
                drawLiveMosaic(
                    from: crop,
                    selectionSize: sel.size,
                    localRect: local,
                    dest: dest,
                    ctx: ctx
                )
            } else {
                ctx.setFillColor(NSColor.darkGray.withAlphaComponent(0.75).cgColor)
                ctx.fill(dest)
            }
        case .ellipse:
            ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(w)
            ctx.strokeEllipse(in: CGRect(point: a, and: b).offsetBy(dx: sel.minX, dy: sel.minY))
        case .arrow:
            arrow(from: draftStart, to: cur, color: color, width: w, ctx: ctx)
        case .pen:
            guard draftPoints.count > 1 else { return }
            ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(w); ctx.setLineCap(.round)
            ctx.beginPath(); ctx.move(to: draftPoints[0])
            for p in draftPoints.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .text:
            break
        case .move:
            break
        }
    }

    private func drawLiveMosaic(
        from crop: CGImage,
        selectionSize: CGSize,
        localRect: CGRect,
        dest: CGRect,
        ctx: CGContext
    ) {
        let pixel = ScreenshotPixelMath.pixelRect(
            viewRect: localRect,
            imageWidth: crop.width,
            imageHeight: crop.height,
            viewSize: selectionSize
        )
        guard pixel.width > 1, pixel.height > 1,
              let piece = crop.cropping(to: pixel) else {
            ctx.setFillColor(NSColor.darkGray.withAlphaComponent(0.8).cgColor)
            ctx.fill(dest)
            return
        }
        let block = max(6, min(18, min(dest.width, dest.height) / 8))
        let sw = max(1, Int(ceil(dest.width / block)))
        let sh = max(1, Int(ceil(dest.height / block)))
        let space = crop.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let small = CGContext(
            data: nil, width: sw, height: sh,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        small.interpolationQuality = .none
        small.draw(piece, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let tiny = small.makeImage() else { return }
        let preview = NSImage(cgImage: tiny, size: dest.size)
        NSGraphicsContext.current?.imageInterpolation = .none
        preview.draw(in: dest, from: .zero, operation: .copy, fraction: 1)
    }

    private func arrow(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat, ctx: CGContext) {
        ctx.setStrokeColor(color.cgColor); ctx.setFillColor(color.cgColor); ctx.setLineWidth(width)
        ctx.beginPath(); ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()
        let angle = atan2(to.y - from.y, to.x - from.x)
        let head = max(10, width * 4)
        let p1 = CGPoint(x: to.x - head * cos(angle - .pi / 7), y: to.y - head * sin(angle - .pi / 7))
        let p2 = CGPoint(x: to.x - head * cos(angle + .pi / 7), y: to.y - head * sin(angle + .pi / 7))
        ctx.beginPath(); ctx.move(to: to); ctx.addLine(to: p1); ctx.addLine(to: p2); ctx.closePath(); ctx.fillPath()
    }

    private func drawHandles(_ sel: CGRect) {
        for h in ResizeHandle.allCases {
            let p = handlePoint(h, in: sel)
            let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor.systemCyan.setStroke()
            NSBezierPath(ovalIn: r).stroke()
        }
    }

    private func handlePoint(_ h: ResizeHandle, in sel: CGRect) -> CGPoint {
        switch h {
        case .topLeft: return CGPoint(x: sel.minX, y: sel.minY)
        case .top: return CGPoint(x: sel.midX, y: sel.minY)
        case .topRight: return CGPoint(x: sel.maxX, y: sel.minY)
        case .right: return CGPoint(x: sel.maxX, y: sel.midY)
        case .bottomRight: return CGPoint(x: sel.maxX, y: sel.maxY)
        case .bottom: return CGPoint(x: sel.midX, y: sel.maxY)
        case .bottomLeft: return CGPoint(x: sel.minX, y: sel.maxY)
        case .left: return CGPoint(x: sel.minX, y: sel.midY)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let state, state.phase != .longShot else { return }

        if state.phase == .selecting || state.selection == nil || !ownsSelection {
            beginCreate(at: p)
            return
        }
        guard var sel = state.selection else { return }

        if let handle = hitHandle(p, in: sel) {
            dragMode = .resizing(handle)
            dragStart = p
            selectionAtDragStart = sel
            return
        }
        if sel.insetBy(dx: -2, dy: -2).contains(p) {
            if event.clickCount >= 2 {
                state.finish()
                return
            }
            guard state.replacementCrop != nil else {
                dragMode = .moving
                dragStart = p
                selectionAtDragStart = sel
                return
            }
            if state.tool != .text {
                commitInlineText(discardEmpty: true)
            }
            if state.tool == .text {
                beginInlineText(at: p, in: sel)
                return
            }
            // Default / 移动: drag selection. Drawing tools only annotate when chosen.
            if state.tool == .move || !state.tool.drawsAnnotation {
                dragMode = .moving
                dragStart = p
                selectionAtDragStart = sel
                return
            }
            dragMode = .annotating
            draftStart = p
            draftPoints = [p]
            return
        }
        beginCreate(at: p)
        _ = sel
    }

    private func beginCreate(at p: CGPoint) {
        guard let state else { return }
        commitInlineText(discardEmpty: true)
        dragMode = .creating
        dragStart = p
        state.selectionDisplayID = displayID
        state.selection = CGRect(origin: p, size: .zero)
        state.annotations = []
        state.replacementCrop = nil
        state.phase = .selecting
        state.onHideAllChrome?()
        needsDisplay = true
        NotificationCenter.default.post(name: .screenshotOverlayNeedsDisplay, object: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let state else { return }
        switch dragMode {
        case .creating:
            state.selection = CGRect(point: dragStart, and: p)
            needsDisplay = true
        case .moving:
            var sel = selectionAtDragStart
            sel.origin.x += p.x - dragStart.x
            sel.origin.y += p.y - dragStart.y
            state.selection = clamp(sel)
            state.replacementCrop = nil
            state.phase = .selecting
            state.onHideAllChrome?()
            needsDisplay = true
        case .resizing(let handle):
            state.selection = clamp(resize(selectionAtDragStart, handle: handle, to: p))
            state.replacementCrop = nil
            state.phase = .selecting
            state.onHideAllChrome?()
            needsDisplay = true
        case .annotating:
            draftPoints.append(p)
            needsDisplay = true
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer {
            dragMode = .none
            draftPoints = []
            needsDisplay = true
        }
        guard let state else { return }
        switch dragMode {
        case .creating:
            var sel = CGRect(point: dragStart, and: p)
            if sel.width < 4 || sel.height < 4 {
                state.selection = nil
                state.phase = .selecting
                state.onHideAllChrome?()
                return
            }
            sel = clamp(sel)
            state.selection = sel
            controller?.finalizeSelectionForEdit()
        case .moving, .resizing(_):
            if state.selection != nil {
                controller?.finalizeSelectionForEdit()
            }
        case .annotating:
            commitAnnotation(end: p)
        case .none:
            break
        }
    }

    private func commitAnnotation(end: CGPoint) {
        guard let state, let sel = state.selection else { return }
        let toLocal: (CGPoint) -> CGPoint = { CGPoint(x: $0.x - sel.minX, y: $0.y - sel.minY) }
        let a = toLocal(draftStart)
        let b = toLocal(end)
        let c = state.strokeColor
        let w = state.lineWidth
        switch state.tool {
        case .rect: state.addAnnotation(.rect(CGRect(point: a, and: b), c, w))
        case .ellipse: state.addAnnotation(.ellipse(CGRect(point: a, and: b), c, w))
        case .arrow: state.addAnnotation(.arrow(a, b, c, w))
        case .pen: state.addAnnotation(.pen(draftPoints.map(toLocal), c, w))
        case .mosaic: state.addAnnotation(.mosaic(CGRect(point: a, and: b)))
        case .text, .move: break
        }
    }

    private func beginInlineText(at p: CGPoint, in sel: CGRect) {
        guard let state else { return }
        commitInlineText(discardEmpty: true)

        let local = CGPoint(x: p.x - sel.minX, y: p.y - sel.minY)
        textOriginInSelection = local

        let fontSize = state.textFontSize
        let field = NSTextField(frame: NSRect(
            x: p.x,
            y: p.y,
            width: max(120, min(280, sel.maxX - p.x - 8)),
            height: fontSize + 14
        ))
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = NSColor.black.withAlphaComponent(0.18)
        field.textColor = state.strokeColor
        field.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        field.placeholderString = "输入文字"
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.wantsLayer = true
        field.layer?.borderWidth = 1.5
        field.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        field.layer?.cornerRadius = 3

        addSubview(field)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(field)
        textEditor = field
    }

    @discardableResult
    func commitInlineText(discardEmpty: Bool = false) -> Bool {
        guard let field = textEditor, let state, let origin = textOriginInSelection else {
            return false
        }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        field.removeFromSuperview()
        textEditor = nil
        textOriginInSelection = nil

        if text.isEmpty {
            return !discardEmpty
        }
        state.addAnnotation(.text(origin, text, state.strokeColor, state.textFontSize))
        needsDisplay = true
        return true
    }

    func syncInlineTextStyle() {
        guard let field = textEditor, let state else { return }
        field.textColor = state.strokeColor
        field.font = NSFont.systemFont(ofSize: state.textFontSize, weight: .semibold)
        var frame = field.frame
        frame.size.height = state.textFontSize + 14
        field.frame = frame
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitInlineText(discardEmpty: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            textEditor?.stringValue = ""
            commitInlineText(discardEmpty: true)
            return true
        }
        return false
    }

    private func hitHandle(_ p: CGPoint, in sel: CGRect) -> ResizeHandle? {
        for h in ResizeHandle.allCases {
            let hp = handlePoint(h, in: sel)
            if abs(hp.x - p.x) <= 8 && abs(hp.y - p.y) <= 8 { return h }
        }
        return nil
    }

    private func resize(_ sel: CGRect, handle: ResizeHandle, to p: CGPoint) -> CGRect {
        var r = sel
        switch handle {
        case .topLeft:
            r.origin = p; r.size.width = sel.maxX - p.x; r.size.height = sel.maxY - p.y
        case .top:
            r.origin.y = p.y; r.size.height = sel.maxY - p.y
        case .topRight:
            r.origin.y = p.y; r.size.width = p.x - sel.minX; r.size.height = sel.maxY - p.y
        case .right:
            r.size.width = p.x - sel.minX
        case .bottomRight:
            r.size.width = p.x - sel.minX; r.size.height = p.y - sel.minY
        case .bottom:
            r.size.height = p.y - sel.minY
        case .bottomLeft:
            r.origin.x = p.x; r.size.width = sel.maxX - p.x; r.size.height = p.y - sel.minY
        case .left:
            r.origin.x = p.x; r.size.width = sel.maxX - p.x
        }
        r.size.width = max(4, r.size.width)
        r.size.height = max(4, r.size.height)
        return r
    }

    private func clamp(_ sel: CGRect) -> CGRect {
        var r = sel
        r.origin.x = max(0, min(r.origin.x, bounds.width - 4))
        r.origin.y = max(0, min(r.origin.y, bounds.height - 4))
        r.size.width = min(r.width, bounds.width - r.origin.x)
        r.size.height = min(r.height, bounds.height - r.origin.y)
        r = CGRect(
            x: floor(r.minX),
            y: floor(r.minY),
            width: max(1, floor(r.width)),
            height: max(1, floor(r.height))
        )
        if r.maxX > bounds.width {
            r.size.width = max(1, bounds.width - r.origin.x)
        }
        if r.maxY > bounds.height {
            r.size.height = max(1, bounds.height - r.origin.y)
        }
        return r
    }

    func refresh() {
        syncInlineTextStyle()
        needsDisplay = true
    }
}

private extension CGRect {
    init(point a: CGPoint, and b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

extension Notification.Name {
    static let screenshotOverlayNeedsDisplay = Notification.Name("notch.screenshot.overlayNeedsDisplay")
}
