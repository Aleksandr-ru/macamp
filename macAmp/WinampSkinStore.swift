import AppKit
import Combine

/// Imports a classic Winamp `.wsz` archive. A `.wsz` is a ZIP containing BMP assets;
/// the extracted files are kept in Application Support for the renderer to consume.
final class WinampSkinStore: ObservableObject {
    struct PlaylistColors {
        let normalText: NSColor
        let currentText: NSColor
        let background: NSColor
        let selectedBackground: NSColor
    }
    @Published private(set) var name = "CLASSIC"
    @Published private(set) var status = "NO TRACK — LOAD A WINAMP .WSZ SKIN"
    @Published private(set) var visualizationPalette: [NSColor] = WinampSkinStore.defaultVisualizationPalette
    private(set) var extractedDirectory: URL?
    /// Source sheets are immutable for a loaded skin. Keep each decoded BMP in
    /// memory; reopening and case-insensitively scanning the skin directory on
    /// every SwiftUI body pass was the dominant rendering cost.
    private var bitmapCache: [String: NSImage] = [:]
    private var skinFileURLCache: [String: URL] = [:]
    /// A valid skin may intentionally omit optional resources. Remember those
    /// misses too, so a redraw never rescans its directory for the same name.
    private var missingSkinFiles: Set<String> = []
    /// Cursors are requested while SwiftUI rebuilds title/resize areas. Keep
    /// the decoded image and cursor object just like the bitmap sheets; disk
    /// I/O here directly delays input processing.
    private var cursorCache: [String: NSCursor] = [:]
    private var timeDigitCache: [Int: NSImage] = [:]
    private var positionBarCache: [String: NSImage] = [:]
    private var volumeBarCache: [Int: NSImage] = [:]
    private var volumeThumbCache: [Bool: NSImage] = [:]
    private var balanceBarCache: [Int: NSImage] = [:]
    private var balanceThumbCache: [Bool: NSImage] = [:]
    private var windowToggleCache: [String: NSImage] = [:]
    private var textDigitCache: [Int: NSImage] = [:]
    private var visualizationGlyphCache: [Character: NSImage] = [:]
    private var playerControlCache: [String: NSImage] = [:]
    private var playbackToggleCache: [String: NSImage] = [:]
    private var channelIndicatorCache: [String: NSImage] = [:]
    private var titleBarCache: [String: NSImage] = [:]
    private var titleBarControlCache: [String: NSImage] = [:]
    private var clutterbarCache: [String: NSImage] = [:]
    private var playbackIndicatorCache: [String: NSImage] = [:]
    private var windowShadePositionCache: [Int: NSImage] = [:]
    private var windowShadeMinusCache: NSImage?
    private var windowShadeTimeCache: [String: NSImage] = [:]
    private var equalizerSliderCache: [String: NSImage] = [:]
    private var playlistTimeCache: [String: NSImage] = [:]
    private var playlistWindowShadeTrackCache: [String: NSImage] = [:]
    private var playlistColorsCache: PlaylistColors?

    enum WindowToggle {
        case equalizer
        case playlist
    }

    enum PlayerControl: Equatable {
        case previous
        case play
        case pause
        case stop
        case next
        case eject
    }

    enum PlaybackToggle {
        case shuffle
        case repeatTrack
    }

    enum TitleBarControl {
        case minimize
        case windowShade
        case close
    }

    enum EqualizerTitleControl { case windowShade, close }

    enum PlaybackIndicator: String {
        case play
        case pause
        case stop
        /// Winamp draw_playicon(8): play glyph with the red lost-sync lamp.
        case lostSync
    }

    init() {
        loadBundledDefaultSkin()
    }

    func chooseArchive() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["wsz", "zip"]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let archive = panel.url else {
            status = "SKIN IMPORT CANCELLED"
            return
        }

