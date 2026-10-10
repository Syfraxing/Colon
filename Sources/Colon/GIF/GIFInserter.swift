import AppKit
import Carbon.HIToolbox
import ColonCore

/// Pastes a GIF into the frontmost app: GIF data plus a file URL on the pasteboard, a synthetic
/// ⌘V, then the user's previous pasteboard comes back.
@MainActor
enum GIFInserter {
    static let gifType = NSPasteboard.PasteboardType("com.compuserve.gif")
    /// Long enough for slow apps (Mail, Electron) to read the pasteboard after ⌘V.
    static let restoreDelay: TimeInterval = 1.0
    /// Temp copies older than this are removed on the next insert.
    static let tempFileLifetime: TimeInterval = 10 * 60

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Colon-GIFs", isDirectory: true)

    private static var savedPasteboard: [NSPasteboardItem]?
    private static var pasteboardChangeCount = 0
    private static var restoreWork: DispatchWorkItem?

    /// Writes `data` to a fresh temp file named after the GIF. The name never includes the query.
    static func writeTemporaryFile(_ data: Data, named fileName: String) throws -> URL {
        removeStaleFiles()
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Puts the GIF on the pasteboard. With `paste`, sends ⌘V to the frontmost app and restores the
    /// previous pasteboard after `restoreDelay`; without, leaves it there for the user to paste.
    static func insert(_ data: Data, fileURL: URL, paste: Bool) {
        let pasteboard = NSPasteboard.general
        restoreWork?.cancel()
        restoreWork = nil
        if paste, savedPasteboard == nil {
            savedPasteboard = snapshot(pasteboard)
        }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(data, forType: gifType)
        item.setString(fileURL.absoluteString, forType: .fileURL)
        if paste { item.setData(Data(), forType: transientType) }
        pasteboard.writeObjects([item])
        pasteboardChangeCount = pasteboard.changeCount
        guard paste else {
            savedPasteboard = nil
            return
        }

        let keyCode = KeyLayout.keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        SyntheticEvent.keyPress(keyCode, flags: .maskCommand).forEach { $0.post(tap: .cghidEventTap) }

        let work = DispatchWorkItem {
            MainActor.assumeIsolated { restorePasteboard() }
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: work)
    }

    /// Removes every temp copy (launch, quit).
    static func removeAllFiles() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Private

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func restorePasteboard() {
        defer {
            savedPasteboard = nil
            restoreWork = nil
        }
        let pasteboard = NSPasteboard.general
        // If something else wrote to the pasteboard meanwhile (the user copied), keep that.
        guard pasteboard.changeCount == pasteboardChangeCount, let saved = savedPasteboard else { return }
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
    }

    private static func removeStaleFiles() {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey],
                                                             options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date().addingTimeInterval(-tempFileLifetime)
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff { try? manager.removeItem(at: folder) }
        }
    }
}
