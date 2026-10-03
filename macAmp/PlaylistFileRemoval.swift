import AppKit
import Darwin
import Foundation

/// An explicit, immutable allowlist. No directory enumeration, CUE FILE path
/// traversal, recursive removal, or permanent-delete fallback is permitted.
enum PlaylistFileRemoval {
    struct Entry {
        let url: URL
        let sheetURL: URL?
        let selected: Bool
    }

    struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
    }

    struct File {
        let url: URL
        let accessURL: URL
        let identity: Identity
        let parentIdentity: Identity
        let local: Bool
        var audioPaths = Set<String>()
        var sheetPaths = Set<String>()
    }

    struct Plan {
        let files: [File]
        let skippedURLs: Int
    }

    struct Outcome {
        var audioPaths = Set<String>()
        var sheetPaths = Set<String>()
        var completed = 0
        var error: Error?
    }

    struct Failure: LocalizedError {
        let url: URL
        let reason: String
        var errorDescription: String? { "\(url.path)\n\n\(reason)" }
    }

    private static func posixError(_ url: URL) -> Failure {
        let code = errno
        return Failure(url: url, reason: String(cString: strerror(code)))
    }

    private static func openParent(of url: URL) throws -> Int32 {
        // Walk a previously canonicalized absolute parent from the root with
        // O_NOFOLLOW at EVERY component. A replaced ancestor cannot redirect
        // deletion into another directory. Descriptors are bounded and closed.
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(url) }
        for component in url.deletingLastPathComponent().pathComponents.dropFirst() {
            guard component != ".", component != "..", !component.contains("/") else {
                close(descriptor)
                throw Failure(url: url, reason: "Unsafe directory path.")
            }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let error = posixError(url)
                close(descriptor)
                throw error
            }
            close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    private static func inspect(_ url: URL, parent: Int32) throws -> (stat, stat, Bool) {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.utf8.contains(0) else {
            throw Failure(url: url, reason: "Unsafe file name.")
        }
        var directory = stat()
        var item = stat()
        var volume = statfs()
        guard fstat(parent, &directory) == 0,
              fstatat(parent, name, &item, AT_SYMLINK_NOFOLLOW) == 0,
              fstatfs(parent, &volume) == 0 else { throw posixError(url) }
        guard (item.st_mode & S_IFMT) == S_IFREG else {
            throw Failure(url: url, reason: "Only regular files are allowed. Folders, symbolic links and special files will not be removed.")
        }
        return (item, directory, (volume.f_flags & UInt32(MNT_LOCAL)) != 0)
    }

    static func prepare(_ entries: [Entry]) throws -> Plan {
        var files: [File] = []
        var indices: [String: Int] = [:]
        let selected = entries.filter(\.selected)
        var knownSheets: [String: Set<URL>] = [:]
        for entry in entries where entry.url.isFileURL {
            if let sheet = entry.sheetURL {
                knownSheets[entry.url.standardizedFileURL.path, default: []].insert(sheet)
            }
        }

        func append(_ source: URL, accessURL: URL, audioPath: String? = nil, sheetPath: String? = nil) throws {
            guard source.isFileURL, source.host == nil || source.host == "" || source.host == "localhost",
                  !source.path.utf8.contains(0) else {
                throw Failure(url: source, reason: "Only files on mounted volumes are allowed.")
            }
            // Resolve the parent only; never follow the selected file itself.
            let url = source.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(source.lastPathComponent, isDirectory: false)
            let index: Int
            if let existing = indices[url.path] {
                index = existing
            } else {
                let parent = try openParent(of: url)
                defer { close(parent) }
                let (item, directory, local) = try inspect(url, parent: parent)
                index = files.count
                indices[url.path] = index
                files.append(File(url: url, accessURL: accessURL, identity: Identity(item),
                                  parentIdentity: Identity(directory), local: local))
            }
            if let audioPath { files[index].audioPaths.insert(audioPath) }
            if let sheetPath { files[index].sheetPaths.insert(sheetPath) }
        }

        var processedAudio = Set<String>()
        for entry in selected where entry.url.isFileURL {
            let audio = entry.url.standardizedFileURL
            guard processedAudio.insert(audio.path).inserted else { continue }
            let scoped = entry.url.startAccessingSecurityScopedResource()
            defer { if scoped { entry.url.stopAccessingSecurityScopedResource() } }
            try append(audio, accessURL: entry.url, audioPath: audio.path)

            let tracks = CueSheet.tracks(for: entry.url)
            let discoveredSheet = tracks?.first?.segment.sheetURL.standardizedFileURL
            var sheets = knownSheets[audio.path] ?? []
            if let discoveredSheet { sheets.insert(discoveredSheet) }
            for source in sheets.sorted(by: { $0.path < $1.path }) {
                let sheet = source.standardizedFileURL
                // Only the sidecar names actually supported by the reader are
                // eligible. Never turn arbitrary persisted CUE paths or FILE
                // directives into additional deletion targets.
                let candidates = [audio.deletingPathExtension().appendingPathExtension("cue"),
                                  audio.appendingPathExtension("cue")]
                guard sheet.isFileURL, candidates.contains(sheet), discoveredSheet == sheet else {
                    throw Failure(url: sheet, reason: "The CUE sidecar could not be verified for the selected audio file. No files have been changed.")
                }
                try append(sheet, accessURL: entry.url, sheetPath: sheet.path)
            }
        }
        return Plan(files: files, skippedURLs: selected.filter { !$0.url.isFileURL }.count)
    }

    static func execute(_ plan: Plan) -> Outcome {
        var outcome = Outcome()
        for file in plan.files {
            let scoped = file.accessURL.startAccessingSecurityScopedResource()
            defer { if scoped { file.accessURL.stopAccessingSecurityScopedResource() } }
            do {
                let parent = try openParent(of: file.url)
                defer { close(parent) }
                let (item, directory, local) = try inspect(file.url, parent: parent)
                guard Identity(item) == file.identity, Identity(directory) == file.parentIdentity,
                      local == file.local else {
                    throw Failure(url: file.url, reason: "The file, containing directory or volume changed after confirmation. Nothing else will be removed.")
                }
                if local {
                    // Native Trash only. Failure MUST NOT fall back to unlink.
                    try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                } else {
                    // unlinkat with flags=0 cannot remove a directory and never
                    // recurses. The parent descriptor fixes the deletion scope.
                    guard unlinkat(parent, file.url.lastPathComponent, 0) == 0 else {
                        throw posixError(file.url)
                    }
                }
                outcome.audioPaths.formUnion(file.audioPaths)
                outcome.sheetPaths.formUnion(file.sheetPaths)
                outcome.completed += 1
            } catch {
                outcome.error = Failure(url: file.url, reason: error.localizedDescription)
                break // No further targets after the first failure.
            }
        }
        return outcome
    }

    static func confirmation(for plan: Plan) -> NSAlert {
        let localCount = plan.files.filter(\.local).count
        let networkCount = plan.files.count - localCount
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move selected files to Trash?"
        alert.informativeText = "Local files: \(localCount) — move to Trash; you can restore them in Finder.\nNetwork files: \(networkCount) — permanently delete from the mounted network volume.\nURLs skipped: \(plan.skippedURLs)."
        // Cancellation is the default Return action; destructive work requires
        // the specifically labelled second button.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: networkCount == 0 ? "Move to Trash" : "Move to Trash / Delete Network Files")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        return alert
    }
}
