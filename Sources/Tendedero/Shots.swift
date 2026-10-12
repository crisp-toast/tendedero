import AppKit
import SwiftUI

/// A new screenshot waits in the middle of the screen until you decide where
/// it goes. Drag it to the menu bar and let go on the line to hang it there,
/// or drag it anywhere else to send it there. A click opens it, and the cross
/// moves it to the Trash. Nothing reaches the line unless you drag it there.
/// Screenshots taken in a row pile up, the newest on top.
@MainActor
final class Shots {
    private let line: Line
    private var waiting: [Shot] = []
    /// A screenshot is being dragged from the middle of the screen, so the
    /// line can come down for it.
    var onDragChanged: (Bool) -> Void = { _ in }

    init(line: Line) {
        self.line = line
    }

    /// Shows a new screenshot in the middle of the screen it was taken on,
    /// lifting off from where it was captured when that is known.
    func show(_ url: URL, from capture: CGRect?) {
        guard !waiting.contains(where: { $0.url == url }),
              let image = makeThumbnail(url, maxPixels: 1600) else { return }
        let center = capture.map { CGPoint(x: $0.midX, y: $0.midY) }
        let screen = center.flatMap { c in NSScreen.screens.first { NSMouseInRect(c, $0.frame, false) } }
            ?? LinePanel.screenUnderPointer()
        guard let screen else { return }
        let slot = (waiting.map(\.slot).max() ?? -1) + 1
        let shot = Shot(url: url, image: image, slot: slot)
        configure(shot)
        waiting.append(shot)
        shot.present(on: screen, from: capture)
    }

    /// The line took it. It goes away once the drag is over.
    func hung(_ url: URL) {
        waiting.first { $0.url == url }?.hung = true
    }

    /// Screenshots whose file was deleted or moved away go away by themselves.
    func prune() {
        for shot in waiting where !FileManager.default.fileExists(atPath: shot.url.path) {
            dismiss(shot)
        }
    }

