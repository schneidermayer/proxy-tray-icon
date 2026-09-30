import Cocoa
import OSLog

enum ConnectionLossAlert {
    private static let logger = Logger(subsystem: "net.hsch.proxytray", category: "Connection")

    static func present(message: String, cleanupErrors: [String]) {
        var details = message
        if !cleanupErrors.isEmpty {
            details += "\n\nRestoring previous proxy settings failed:\n" + cleanupErrors.joined(separator: "\n")
        }

        logger.error("SSH connection lost")
        for line in details.components(separatedBy: .newlines) where !line.isEmpty {
            logger.error("\(line, privacy: .public)")
        }

        let alert = makeAlert(details: details, cleanupFailed: !cleanupErrors.isEmpty)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(details, forType: .string)
        }
    }

    static func makeAlert(details: String, cleanupFailed: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "SSH connection lost"
        alert.informativeText = cleanupFailed
            ? "The tunnel closed unexpectedly. Some previous proxy settings could not be restored; check the details below and your network proxy settings."
            : "The tunnel closed unexpectedly and ProxyTray's network changes have been reverted. Choose Enable Proxy from the menu to reconnect."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Details")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let contentSize = scrollView.contentSize
        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.size = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = details
        scrollView.documentView = textView
        alert.accessoryView = scrollView
        return alert
    }
}
