import AppKit

/// Notices an image being dragged anywhere on screen, out of any app, so the
/// line can come down for it at the top edge the way it does for the pointer.
///
/// Every drag writes to the system's drag pasteboard as it starts. Watching
/// the mouse from outside needs no permission, and only what kind of thing is
/// being dragged is read, never the image itself, until it is dropped on the
/// line.
@MainActor
final class DragWatcher {
    private(set) var isActive = false

    private let pasteboard = NSPasteboard(name: .drag)
    /// The drag pasteboard as it was when the button went down. A drag that
    /// starts afterwards changes it.
    private var seenCount: Int
    private var lastLook = Date.distantPast
    private var monitors: [Any] = []
    private let onStart: () -> Void
    private let onEnd: () -> Void

    init(onStart: @escaping () -> Void, onEnd: @escaping () -> Void) {
        self.onStart = onStart
        self.onEnd = onEnd
        seenCount = pasteboard.changeCount
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch event.type {
                case .leftMouseDown: self.seenCount = self.pasteboard.changeCount
                case .leftMouseDragged: self.dragged()
                case .leftMouseUp: self.end()
                default: break
                }
            }
        }
        // Global monitors only see other apps' events, so photos dragged off
        // the line itself never count.
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp], handler: handler) {
            monitors.append(monitor)
        }
    }

    private func dragged() {
        guard !isActive else { return }
        // A drag only writes the pasteboard once it gets going. A look every
        // few frames is plenty, and keeps moving windows or selecting text cheap.
        let now = Date()
        guard now.timeIntervalSince(lastLook) >= 0.05 else { return }
        lastLook = now
        let count = pasteboard.changeCount
        guard count != seenCount else { return }
        seenCount = count
        guard DropIn.canAccept(pasteboard) else { return }
        isActive = true
        onStart()
    }

    /// The button went up. Also called when the line notices the button is
    /// no longer down, in case the release went unheard.
    func end() {
        guard isActive else { return }
        isActive = false
        onEnd()
    }
}
