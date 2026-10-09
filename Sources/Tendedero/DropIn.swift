import AppKit
import UniformTypeIdentifiers

/// Images dragged onto the line from anywhere else: a file from Finder, a
/// photo from Photos, a picture from a web page. Each one is copied into
/// Tendedero's own folder and hangs like a screenshot. The original never
/// moves, and discarding it from the line only throws the copy away.
enum DropIn {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tendedero/Dropped", isDirectory: true)
    }()

    /// Image data for drags that carry a picture but no file, like some
    /// images from web pages, with the extension each is saved with. TIFF is
    /// saved as PNG, which is smaller and opens everywhere.
    private static let dataTypes: [(type: NSPasteboard.PasteboardType, ext: String)] = [
        (.png, "png"),
        (NSPasteboard.PasteboardType(UTType.jpeg.identifier), "jpg"),
        (NSPasteboard.PasteboardType(UTType.heic.identifier), "heic"),
        (.tiff, "png"),
    ]

    /// Everything the line listens for.
    static var draggedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL]
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
            + dataTypes.map(\.type)
    }

    private static let imageFilesOnly: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    /// Whether a drag carries at least one image. Only what kind of thing is
    /// being dragged is read here, never the image itself.
    static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: imageFilesOnly)
            || !imagePromises(on: pasteboard).isEmpty
            || pasteboard.availableType(from: dataTypes.map(\.type)) != nil
    }

    /// Takes the images out of a drop and hands each one back, on the main
    /// thread, as a file in Tendedero's folder. Must be called while the drop
    /// is being performed, when the drag can still be read.
    /// Returns false when there was no image to take.
    static func receive(_ pasteboard: NSPasteboard, each: @escaping (URL) -> Void) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: imageFilesOnly) as? [URL],
           !files.isEmpty {
            work.async {
                for file in files {
                    guard let copy = copy(file) else { continue }
                    DispatchQueue.main.async { each(copy) }
                }
            }
            return true
        }

        let promises = imagePromises(on: pasteboard)
        if !promises.isEmpty {
            for promise in promises { receive(promise, each: each) }
            return true
        }

        if let type = pasteboard.availableType(from: dataTypes.map(\.type)),
           let data = pasteboard.data(forType: type) {
            work.async {
                guard let file = write(data, type: type) else { return }
                DispatchQueue.main.async { each(file) }
            }
            return true
        }
        return false
    }

    // MARK: Files

    private static let work = DispatchQueue(label: "app.tendedero.drop-in", qos: .userInitiated)

    private static func copy(_ file: URL) -> URL? {
        // Already one of ours, like a screenshot from the inbox: it hangs as it is.
        if isOurs(file) { return file }
        let target = uniqueURL(in: folder, for: file.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: file, to: target)
            log.notice("Dropped in \(file.lastPathComponent, privacy: .public)")
            return target
        } catch {
            log.error("Could not copy \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func write(_ data: Data, type: NSPasteboard.PasteboardType) -> URL? {
        guard let ext = dataTypes.first(where: { $0.type == type })?.ext else { return nil }
        var bytes = data
        if type == .tiff {
            guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return nil }
            bytes = png
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let target = uniqueURL(in: folder, for: "Image \(stamp.string(from: Date())).\(ext)")
        do {
            try bytes.write(to: target, options: .withoutOverwriting)
            log.notice("Dropped in image data as \(target.lastPathComponent, privacy: .public)")
            return target
        } catch {
            log.error("Could not save dropped image: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Whether a file already lives in one of Tendedero's own folders.
    static func isOurs(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return [folder, Inbox.folder].contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    // MARK: Promises

    /// Apps like Photos promise a file and only write it once it is dropped.
    private static func imagePromises(on pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        return receivers.filter { $0.fileTypes.contains(where: isImageType) }
    }

    /// Promised types are usually type identifiers, and file extensions in
    /// older apps.
    private static func isImageType(_ name: String) -> Bool {
        (UTType(name) ?? UTType(filenameExtension: name))?.conforms(to: .image) ?? false
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Each promise is written into a folder of its own in the temporary
    /// directory, so names never clash, then moved in next to the others.
    private static func receive(_ promise: NSFilePromiseReceiver, each: @escaping (URL) -> Void) {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("Tendedero-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            log.error("Could not make a folder for a promised file: \(error.localizedDescription, privacy: .public)")
            return
        }
        var handled = 0
        promise.receivePromisedFiles(atDestination: staging, options: [:], operationQueue: promiseQueue) { file, error in
            defer {
                handled += 1
                if handled >= promise.fileNames.count { try? fm.removeItem(at: staging) }
            }
            if let error {
                log.error("A promised file did not arrive: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let type = try? file.resourceValues(forKeys: [.contentTypeKey]).contentType,
                  type.conforms(to: .image) else { return }
            let target = uniqueURL(in: folder, for: file.lastPathComponent)
            do {
                try fm.moveItem(at: file, to: target)
                log.notice("Dropped in promised \(target.lastPathComponent, privacy: .public)")
                DispatchQueue.main.async { each(target) }
            } catch {
                log.error("Could not keep a promised file: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// The panel's content: it holds the line, and catches images dragged onto
/// it from other apps while the line is down. The rest of the time the panel
/// lets the mouse through, so it never gets in the way of other drags.
final class LineDropView: NSView {
    /// Whether an image the line can take is over it.
    var onTarget: (Bool) -> Void = { _ in }
    /// The drop, with the frame of the dragged picture where it was let go,
    /// in screen coordinates, when the drag reports it.
    var onDrop: (NSPasteboard, CGRect?) -> Bool = { _, _ in false }

    private var verdict: (sequence: Int, accepts: Bool)?

    init(content: NSView) {
        super.init(frame: .zero)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        registerForDraggedTypes(DropIn.draggedTypes)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Asked once per drag. A photo dragged off the line itself is turned
    /// away, so letting it go over the line still sends it back to its place.
    private func accepts(_ info: NSDraggingInfo) -> Bool {
        if let verdict, verdict.sequence == info.draggingSequenceNumber { return verdict.accepts }
        let accepts = info.draggingSource == nil && DropIn.canAccept(info.draggingPasteboard)
        verdict = (info.draggingSequenceNumber, accepts)
        return accepts
    }

    private func respond(_ info: NSDraggingInfo) -> NSDragOperation {
        let ok = accepts(info)
        onTarget(ok)
        return ok ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { respond(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { respond(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { onTarget(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onTarget(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        var frame: CGRect?
        sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self],
                                      searchOptions: [:]) { item, _, stop in
            frame = item.draggingFrame
            stop.pointee = true
        }
        let onScreen = frame.flatMap { f -> CGRect? in
            guard f.width > 2, f.height > 2, let window else { return nil }
            return window.convertToScreen(convert(f, to: nil))
        }
        return onDrop(sender.draggingPasteboard, onScreen)
    }
}