        do {
            try extract(archive)
            name = archive.deletingPathExtension().lastPathComponent
            status = "SKIN LOADED — \(name.uppercased())"
        } catch {
            status = "INVALID WINAMP SKIN"
        }
    }

    private func loadBundledDefaultSkin() {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("DefaultSkin", isDirectory: true),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("MAIN.BMP").path) else {
            status = "DEFAULT SKIN NOT FOUND"
            return
        }
        extractedDirectory = directory
        clearImageCaches()
        name = "WINAMP CLASSIC 2.91"
        status = "DEFAULT WINAMP 2.91 SKIN"
        visualizationPalette = loadVisualizationPalette(from: directory)
    }

    private func extract(_ archive: URL) throws {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
            .appendingPathComponent("macAmp/Skins", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", archive.path, destination.path]
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw SkinError.invalidArchive }

        let files = try FileManager.default.contentsOfDirectory(at: destination,
                                                                 includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])
        guard files.contains(where: { $0.lastPathComponent.caseInsensitiveCompare("main.bmp") == .orderedSame }) else {
            throw SkinError.missingMainBitmap
        }
        extractedDirectory = destination
        visualizationPalette = loadVisualizationPalette(from: destination)
        clearImageCaches()
    }

    private func clearImageCaches() {
        bitmapCache.removeAll()
        skinFileURLCache.removeAll()
        missingSkinFiles.removeAll()
        cursorCache.removeAll()
        timeDigitCache.removeAll()
        positionBarCache.removeAll()
        volumeBarCache.removeAll()
        volumeThumbCache.removeAll()
        balanceBarCache.removeAll()
        balanceThumbCache.removeAll()
        windowToggleCache.removeAll()
        textDigitCache.removeAll()
        visualizationGlyphCache.removeAll()
        playerControlCache.removeAll()
        playbackToggleCache.removeAll()
        channelIndicatorCache.removeAll()
        titleBarCache.removeAll()
        titleBarControlCache.removeAll()
        clutterbarCache.removeAll()
        playbackIndicatorCache.removeAll()
        windowShadePositionCache.removeAll()
        windowShadeMinusCache = nil
        windowShadeTimeCache.removeAll()
        equalizerSliderCache.removeAll()
        playlistTimeCache.removeAll()
        playlistWindowShadeTrackCache.removeAll()
        playlistColorsCache = nil
    }

    func bitmap(named filename: String) -> NSImage? {
        guard let directory = extractedDirectory else { return nil }
        let key = filename.lowercased()
        if let cached = bitmapCache[key] { return cached }
        if missingSkinFiles.contains(key) { return nil }
        let url: URL
        if let cachedURL = skinFileURLCache[key] {
            url = cachedURL
        } else {
            let directURL = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: directURL.path) {
                url = directURL
            } else {
                guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                                includingPropertiesForKeys: nil),
                      let match = files.first(where: { $0.lastPathComponent.caseInsensitiveCompare(filename) == .orderedSame }) else {
                    missingSkinFiles.insert(key)
                    return nil
                }
                url = match
            }
            skinFileURLCache[key] = url
        }
        guard let image = NSImage(contentsOf: url) else {
            missingSkinFiles.insert(key)
            return nil
        }
        bitmapCache[key] = image
        return image
    }

    /// Exact generic-dialog compositor from Winamp's draw_embed.cpp.
    /// GEN.BMP has a 20 px title bar, tiled 29 px side rails, and a 38 px
    /// lower frame; none of these sprites is scaled with the content.
    func genericWindowImage(width: Int, height: Int, isActive: Bool) -> NSImage? {
        guard width >= 125, height >= 58,
              let sheet = bitmap(named: "GEN.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        func sprite(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> NSImage? {
            guard x >= 0, y >= 0, x + w <= source.width, y + h <= source.height,
                  let crop = source.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else { return nil }
            return NSImage(cgImage: crop, size: NSSize(width: w, height: h))
        }
        func draw(_ image: NSImage?, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            image?.draw(in: NSRect(x: x, y: y, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
        }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSColor.black.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

        let stateY = isActive ? 0 : 21
        let title = genericTitleGlyphImage("Info", isActive: isActive)
        let exactTextWidth = Int(title?.size.width ?? 0)
        // The title field is a skin resource, not a fixed macOS title label.
        // It must be wide enough for the actual GEN.BMP glyph sequence.
        let textWidth = min(width - 100, max(25, exactTextWidth))
        var x = 0
        draw(sprite(0, stateY, 25, 20), 0, CGFloat(height - 20), 25, 20); x += 25
        var sideTiles = max(0, (width - 100 - textWidth) / 25)
        if sideTiles % 2 == 1 { draw(sprite(104, stateY, 12, 20), CGFloat(x), CGFloat(height - 20), 12, 20); x += 12 }
        sideTiles /= 2
        for _ in 0..<sideTiles { draw(sprite(104, stateY, 25, 20), CGFloat(x), CGFloat(height - 20), 25, 20); x += 25 }
        draw(sprite(26, stateY, 25, 20), CGFloat(x), CGFloat(height - 20), 25, 20); x += 25
        let titleStart = x
        var titleTiles = textWidth / 25
        while titleTiles > 0 { draw(sprite(52, stateY, 25, 20), CGFloat(x), CGFloat(height - 20), 25, 20); x += 25; titleTiles -= 1 }
        let titleRemainder = textWidth % 25
        if titleRemainder > 0 {
            draw(sprite(52, stateY, titleRemainder, 20), CGFloat(x), CGFloat(height - 20), CGFloat(titleRemainder), 20)
            x += titleRemainder
        }
        // draw_embed_tbar(): the text sits 4 px below the title bar's top
        // edge (therefore height−11 in AppKit's bottom-left coordinates).
        // It is centred inside its dedicated 25-px title field, preserving
        // the native left and right field tiles.
        if let title {
            let textX = titleStart + (textWidth - exactTextWidth) / 2
            draw(title, CGFloat(textX), CGFloat(height - 11), title.size.width, 7)
        }
        draw(sprite(78, stateY, 25, 20), CGFloat(x), CGFloat(height - 20), 25, 20); x += 25
        let remaining = width - 25 - x
        if remaining > 0 { draw(sprite(104, stateY, 25, 20), CGFloat(x), CGFloat(height - 20), CGFloat(remaining), 20) }
        draw(sprite(130, stateY, 25, 20), CGFloat(width - 25), CGFloat(height - 20), 25, 20)
        draw(sprite(144, 3, 9, 9), CGFloat(width - 11), CGFloat(height - 12), 9, 9)

        let railHeight = height - 58
        var y = 38
        while y < 38 + railHeight {
            let segment = min(29, 38 + railHeight - y)
            draw(sprite(127, 42, 11, 29), 0, CGFloat(y), 11, CGFloat(segment))
            draw(sprite(139, 42, 8, 29), CGFloat(width - 8), CGFloat(y), 8, CGFloat(segment))
            y += segment
        }
        draw(sprite(158, 42, 11, 24), 0, 14, 11, 24)
        draw(sprite(170, 42, 8, 24), CGFloat(width - 8), 14, 8, 24)
        draw(sprite(0, 42, 125, 14), 0, 0, 125, 14)
        var bottomX = 125
        while bottomX < width - 125 {
            let segment = min(25, width - 125 - bottomX)
            draw(sprite(127, 72, 25, 14), CGFloat(bottomX), 0, CGFloat(segment), 14)
            bottomX += segment
        }
        draw(sprite(0, 57, 125, 14), CGFloat(width - 125), 0, 125, 14)
        image.unlockFocus()
        return image
    }

    /// The generic frame has two 125 px lower corners.  The title's own
    /// glyphs can require more than the compact 25 px field, so use both
    /// constraints when deciding whether a generic window may shrink.
    func genericMinimumWindowWidth(title: String) -> Int {
        let glyphWidth = Int(genericTitleGlyphImage(title, isActive: true)?.size.width ?? 25)
        return max(250, 100 + max(25, glyphWidth))
    }

    /// Side rails are kept separate so native scroll views can never paint
    /// over the skinned border while their system scrollers are visible.
    func genericInfoSideRailImage(left: Bool, height: Int) -> NSImage? {
        guard height >= 58, let sheet = bitmap(named: "GEN.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = left ? 11 : 8
        let sourceX = left ? 127 : 139
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus(); NSGraphicsContext.current?.imageInterpolation = .none
        func draw(_ x: Int, _ y: Int, _ h: Int, _ destinationY: Int, _ destinationHeight: Int? = nil) {
            guard let crop = source.cropping(to: CGRect(x: x, y: y, width: width, height: h)) else { return }
            let outputHeight = destinationHeight ?? h
            NSImage(cgImage: crop, size: NSSize(width: width, height: h)).draw(in: NSRect(x: 0, y: destinationY, width: width, height: outputHeight))
        }
        let railHeight = height - 58
        var y = 38
        while y < 38 + railHeight { let segment = min(29, 38 + railHeight - y); draw(sourceX, 42, 29, y, segment); y += segment }
        draw(left ? 158 : 170, 42, 24, 14)
        image.unlockFocus()
        return image
    }

    /// GEN.BMP's compact generic title controls are 9×9 cells near its lower
    /// edge.  Keeping this extraction here makes Info follow skin changes.
    func genericCloseButtonImage(pressed: Bool) -> NSImage? {
        guard let sheet = bitmap(named: "GEN.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let x = pressed ? 148 : 144
        let y = pressed ? 42 : 3
        guard let crop = source.cropping(to: CGRect(x: x, y: y, width: 9, height: 9)) else { return nil }
        return NSImage(cgImage: crop, size: NSSize(width: 9, height: 9))
    }

    /// Winamp's generic title font is variable-width. Its delimiter is the
    /// first colour before A, exactly as documented in wa_dlg.h.
    func genericTitleGlyphImage(_ text: String, isActive: Bool) -> NSImage? {
        guard let sheet = bitmap(named: "GEN.BMP"),
              let rep = NSBitmapImageRep(data: sheet.tiffRepresentation ?? Data()) else { return nil }
        let delimiterY = 90
        guard let delimiter = rep.colorAt(x: 0, y: delimiterY) else { return nil }
        var offsets: [Int] = [], widths: [Int] = [], position = 0
        for _ in 0..<26 {
            while position < rep.pixelsWide, rep.colorAt(x: position, y: delimiterY) == delimiter { position += 1 }
            let start = position
            while position < rep.pixelsWide, rep.colorAt(x: position, y: delimiterY) != delimiter { position += 1 }
            offsets.append(start); widths.append(max(1, position - start))
        }
        let letters = text.uppercased().compactMap { character -> (Int, Int)? in
            guard let ascii = character.asciiValue, ascii >= 65, ascii <= 90 else { return nil }
            let index = Int(ascii - 65); return (offsets[index], widths[index])
        }
        let width = letters.reduce(0) { $0 + $1.1 }
        guard width > 0,
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let output = NSImage(size: NSSize(width: width, height: 7)); output.lockFocus()
        var x = 0
        let row = isActive ? 88 : 96
        for (offset, glyphWidth) in letters {
            if let glyph = source.cropping(to: CGRect(x: offset, y: row, width: glyphWidth, height: 7)) {
                NSImage(cgImage: glyph, size: NSSize(width: glyphWidth, height: 7)).draw(at: NSPoint(x: x, y: 0), from: .zero, operation: .copy, fraction: 1)
            }
            x += glyphWidth
        }
        output.unlockFocus()
        return output
    }

    /// `PLEDIT.TXT` is the authoritative palette for the classic Playlist
    /// Editor.  Its four values map exactly to Winamp's Skin_PLColors 0...3.
    func playlistColors() -> PlaylistColors {
        if let playlistColorsCache { return playlistColorsCache }
        let defaults = PlaylistColors(
            normalText: Self.color(hex: "00FF00"),
            currentText: Self.color(hex: "FFFFFF"),
            background: Self.color(hex: "000000"),
            selectedBackground: Self.color(hex: "0000C6")
        )
        guard let directory = extractedDirectory,
              let file = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                  .first(where: { $0.lastPathComponent.caseInsensitiveCompare("PLEDIT.TXT") == .orderedSame }),
              let contents = try? String(contentsOf: file, encoding: .utf8) else {
            playlistColorsCache = defaults
            return defaults
        }

        var values: [String: NSColor] = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            if let color = Self.colorIfValid(hex: value) { values[key] = color }
        }
        let colors = PlaylistColors(
            normalText: values["normal"] ?? defaults.normalText,
            currentText: values["current"] ?? defaults.currentText,
            background: values["normalbg"] ?? defaults.background,
            selectedBackground: values["selectedbg"] ?? defaults.selectedBackground
        )
        playlistColorsCache = colors
        return colors
    }

    private static func color(hex: String) -> NSColor { colorIfValid(hex: hex) ?? .black }

    private static func colorIfValid(hex: String) -> NSColor? {
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
        return NSColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Classic skins provide a dedicated diagonal Playlist resize cursor.
    func cursor(named filename: String, hotSpot: NSPoint = NSPoint(x: 8, y: 8)) -> NSCursor? {
        guard let directory = extractedDirectory else { return nil }
        let fileKey = filename.lowercased()
        let key = "\(fileKey)-\(hotSpot.x)-\(hotSpot.y)"
        if let cached = cursorCache[key] { return cached }
        if missingSkinFiles.contains(fileKey) { return nil }
        let url: URL
        if let cachedURL = skinFileURLCache[fileKey] {
            url = cachedURL
        } else if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
                  let match = files.first(where: { $0.lastPathComponent.caseInsensitiveCompare(filename) == .orderedSame }) {
            url = match
        } else {
            missingSkinFiles.insert(fileKey)
            return nil
        }
        guard let image = NSImage(contentsOf: url) else {
            missingSkinFiles.insert(fileKey)
            return nil
        }
        skinFileURLCache[fileKey] = url
        let cursor = NSCursor(image: image, hotSpot: hotSpot)
        cursorCache[key] = cursor
        return cursor
    }

    /// The classic title bar uses rows 0/15; windowshade uses the compact rows 29/42.
    func titleBarImage(isActive: Bool, isWindowShaded: Bool) -> NSImage? {
        let key = "\(isActive)-\(isWindowShaded)"
        if let cached = titleBarCache[key] { return cached }
        let y: Int
        switch (isActive, isWindowShaded) {
        case (true, false): y = 0
        case (false, false): y = 15
        case (true, true): y = 29
        case (false, true): y = 42
        }
        guard let sheet = bitmap(named: "TITLEBAR.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= 302, source.height >= y + 14,
              let cropped = source.cropping(to: CGRect(x: 27, y: y, width: 275, height: 14)) else {
            return nil
        }
        let image = NSImage(cgImage: cropped, size: NSSize(width: 275, height: 14))
        titleBarCache[key] = image
        return image
    }

    func equalizerBaseImage() -> NSImage? {
        croppedEqualizerImage(x: 0, y: 0, width: 275, height: 116)
    }

    /// Recreates the classic Playlist Editor frame from `pledit.bmp` sprites.
    /// The sheet is not a background image: Winamp's `draw_pe.cpp` tiles its
    /// title bar, side rails and 38 px bottom command strip independently.
    func playlistEditorImage(width: Int, height: Int, isActive: Bool) -> NSImage? {
        guard width >= 275, height >= 58,
              let sheet = bitmap(named: "PLEDIT.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        func sprite(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> NSImage? {
            guard source.width >= x + w, source.height >= y + h,
                  let crop = source.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else { return nil }
            return NSImage(cgImage: crop, size: NSSize(width: w, height: h))
        }
        func draw(_ image: NSImage?, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            image?.draw(in: NSRect(x: x, y: y, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
        }

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

        let titleY = height - 20
        let titleState = isActive ? 0 : 21
        draw(sprite(0, titleState, 25, 20), 0, CGFloat(titleY), 25, 20)
        // For the standard 275 px editor this follows the exact 25+125+100+25
        // layout used by Winamp. The middle tile also allows wider future windows.
        var titleX = 25
        let titleEnd = width - 25
        while titleX < titleEnd {
            let segment = min(25, titleEnd - titleX)
            draw(sprite(127, titleState, 25, 20), CGFloat(titleX), CGFloat(titleY), CGFloat(segment), 20)
            titleX += segment
        }
        // Central title artwork and right title/corner segment are deliberately
        // overlaid at the original positions; they contain playlist controls.
        draw(sprite(26, titleState, 100, 20), CGFloat(max(25, (width - 100) / 2)), CGFloat(titleY), 100, 20)
        draw(sprite(153, titleState, 25, 20), CGFloat(width - 25), CGFloat(titleY), 25, 20)

        let listHeight = height - 20 - 38
        var railY = 38
        while railY < 38 + listHeight {
            let segment = min(29, 38 + listHeight - railY)
            draw(sprite(0, 42, 12, 29), 0, CGFloat(railY), 12, CGFloat(segment))
            draw(sprite(31, 42, 5, 29), CGFloat(width - 20), CGFloat(railY), 5, CGFloat(segment))
            draw(sprite(44, 42, 7, 29), CGFloat(width - 7), CGFloat(railY), 7, CGFloat(segment))
            railY += segment
        }

        // Bottom command area: the standard 275 px layout is exactly 125 + 150.
        draw(sprite(0, 72, 125, 38), 0, 0, 125, 38)
        if width > 275 {
            var x = 125
            while x < width - 150 {
                let segment = min(25, width - 150 - x)
                draw(sprite(179, 0, 25, 38), CGFloat(x), 0, CGFloat(segment), 38)
                x += segment
            }
        }
        draw(sprite(126, 72, 150, 38), CGFloat(width - 150), 0, 150, 38)
        image.unlockFocus()
        return image
    }

    /// Draws the Playlist Editor counter exactly as classic Winamp does: its
    /// digits, minus sign and colon all come from `TEXT.BMP`, not a system font.
    /// The layout deliberately keeps the narrow sign and the original gaps.
    func playlistTimeImage(minutes: Int, seconds: Int, isRemaining: Bool) -> NSImage? {
        let clampedMinutes = max(0, min(999, minutes))
        let clampedSeconds = max(0, min(59, seconds))
        let key = "\(clampedMinutes):\(clampedSeconds):\(isRemaining)"
        if let cached = playlistTimeCache[key] { return cached }
        guard let sheet = bitmap(named: "TEXT.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        func glyph(_ x: Int, _ y: Int = 6, _ width: Int = 5) -> NSImage? {
            guard source.width >= x + width, source.height >= y + 6,
                  let crop = source.cropping(to: CGRect(x: x, y: y, width: width, height: 6)) else { return nil }
            return NSImage(cgImage: crop, size: NSSize(width: width, height: 6))
        }
        func draw(_ glyph: NSImage?, at x: CGFloat, width: CGFloat) {
            glyph?.draw(in: NSRect(x: x, y: 0, width: width, height: 6), from: .zero, operation: .copy, fraction: 1)
        }

        let image = NSImage(size: NSSize(width: 32, height: 6))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        // draw_pe_timedisp() leaves the colon embedded in PLEDIT.BMP untouched.
        // Only the sign and numeric cells are refreshed, preserving the native gap.
        draw(glyph(142, 0, 4), at: 0, width: 4)
        draw(glyph(isRemaining ? 75 : 142, isRemaining ? 6 : 0, 3), at: 4, width: 3)

        // TEXT.BMP row 6: 0...9 at x = 0...45, minus at 75.  The
        // PLEDIT counter is MMM:SS (not MM:SS): draw_pe_timedisp() places
        // the hundreds-of-minutes cell at x+4 whenever it is non-zero.
        if clampedMinutes >= 100 {
            draw(glyph(((clampedMinutes / 100) % 10) * 5), at: 4, width: 5)
        }
        draw(glyph(((clampedMinutes / 10) % 10) * 5), at: 9, width: 5)
        draw(glyph((clampedMinutes % 10) * 5), at: 14, width: 5)
        draw(glyph((clampedSeconds / 10) * 5), at: 22, width: 5)
        draw(glyph((clampedSeconds % 10) * 5), at: 27, width: 5)
        image.unlockFocus()
        playlistTimeCache[key] = image
        return image
    }

    /// Pressed 22×18 frames for the five lower Playlist Editor menu buttons.
    func playlistMenuButtonPressedImage(index: Int) -> NSImage? {
        let sourceX = [23, 77, 127, 177, 227]
        guard sourceX.indices.contains(index),
              let sheet = bitmap(named: "PLEDIT.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let crop = source.cropping(to: CGRect(x: sourceX[index], y: 149, width: 22, height: 18)) else { return nil }
        return NSImage(cgImage: crop, size: NSSize(width: 22, height: 18))
    }

    func playlistCloseButtonImage(pressed: Bool) -> NSImage? {
        let source = pressed ? (52, 42) : (167, 3)
        guard let sheet = bitmap(named: "PLEDIT.BMP"),
              let image = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let crop = image.cropping(to: CGRect(x: source.0, y: source.1, width: 9, height: 9)) else { return nil }
        return NSImage(cgImage: crop, size: NSSize(width: 9, height: 9))
    }

    /// Compact Playlist Editor title bar used by its WindowShade mode.
    func playlistWindowShadeTitleImage(width: Int, isActive: Bool) -> NSImage? {
        guard width >= 50,
              let sheet = bitmap(named: "PLEDIT.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        func crop(_ x: Int, _ y: Int, _ w: Int) -> NSImage? {
            guard let value = source.cropping(to: CGRect(x: x, y: y, width: w, height: 14)) else { return nil }
            return NSImage(cgImage: value, size: NSSize(width: w, height: 14))
        }
        guard let left = crop(72, 42, 25),
              let middle = crop(72, 57, 25),
              let right = crop(99, isActive ? 42 : 57, 50) else { return nil }
        let image = NSImage(size: NSSize(width: width, height: 14))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        left.draw(in: NSRect(x: 0, y: 0, width: 25, height: 14))
        var x = 25
        while x < width - 50 {
            let part = min(25, width - 50 - x)
            middle.draw(in: NSRect(x: x, y: 0, width: part, height: 14), from: .zero, operation: .copy, fraction: 1)
            x += part
        }
        right.draw(in: NSRect(x: width - 50, y: 0, width: 50, height: 14))
        image.unlockFocus()
        return image
    }

    func playlistTitleControlImage(windowShade: Bool, close: Bool, pressed: Bool) -> NSImage? {
        let source: (Int, Int)
        if close {
            source = pressed ? (52, 42) : (167, 3)
        } else if windowShade {
            source = pressed ? (150, 42) : (128, 45)
        } else {
            source = pressed ? (62, 42) : (158, 3)
        }
        guard let sheet = bitmap(named: "PLEDIT.BMP"),
              let image = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let crop = image.cropping(to: CGRect(x: source.0, y: source.1, width: 9, height: 9)) else { return nil }
        return NSImage(cgImage: crop, size: NSSize(width: 9, height: 9))
    }

    /// The compact Playlist Editor right-aligns the current track's static
    /// total duration before the last 29 px window controls.
    func playlistWindowShadeTrackImage(time: TimeInterval, showsTime: Bool, width: Int) -> NSImage? {
        let usableWidth = max(0, width)
        let wholeSeconds = max(0, Int(time.rounded(.down)))
        let minutes = wholeSeconds / 60
        let seconds = wholeSeconds % 60
        let durationText = showsTime ? " \(minutes):\(String(format: "%02d", seconds)) " : ""
        let key = "\(durationText)|\(usableWidth)"
        if let cached = playlistWindowShadeTrackCache[key] { return cached }
        guard let sheet = bitmap(named: "TEXT.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        func sourcePoint(for character: Character) -> (Int, Int) {
            if let ascii = character.asciiValue {
                switch ascii {
                case 48...57: return (Int(ascii - 48) * 5, 6)
                default: break
                }
            }
            switch character {
            case ".": return (55, 6)
            case ":": return (60, 6)
            case "(": return (65, 6)
            case ")": return (70, 6)
            case "-": return (75, 6)
            case "[": return (110, 6)
            case "]": return (115, 6)
            case "_": return (90, 6)
            case "+": return (95, 6)
            case "/": return (105, 6)
            case " ": return (150, 0)
            default: return (15, 12) // question-mark cell
            }
        }
        func glyph(_ character: Character) -> NSImage? {
            let point = sourcePoint(for: character)
            guard let crop = source.cropping(to: CGRect(x: point.0, y: point.1, width: 5, height: 6)) else { return nil }
            return NSImage(cgImage: crop, size: NSSize(width: 5, height: 6))
        }

        let durationWidth = durationText.count * 5
        let image = NSImage(size: NSSize(width: usableWidth, height: 6))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        // The compact title itself uses the same live font as the main window.
        // This skin image contributes only the right-aligned duration glyphs.
        let durationStart = max(0, usableWidth - durationWidth)
        for (index, character) in durationText.enumerated() {
            glyph(character)?.draw(in: NSRect(x: durationStart + index * 5, y: 0, width: 5, height: 6), from: .zero, operation: .copy, fraction: 1)
        }
        image.unlockFocus()
        playlistWindowShadeTrackCache[key] = image
        return image
    }

    /// Raster text for the compact Playlist Editor.  The inactive editor uses
    /// this for its track count and total duration, rather than a proportional
    /// system font that can spill into the PWSIZE control.
    func playlistWindowShadeGlyphTextImage(_ text: String, width: Int, rightAligned: Bool = true) -> NSImage? {
        let usableWidth = max(0, width)
        let key = "glyph:\(text)|\(usableWidth)|\(rightAligned)"
        if let cached = playlistWindowShadeTrackCache[key] { return cached }
        guard let sheet = bitmap(named: "TEXT.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        func sourcePoint(for character: Character) -> (Int, Int) {
            if let ascii = character.asciiValue {
                switch ascii {
                case 48...57: return (Int(ascii - 48) * 5, 6)
                default: break
                }
            }
            switch character {
            case ".": return (55, 6)
            case ":": return (60, 6)
            case "(": return (65, 6)
            case ")": return (70, 6)
            case "-": return (75, 6)
            case "[": return (110, 6)
            case "]": return (115, 6)
            case "_": return (90, 6)
            case "+": return (95, 6)
            case "/": return (105, 6)
            case " ": return (150, 0)
            default: return (15, 12)
            }
        }
        let visibleCharacters = Array(text.prefix(max(0, usableWidth / 5)))
        let image = NSImage(size: NSSize(width: usableWidth, height: 6))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        let start = rightAligned ? max(0, usableWidth - visibleCharacters.count * 5) : 0
        for (index, character) in visibleCharacters.enumerated() {
            let point = sourcePoint(for: character)
            guard let glyph = source.cropping(to: CGRect(x: point.0, y: point.1, width: 5, height: 6)) else { continue }
            NSImage(cgImage: glyph, size: NSSize(width: 5, height: 6))
                .draw(in: NSRect(x: start + index * 5, y: 0, width: 5, height: 6), from: .zero, operation: .copy, fraction: 1)
        }
        image.unlockFocus()
        playlistWindowShadeTrackCache[key] = image
        return image
    }

    func equalizerTitleBarImage(isActive: Bool) -> NSImage? {
        croppedEqualizerImage(x: 0, y: isActive ? 134 : 149, width: 275, height: 14)
    }

    func equalizerWindowShadeTitleImage(isActive: Bool) -> NSImage? {
        guard let sheet = bitmap(named: "EQ_EX.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = source.cropping(to: CGRect(x: 0, y: isActive ? 0 : 15, width: 275, height: 14)) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: 275, height: 14))
    }

    func equalizerTitleControlImage(_ control: EqualizerTitleControl, windowShade: Bool, pressed: Bool) -> NSImage? {
        let filename: String
        let x: Int
        let y: Int
        switch (windowShade, control, pressed) {
        case (false, .windowShade, false): filename = "EQMAIN.BMP"; x = 254; y = 137
        case (false, .windowShade, true): filename = "EQ_EX.BMP"; x = 1; y = 38
        case (false, .close, false): filename = "EQMAIN.BMP"; x = 0; y = 116
        case (false, .close, true): filename = "EQMAIN.BMP"; x = 0; y = 125
        case (true, .windowShade, false): filename = "EQ_EX.BMP"; x = 254; y = 3
        case (true, .windowShade, true): filename = "EQ_EX.BMP"; x = 1; y = 47
        case (true, .close, false): filename = "EQ_EX.BMP"; x = 11; y = 38
        case (true, .close, true): filename = "EQ_EX.BMP"; x = 11; y = 47
        }
        guard let sheet = bitmap(named: filename),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = source.cropping(to: CGRect(x: x, y: y, width: 9, height: 9)) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: 9, height: 9))
    }

    func equalizerWindowShadeThumb(isVolume: Bool, value: Double) -> NSImage? {
        let clamped = min(1, max(0, value))
        let state = min(2, Int((clamped * 3).rounded(.down)))
        let x = (isVolume ? 1 : 11) + state * 3
        guard let sheet = bitmap(named: "EQ_EX.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = source.cropping(to: CGRect(x: x, y: 30, width: 3, height: 7)) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: 3, height: 7))
    }

    private func croppedEqualizerImage(x: Int, y: Int, width: Int, height: Int) -> NSImage? {
        guard let sheet = bitmap(named: "EQMAIN.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= x + width, source.height >= y + height,
              let cropped = source.cropping(to: CGRect(x: x, y: y, width: width, height: height)) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: width, height: height))
    }

    /// Recreates Winamp's `draw_eq_slid`: a 14×63 rail plus an 11×11 skin thumb.
    func equalizerSliderImage(position: Int, pressed: Bool) -> NSImage? {
        let clampedPosition = min(63, max(0, position))
        let key = "\(clampedPosition)-\(pressed)"
        if let cached = equalizerSliderCache[key] { return cached }
        // EQMAIN stores the coloured rail strips in the inverse visual order:
        // red is selected for the upper slider position, green for the lower one.
        let railPosition = 63 - clampedPosition
        let spriteRow = 27 - (railPosition * 28 / 64)
        let railY = spriteRow < 14 ? 164 : 229
        let railX = 13 + (spriteRow < 14 ? spriteRow : spriteRow - 14) * 15
        guard let sheet = bitmap(named: "EQMAIN.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let rail = source.cropping(to: CGRect(x: railX, y: railY, width: 14, height: 63)),
              let thumb = source.cropping(to: CGRect(x: 0, y: pressed ? 176 : 164, width: 11, height: 11)) else { return nil }
        let image = NSImage(size: NSSize(width: 14, height: 63))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: rail, size: NSSize(width: 14, height: 63)).draw(in: NSRect(x: 0, y: 0, width: 14, height: 63))
        let thumbY = 51 - ((63 - clampedPosition) * 52 / 64)
        NSImage(cgImage: thumb, size: NSSize(width: 11, height: 11)).draw(in: NSRect(x: 1, y: thumbY, width: 11, height: 11))
        image.unlockFocus()
        equalizerSliderCache[key] = image
        return image
    }

    func equalizerOnAutoImage(on: Bool, auto: Bool, onPressed: Bool, autoPressed: Bool) -> NSImage? {
        guard let sheet = bitmap(named: "EQMAIN.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let onImage = source.cropping(to: CGRect(x: 10 + (onPressed ? 118 : 0) + (on ? 59 : 0), y: 119, width: 25, height: 12)),
              let autoImage = source.cropping(to: CGRect(x: 35 + (autoPressed ? 118 : 0) + (auto ? 59 : 0), y: 119, width: 33, height: 12)) else { return nil }
        let image = NSImage(size: NSSize(width: 58, height: 12))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: onImage, size: NSSize(width: 25, height: 12)).draw(in: NSRect(x: 0, y: 0, width: 25, height: 12))
        NSImage(cgImage: autoImage, size: NSSize(width: 33, height: 12)).draw(in: NSRect(x: 25, y: 0, width: 33, height: 12))
        image.unlockFocus()
        return image
    }

    func equalizerPresetsImage(pressed: Bool) -> NSImage? {
        croppedEqualizerImage(x: 224, y: pressed ? 176 : 164, width: 44, height: 12)
    }

    func titleBarControlImage(_ control: TitleBarControl, pressed: Bool) -> NSImage? {
        let key = "\(control)-\(pressed)"
        if let cached = titleBarControlCache[key] { return cached }
        let x: Int
        let y: Int
        switch control {
        case .minimize: (x, y) = (9, pressed ? 9 : 0)
        case .close: (x, y) = (18, pressed ? 9 : 0)
        case .windowShade: (x, y) = (0, pressed ? 27 : 18)
        }
        guard let sheet = bitmap(named: "TITLEBAR.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= x + 9, source.height >= y + 9,
              let cropped = source.cropping(to: CGRect(x: x, y: y, width: 9, height: 9)) else {
            return nil
        }
        let image = NSImage(cgImage: cropped, size: NSSize(width: 9, height: 9))
        titleBarControlCache[key] = image
        return image
    }

    /// `titlebar.bmp` stores the 8×43 clutterbar at (304, 0).
    /// Pressing any of its five buttons swaps the entire strip for a state at (304 + 8n, 44).
    func clutterbarImage(pressedButton: Int?) -> NSImage? {
        let key = pressedButton.map(String.init) ?? "normal"
        if let cached = clutterbarCache[key] { return cached }
        let x = pressedButton.map { 304 + $0 * 8 } ?? 304
        let y = pressedButton == nil ? 0 : 44
        guard let sheet = bitmap(named: "TITLEBAR.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= x + 8, source.height >= y + 43,
              let cropped = source.cropping(to: CGRect(x: x, y: y, width: 8, height: 43)) else {
            return nil
        }
        let image = NSImage(cgImage: cropped, size: NSSize(width: 8, height: 43))
        clutterbarCache[key] = image
        return image
    }

    func playbackIndicatorImage(_ indicator: PlaybackIndicator) -> NSImage? {
        if let cached = playbackIndicatorCache[indicator.rawValue] { return cached }
        let mainX: Int
        let leftX: Int
        let leftWidth: Int
        switch indicator {
        case .play: (mainX, leftX, leftWidth) = (0, 36, 3)
        case .pause: (mainX, leftX, leftWidth) = (9, 27, 2)
        case .stop: (mainX, leftX, leftWidth) = (18, 27, 2)
        case .lostSync: (mainX, leftX, leftWidth) = (0, 39, 3)
        }
        guard let sheet = bitmap(named: "PLAYPAUS.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= max(mainX + 9, leftX + leftWidth), source.height >= 9,
              let mainPart = source.cropping(to: CGRect(x: mainX, y: 0, width: 9, height: 9)),
              let leftPart = source.cropping(to: CGRect(x: leftX, y: 0, width: leftWidth, height: 9)) else {
            return nil
        }
        let image = NSImage(size: NSSize(width: 11, height: 9))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: leftPart, size: NSSize(width: leftWidth, height: 9))
            .draw(in: NSRect(x: 0, y: 0, width: leftWidth, height: 9))
        NSImage(cgImage: mainPart, size: NSSize(width: 9, height: 9))
            .draw(in: NSRect(x: 2, y: 0, width: 9, height: 9))
        image.unlockFocus()
        playbackIndicatorCache[indicator.rawValue] = image
        return image
    }

    func windowShadeMinusSign() -> NSImage? {
        if let windowShadeMinusCache { return windowShadeMinusCache }
        guard let sheet = bitmap(named: "TEXT.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= 78, source.height >= 12,
              let cropped = source.cropping(to: CGRect(x: 75, y: 6, width: 3, height: 6)) else {
            return nil
        }
        let image = NSImage(cgImage: cropped, size: NSSize(width: 3, height: 6))
        windowShadeMinusCache = image
        return image
    }

    /// Exact 32×6 compact main-window time field. Its digits begin at x=134
    /// in the 275 px titlebar, while the colon occupies the built-in gap.
    func windowShadeTimeImage(minutes: Int, seconds: Int, isRemaining: Bool) -> NSImage? {
        let safeMinutes = max(0, min(99, minutes))
        let safeSeconds = max(0, min(59, seconds))
        let key = "\(safeMinutes):\(safeSeconds):\(isRemaining)"
        if let cached = windowShadeTimeCache[key] { return cached }
        guard let sheet = bitmap(named: "TEXT.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        func glyph(_ x: Int, _ y: Int = 6, _ width: Int = 5) -> NSImage? {
            guard let crop = source.cropping(to: CGRect(x: x, y: y, width: width, height: 6)) else { return nil }
            return NSImage(cgImage: crop, size: NSSize(width: width, height: 6))
        }
        func draw(_ image: NSImage?, _ x: CGFloat, _ width: CGFloat = 5) {
            image?.draw(in: NSRect(x: x, y: 0, width: width, height: 6), from: .zero, operation: .copy, fraction: 1)
        }
        let image = NSImage(size: NSSize(width: 32, height: 6))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        // draw_time() clears these two three-pixel sign cells before writing digits.
        draw(glyph(142, 0, 3), 1, 3)
        draw(glyph(isRemaining ? 75 : 142, isRemaining ? 6 : 0, 3), 5, 3)
        draw(glyph((safeMinutes / 10) * 5), 9)
        draw(glyph((safeMinutes % 10) * 5), 14)
        // The original skin uses this three-pixel gap for its colon.
        draw(glyph(60), 18)
        draw(glyph((safeSeconds / 10) * 5), 22)
        draw(glyph((safeSeconds % 10) * 5), 27)
        image.unlockFocus()
        windowShadeTimeCache[key] = image
        return image
    }

    /// Compact position bar from `titlebar.bmp`: 17×7 background plus a 3×7 thumb.
    func windowShadePositionImage(progress: Double) -> NSImage? {
        let thumbOffset = min(13, max(1, Int((progress * 12).rounded(.down)) + 1))
        if let cached = windowShadePositionCache[thumbOffset] { return cached }
        let thumbState = thumbOffset < 6 ? 0 : (thumbOffset < 9 ? 1 : 2)
        guard let sheet = bitmap(named: "TITLEBAR.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= 26, source.height >= 43,
              let background = source.cropping(to: CGRect(x: 0, y: 36, width: 17, height: 7)),
              let thumb = source.cropping(to: CGRect(x: 17 + thumbState * 3, y: 36, width: 3, height: 7)) else {
            return nil
        }
        let image = NSImage(size: NSSize(width: 17, height: 7))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: background, size: NSSize(width: 17, height: 7))
            .draw(in: NSRect(x: 0, y: 0, width: 17, height: 7))
        NSImage(cgImage: thumb, size: NSSize(width: 3, height: 7))
            .draw(in: NSRect(x: thumbOffset, y: 0, width: 3, height: 7))
        image.unlockFocus()
        windowShadePositionCache[thumbOffset] = image
        return image
    }

    /// The first ten cells of a classic `numbers.bmp` are the digits 0 through 9.
    /// They are fixed 9×13 pixel glyphs in the Winamp 2.x skin specification.
    func timeDigit(_ digit: Int) -> NSImage? {
        timeGlyph(at: digit)
    }

    /// In classic `numbers.bmp` the remaining-time minus is a 5×1 strip at (20, 6),
    /// not an eleventh 9×13 digit cell.
    func timeMinusSign() -> NSImage? {
        let cacheKey = 10
        if let cached = timeDigitCache[cacheKey] { return cached }
        guard let sheet = bitmap(named: "NUMBERS.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= 25, source.height >= 7,
              let cropped = source.cropping(to: CGRect(x: 20, y: 6, width: 5, height: 1)) else {
            return nil
        }
        let image = NSImage(cgImage: cropped, size: NSSize(width: 5, height: 1))
        timeDigitCache[cacheKey] = image
        return image
    }

    private func timeGlyph(at index: Int) -> NSImage? {
        guard (0...9).contains(index) else { return nil }
        if let cached = timeDigitCache[index] { return cached }
        guard let sheet = bitmap(named: "NUMBERS.BMP") ?? bitmap(named: "NUMS_EX.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= 99, source.height >= 13,
              let cropped = source.cropping(to: CGRect(x: index * 9, y: 0, width: 9, height: 13)) else {
            return nil
        }

        let image = NSImage(cgImage: cropped, size: NSSize(width: 9, height: 13))
        timeDigitCache[index] = image
        return image
    }

    /// Classic `posbar.bmp`: a 248×10 track followed by normal and pressed 29×10 thumbs.
    func positionBarTrack() -> NSImage? {
        positionBarImage(cacheKey: "track", x: 0, width: 248)
    }

    func positionBarThumb(pressed: Bool) -> NSImage? {
        positionBarImage(cacheKey: pressed ? "pressedThumb" : "thumb", x: pressed ? 278 : 248, width: 29)
    }

    private func positionBarImage(cacheKey: String, x: Int, width: Int) -> NSImage? {
        if let cached = positionBarCache[cacheKey] { return cached }
        guard let sheet = bitmap(named: "POSBAR.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= x + width, source.height >= 10,
              let cropped = source.cropping(to: CGRect(x: x, y: 0, width: width, height: 10)) else {
            return nil
        }

        let image = NSImage(cgImage: cropped, size: NSSize(width: width, height: 10))
        positionBarCache[cacheKey] = image
        return image
    }

    /// `volume.bmp` contains 28 complete 68×13 slider frames, spaced 15 pixels apart.
    func volumeBarImage(for volume: Double) -> NSImage? {
        let frame = Int((min(1, max(0, volume)) * 27).rounded())
        if let cached = volumeBarCache[frame] { return cached }
        let y = frame * 15
        guard let sheet = bitmap(named: "VOLUME.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= 68, source.height >= y + 13,
              let cropped = source.cropping(to: CGRect(x: 0, y: y, width: 68, height: 13)) else {
            return nil
        }

        let image = NSImage(cgImage: cropped, size: NSSize(width: 68, height: 13))
        volumeBarCache[frame] = image
        return image
    }

    /// The bottom row of `volume.bmp` contains 14×11 normal and pressed thumb images.
    func volumeThumb(pressed: Bool) -> NSImage? {
        if let cached = volumeThumbCache[pressed] { return cached }
        let x = pressed ? 0 : 15
        guard let sheet = bitmap(named: "VOLUME.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= x + 14, source.height >= 433,
              let cropped = source.cropping(to: CGRect(x: x, y: 422, width: 14, height: 11)) else {
            return nil
        }

        let image = NSImage(cgImage: cropped, size: NSSize(width: 14, height: 11))
        volumeThumbCache[pressed] = image
        return image
    }

    /// `balance.bmp` has a 38×13 track at x=9 for each of its 28 balance-distance states.
    func balanceBarImage(for balance: Double) -> NSImage? {
        let frame = Int((min(1, abs(balance)) * 27).rounded())
        if let cached = balanceBarCache[frame] { return cached }
        let y = frame * 15
        guard let sheet = bitmap(named: "BALANCE.BMP") ?? bitmap(named: "VOLUME.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= 47, source.height >= y + 13,
              let cropped = source.cropping(to: CGRect(x: 9, y: y, width: 38, height: 13)) else {
            return nil
        }

        let image = NSImage(cgImage: cropped, size: NSSize(width: 38, height: 13))
        balanceBarCache[frame] = image
        return image
    }

    func balanceThumb(pressed: Bool) -> NSImage? {
        if let cached = balanceThumbCache[pressed] { return cached }
        let x = pressed ? 0 : 15
        guard let sheet = bitmap(named: "BALANCE.BMP") ?? bitmap(named: "VOLUME.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= x + 14, source.height >= 433,
              let cropped = source.cropping(to: CGRect(x: x, y: 422, width: 14, height: 11)) else {
            return nil
        }

        let image = NSImage(cgImage: cropped, size: NSSize(width: 14, height: 11))
        balanceThumbCache[pressed] = image
        return image
    }

    /// `shufrep.bmp` stores EQ/PL controls at y=61 (off) and y=73 (on).
    func windowToggleImage(_ toggle: WindowToggle, isActive: Bool, isPressed: Bool) -> NSImage? {
        let key = "\(toggle)-\(isActive)-\(isPressed)"
        if let cached = windowToggleCache[key] { return cached }

        let x: Int
        switch (toggle, isPressed) {
        case (.equalizer, false): x = 0
        case (.playlist, false): x = 23
        case (.equalizer, true): x = 46
        case (.playlist, true): x = 69
        }
        let y = isActive ? 73 : 61
        guard let sheet = bitmap(named: "SHUFREP.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= x + 23, source.height >= y + 12,
              let cropped = source.cropping(to: CGRect(x: x, y: y, width: 23, height: 12)) else {
            return nil
        }

        let image = NSImage(cgImage: cropped, size: NSSize(width: 23, height: 12))
        windowToggleCache[key] = image
        return image
    }

    /// Digits 0…9 in `text.bmp` start at (0, 6), with 5×6 pixel cells.
    func textDigit(_ digit: Int) -> NSImage? {
        guard (0...9).contains(digit) else { return nil }
        if let cached = textDigitCache[digit] { return cached }
        guard let sheet = bitmap(named: "TEXT.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= (digit + 1) * 5, source.height >= 12,
              let cropped = source.cropping(to: CGRect(x: digit * 5, y: 6, width: 5, height: 6)) else {
            return nil
        }

        let image = NSImage(cgImage: cropped, size: NSSize(width: 5, height: 6))
        textDigitCache[digit] = image
        return image
    }

    /// The visualization mode letters use the classic 5×6 green font in `text.bmp`.
    func visualizationGlyph(_ character: Character) -> NSImage? {
        if let cached = visualizationGlyphCache[character] { return cached }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard let index = alphabet.firstIndex(of: character),
              let sheet = bitmap(named: "TEXT.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= (index + 1) * 5, source.height >= 6,
              let cropped = source.cropping(to: CGRect(x: index * 5, y: 0, width: 5, height: 6)) else {
            return nil
        }

        let image = NSImage(cgImage: cropped, size: NSSize(width: 5, height: 6))
        visualizationGlyphCache[character] = image
        return image
    }

    /// `cbuttons.bmp` stores normal controls in the first row and pressed controls in the second.
    func playerControlImage(_ control: PlayerControl, pressed: Bool) -> NSImage? {
        let key = "\(control)-\(pressed)"
        if let cached = playerControlCache[key] { return cached }

        let x: Int
        let width: Int
        let height: Int
        switch control {
        case .previous: (x, width, height) = (0, 23, 18)
        case .play: (x, width, height) = (23, 23, 18)
        case .pause: (x, width, height) = (46, 23, 18)
        case .stop: (x, width, height) = (69, 23, 18)
        case .next: (x, width, height) = (92, 22, 18)
        case .eject: (x, width, height) = (114, 22, 16)
        }
        let y = pressed ? 18 : 0
        guard let sheet = bitmap(named: "CBUTTONS.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= x + width, source.height >= y + height,
              let cropped = source.cropping(to: CGRect(x: x, y: y, width: width, height: height)) else {
            return nil
        }

        let image = NSImage(cgImage: cropped, size: NSSize(width: width, height: height))
        playerControlCache[key] = image
        return image
    }

    /// `shufrep.bmp` contains shuffle/repeat controls in four rows: off/on × normal/pressed.
    func playbackToggleImage(_ toggle: PlaybackToggle, isActive: Bool, isPressed: Bool) -> NSImage? {
        let key = "\(toggle)-\(isActive)-\(isPressed)"
        if let cached = playbackToggleCache[key] { return cached }

        let x: Int
        let width: Int
        switch toggle {
        case .repeatTrack: (x, width) = (0, 28)
        case .shuffle: (x, width) = (28, 47)
        }
        let y: Int
        switch (isActive, isPressed) {
        case (false, false): y = 0
        case (false, true): y = 15
        case (true, false): y = 30
        case (true, true): y = 45
        }
        guard let sheet = bitmap(named: "SHUFREP.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= x + width, source.height >= y + 15,
              let cropped = source.cropping(to: CGRect(x: x, y: y, width: width, height: 15)) else {
            return nil
        }

        let image = NSImage(cgImage: cropped, size: NSSize(width: width, height: 15))
        playbackToggleCache[key] = image
        return image
    }

    /// `monoster.bmp`: active stereo/mono on the top row; inactive states below.
    func channelIndicator(stereo: Bool, isActive: Bool) -> NSImage? {
        let key = "\(stereo)-\(isActive)"
        if let cached = channelIndicatorCache[key] { return cached }
        let x = stereo ? 0 : 29
        let y = isActive ? 0 : 12
        let width = stereo ? 29 : 27
        guard let sheet = bitmap(named: "MONOSTER.BMP"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width >= x + width, source.height >= y + 12,
              let cropped = source.cropping(to: CGRect(x: x, y: y, width: width, height: 12)) else {
            return nil
        }

        let image = NSImage(cgImage: cropped, size: NSSize(width: width, height: 12))
        channelIndicatorCache[key] = image
        return image
    }

    private func loadVisualizationPalette(from directory: URL) -> [NSColor] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
              let file = files.first(where: { $0.lastPathComponent.caseInsensitiveCompare("VISCOLOR.TXT") == .orderedSame }),
              let text = try? String(contentsOf: file, encoding: .utf8) else {
            return Self.defaultVisualizationPalette
        }

        let colors = text.split(whereSeparator: { $0.isNewline }).compactMap { line -> NSColor? in
            let values = line.split(separator: "/", maxSplits: 1).first?
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let values, values.count >= 3 else { return nil }
            return NSColor(
                calibratedRed: CGFloat(values[0]) / 255,
                green: CGFloat(values[1]) / 255,
                blue: CGFloat(values[2]) / 255,
                alpha: 1
            )
        }
        return colors.count >= 18 ? colors : Self.defaultVisualizationPalette
    }

    private static let defaultVisualizationPalette: [NSColor] = [
        .black, NSColor(calibratedWhite: 0.08, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.35, blue: 1, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.55, blue: 1, alpha: 1),
        NSColor(calibratedRed: 0.15, green: 0.85, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.15, green: 1, blue: 0.45, alpha: 1),
        NSColor(calibratedRed: 0.55, green: 1, blue: 0.20, alpha: 1),
        NSColor(calibratedRed: 0.95, green: 1, blue: 0.15, alpha: 1),
        NSColor(calibratedRed: 1, green: 0.75, blue: 0.10, alpha: 1),
        NSColor(calibratedRed: 1, green: 0.25, blue: 0.10, alpha: 1),
        NSColor(calibratedRed: 1, green: 0.10, blue: 0.08, alpha: 1),
        NSColor(calibratedRed: 0.85, green: 0.05, blue: 0.08, alpha: 1),
        NSColor(calibratedRed: 0.70, green: 0.04, blue: 0.08, alpha: 1),
        NSColor(calibratedRed: 0.55, green: 0.03, blue: 0.08, alpha: 1),
        NSColor(calibratedRed: 0.45, green: 0.03, blue: 0.08, alpha: 1),
        NSColor(calibratedRed: 0.35, green: 0.02, blue: 0.08, alpha: 1),
        NSColor(calibratedRed: 0.25, green: 0.02, blue: 0.08, alpha: 1),
        NSColor(calibratedRed: 0.18, green: 0.01, blue: 0.08, alpha: 1)
    ]

    enum SkinError: Error { case invalidArchive, missingMainBitmap }
}
