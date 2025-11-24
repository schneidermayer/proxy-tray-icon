import Cocoa

enum IconFactory {
    static func icon(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        drawBackground(in: NSRect(origin: .zero, size: size), active: active)
        drawSymbol(in: NSRect(origin: .zero, size: size), active: active)
        image.unlockFocus()
        image.isTemplate = false
        image.size = size
        if !active {
            image.lockFocus()
            NSGraphicsContext.current?.compositingOperation = .sourceAtop
            NSColor(calibratedWhite: 1.0, alpha: 0.5).set()
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
            image.unlockFocus()
        }
        return image
    }

    private static func drawBackground(in rect: NSRect, active: Bool) {
        // Background stays transparent; only the white glyph is rendered.
        NSColor.clear.setFill()
        NSBezierPath(rect: rect).fill()
    }

    private static func drawSymbol(in rect: NSRect, active: Bool) {
        let glyphAlpha: CGFloat = active ? 1.0 : 0.4
        let color = NSColor.white.withAlphaComponent(glyphAlpha)

        let bounds = rect.insetBy(dx: 3.6, dy: 3.6)
        let shaft = NSBezierPath()
        shaft.move(to: NSPoint(x: bounds.minX, y: bounds.midY))
        shaft.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.midY))
        color.setStroke()
        shaft.lineWidth = 1.6
        shaft.lineCapStyle = .round
        shaft.stroke()

        // arrow head
        let tip = NSPoint(x: bounds.maxX, y: bounds.midY)
        let head = NSBezierPath()
        head.move(to: tip)
        head.line(to: NSPoint(x: tip.x - 2.6, y: tip.y + 2.0))
        head.line(to: NSPoint(x: tip.x - 2.6, y: tip.y - 2.0))
        head.close()
        color.setFill()
        head.fill()

        // subtle start node (hollow dot)
        let nodeRect = NSRect(x: bounds.minX - 1.6, y: bounds.midY - 1.6, width: 3.2, height: 3.2)
        let node = NSBezierPath(ovalIn: nodeRect)
        node.lineWidth = 1.4
        color.setStroke()
        node.stroke()
    }
}