    /// After editing in Markup, the waiting screenshot shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let shot = waiting.first(where: { $0.url == url }),
              let image = makeThumbnail(url, maxPixels: 1600) else { return }
        shot.model.image = image
        shot.grab.dragImage = image
    }

    private func configure(_ shot: Shot) {
        let url = shot.url
        let line = line
        let grab = shot.grab
        grab.url = url
        grab.dragImage = shot.model.image
        grab.hangsOnLine = true
        grab.dragImageMaxSide = 200
        grab.onClick = { [weak self, weak shot] in
            NSWorkspace.shared.open(url)
            if let shot { self?.dismiss(shot) }
        }
        grab.onLongPress = { Markup.shared.edit(url) }
        grab.onPressChange = { [weak shot] pressed in shot?.model.pressed = pressed }
        grab.onDragStart = { [weak self, weak shot] in
            shot?.model.dragging = true
            self?.onDragChanged(true)
        }
        grab.onDragEnd = { [weak self, weak shot] in
            shot?.model.dragging = false
            self?.onDragChanged(false)
        }
        grab.onHandOff = { [weak self, weak shot] in
            guard let self, let shot else { return }
            // Let go anywhere but the line, it went where you took it.
            if !shot.hung { line.release(url) }
            self.dismiss(shot)
        }
        grab.onTrash = { [weak self, weak shot] in if let shot { self?.trash(shot) } }
        grab.onDiscard = grab.onTrash
        grab.menuProvider = { [weak self, weak shot] in
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(L("Copy")) { line.copyImage(url) })
            menu.addItem(ClosureMenuItem(L("Open")) {
                NSWorkspace.shared.open(url)
                if let shot { self?.dismiss(shot) }
            })
            menu.addItem(ClosureMenuItem(L("Markup")) { Markup.shared.edit(url) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Move to Trash")) { if let shot { self?.trash(shot) } })
            return menu
        }
    }

    private func trash(_ shot: Shot) {
        do {
            try FileManager.default.trashItem(at: shot.url, resultingItemURL: nil)
            log.notice("Trashed \(shot.url.lastPathComponent, privacy: .public)")
            if line.soundOn { Line.trashSound?.play() }
        } catch {
            log.error("Could not trash \(shot.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
        dismiss(shot)
    }

    private func dismiss(_ shot: Shot) {
        guard let i = waiting.firstIndex(where: { $0 === shot }) else { return }
        waiting.remove(at: i)
        shot.close()
    }
}

/// One screenshot waiting in the middle of the screen: its own small window,
/// the card drawn in SwiftUI, and the grab view on top for the mouse.
@MainActor
private final class Shot {
    let url: URL
    /// Its place in the pile. Each one sits a little lower and to the right.
    let slot: Int
    let model: ShotModel
    let grab = GrabView()
    private let panel: ShotPanel
    var hung = false

    init(url: URL, image: NSImage, slot: Int) {
        self.url = url
        self.slot = slot
        model = ShotModel(image: image)
        let host = NSHostingView(rootView: ShotCard(model: model))
        host.sizingOptions = []
        panel = ShotPanel(content: ShotContentView(host: host, grab: grab))
    }

    func present(on screen: NSScreen, from capture: CGRect?) {
        let target = ShotLayout.frame(for: model.image.size, on: screen, slot: slot)
        // From the capture, the photo starts exactly where it was taken.
        let edge = ShotLayout.margin + Frame.inset
        let start = capture?.insetBy(dx: -edge, dy: -edge)
            ?? target.insetBy(dx: target.width * 0.04, dy: target.height * 0.04)
        panel.setFrame(start, display: false)
        panel.alphaValue = capture == nil ? 0 : 1
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = capture == nil ? 0.22 : 0.45
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        let panel = panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

@MainActor
private final class ShotModel: ObservableObject {
    @Published var image: NSImage
    @Published var dragging = false
    @Published var pressed = false

    init(image: NSImage) { self.image = image }
}

enum ShotLayout {
    /// Room around the card for its shadow.
    static let margin: CGFloat = 32
    /// How far each screenshot in a pile sits from the one before.
    static let pileStep: CGFloat = 26

    /// Large enough to see what it is, small enough to leave the screen
    /// usable. A tiny capture is still big enough to grab.
    static func photoSize(for image: NSSize, on screen: NSScreen) -> NSSize {
        guard image.width > 0, image.height > 0 else { return NSSize(width: 320, height: 200) }
        let visible = screen.visibleFrame
        let natural = NSSize(width: image.width / screen.backingScaleFactor,
                             height: image.height / screen.backingScaleFactor)
        let maxW = min(560, visible.width * 0.45), maxH = min(420, visible.height * 0.45)
        let fit = min(maxW / natural.width, maxH / natural.height)
        var scale = min(fit, 1)
        let longest = max(natural.width, natural.height) * scale
        if longest < 180 { scale = min(fit, 180 / max(natural.width, natural.height)) }
        return NSSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }

    /// The window for a screenshot: centered on the screen, nudged down and
    /// to the right by its place in the pile.
    static func frame(for image: NSSize, on screen: NSScreen, slot: Int) -> NSRect {
        let photo = photoSize(for: image, on: screen)
        let card = NSSize(width: photo.width + Frame.inset * 2, height: photo.height + Frame.inset * 2)
        let visible = screen.visibleFrame
        let step = CGFloat(slot % 6) * pileStep
        let rect = NSRect(x: (visible.midX - card.width / 2 + step).rounded(),
                          y: (visible.midY - card.height / 2 - step).rounded(),
                          width: card.width, height: card.height)
        return rect.insetBy(dx: -margin, dy: -margin)
    }
}

/// The glass card, like a photo on the line but bigger and without a clip.
/// The cross is always there: it is the way to throw the screenshot away.
private struct ShotCard: View {
    @ObservedObject var model: ShotModel

    var body: some View {
        Image(nsImage: model.image)
            .resizable()
            .interpolation(.high)
            .clipShape(RoundedRectangle(cornerRadius: Frame.radius - Frame.inset, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Frame.radius - Frame.inset, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .padding(Frame.inset)
            .glassFrame(cornerRadius: Frame.radius)
            .overlay(alignment: .topLeading) {
                // Drawn here, clicked through GrabView, which sits on top.
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 20, height: 20)
                    .glassFrame(circle: true)
                    .padding(3)
            }
            .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
            .scaleEffect(model.pressed ? 0.97 : 1)
            .animation(model.pressed ? .easeInOut(duration: 0.45) : .spring(response: 0.3, dampingFraction: 0.6),
                       value: model.pressed)
            // While it is being dragged, only a ghost stays behind.
            .opacity(model.dragging ? 0.3 : 1)
            .animation(.easeOut(duration: 0.15), value: model.dragging)
            .padding(ShotLayout.margin)
            .allowsHitTesting(false)
    }
}

/// Lays out the card and the grab view over it, which follows the card
/// exactly while the window grows from the capture.
private final class ShotContentView: NSView {
    private let host: NSView
    private let grab: NSView

    init(host: NSView, grab: NSView) {
        self.host = host
        self.grab = grab
        super.init(frame: .zero)
        addSubview(host)
        addSubview(grab)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        host.frame = bounds
        grab.frame = bounds.insetBy(dx: ShotLayout.margin, dy: ShotLayout.margin)
    }
}

/// A small window that floats over every app, full screen ones included,
/// and never takes focus.
private final class ShotPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
