import Cocoa

enum IconFactory {
    static func icon(active: Bool) -> NSImage {
        return active ? filledIcon(alpha: 1.0) : filledIcon(alpha: 0.4)
    }

    private static func filledIcon(alpha: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 9, y: 18))
            path.curve(to: NSPoint(x: 0, y: 15.75), controlPoint1: NSPoint(x: 4.03, y: 18), controlPoint2: NSPoint(x: 0, y: 17.5))
            path.line(to: NSPoint(x: 0, y: 5.25))
            path.curve(to: NSPoint(x: 9, y: 0), controlPoint1: NSPoint(x: 0, y: 2.25), controlPoint2: NSPoint(x: 4.03, y: 0))
            path.curve(to: NSPoint(x: 18, y: 5.25), controlPoint1: NSPoint(x: 13.97, y: 0), controlPoint2: NSPoint(x: 18, y: 2.25))
            path.line(to: NSPoint(x: 18, y: 15.75))
            path.curve(to: NSPoint(x: 9, y: 18), controlPoint1: NSPoint(x: 18, y: 17.5), controlPoint2: NSPoint(x: 13.97, y: 18))
            path.close()

            NSColor.black.withAlphaComponent(alpha).setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
