import Combine
import Foundation

extension Notification.Name {
    static let macAmpInterfaceScaleDidChange = Notification.Name("macAmpInterfaceScaleDidChange")
}

/// Shared logical geometry for the classic skin windows.
///
/// Main Player and Equalizer are both 116 logical pixels high in their full
/// state. The 29 px resize step is the closest practical step to the 25 px
/// horizontal grid and divides that fixed height exactly four times.
enum SkinWindowGeometry {
    static let mainWidth: CGFloat = 275
    static let fullWindowHeight: CGFloat = 116
    static let windowShadeHeight: CGFloat = 14
    static let horizontalResizeStep: CGFloat = 25
    static let verticalResizeStep: CGFloat = fullWindowHeight / 4

    static func snappedWindowHeight(_ value: CGFloat) -> CGFloat {
        let units = max(1, Int(ceil(max(0, value) / verticalResizeStep)))
        return CGFloat(units) * verticalResizeStep
    }
}

/// Winamp's original double-size mode, generalized to a precise 10% grid.
final class InterfaceScale: ObservableObject {
    @Published var percent: Double {
        didSet {
            let snapped = min(300, max(100, (percent / 10).rounded() * 10))
            if percent != snapped {
                percent = snapped
                return
            }
            UserDefaults.standard.set(percent, forKey: "interfaceScalePercent")
            NotificationCenter.default.post(name: .macAmpInterfaceScaleDidChange, object: self)
        }
    }

    var factor: Double { percent / 100 }

    init() {
        let stored = UserDefaults.standard.double(forKey: "interfaceScalePercent")
        percent = stored == 0 ? 100 : min(300, max(100, (stored / 10).rounded() * 10))
    }
}

/// Independent text scale for dense content views. It deliberately does not
/// alter skin geometry, so users can enlarge playlist and Info text without
/// changing the classic window layout.
final class PlaylistFontScale: ObservableObject {
    @Published var percent: Double {
        didSet {
            let snapped = min(200, max(100, (percent / 10).rounded() * 10))
            if percent != snapped {
                percent = snapped
                return
            }
            UserDefaults.standard.set(percent, forKey: "playlistFontScalePercent")
        }
    }

    var factor: Double { percent / 100 }

    init() {
        let stored = UserDefaults.standard.double(forKey: "playlistFontScalePercent")
        percent = stored == 0 ? 100 : min(200, max(100, (stored / 10).rounded() * 10))
    }
}

/// Persisted independently from playback so the same display mode is restored at launch.
final class TimeDisplayPreference: ObservableObject {
    @Published var showsRemainingTime: Bool {
        didSet {
            UserDefaults.standard.set(showsRemainingTime, forKey: "timeDisplayShowsRemaining")
        }
    }

    init() {
        showsRemainingTime = UserDefaults.standard.bool(forKey: "timeDisplayShowsRemaining")
    }

    func toggle() {
        showsRemainingTime.toggle()
    }
}
