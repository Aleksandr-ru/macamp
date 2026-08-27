import Combine
import Foundation

extension Notification.Name {
    static let macAmpInterfaceScaleDidChange = Notification.Name("MacAmpInterfaceScaleDidChange")
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
