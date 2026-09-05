import AppKit
import Combine
import UserNotifications

protocol TrackNotificationCenter: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func getNotificationSettings(completionHandler: @escaping @Sendable (UNNotificationSettings) -> Void)
    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, Error?) -> Void)
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: TrackNotificationCenter {}

/// Event-driven system notifications. The Swift 5 AppKit host uses main-queue
/// confinement rather than actor isolation. Sendable is safe only because OS
/// callbacks hop to main before accessing state; entry points assert that rule.
final class TrackNotificationController: NSObject, ObservableObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private static let preferenceKey = "macAmp.notifications.trackChanges"
    private static let identifier = "macAmp.nowPlaying"
    private static let category = "macAmp.playback"
    private static let pauseAction = "macAmp.pause"
    private static let nextAction = "macAmp.next"
    private let center: TrackNotificationCenter
    private let defaults: UserDefaults
    private var generation = 0
    private var queuedContent: UNMutableNotificationContent?
    private var isAdding = false
    private var currentToken: Int?

    var onPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onShowWindows: (() -> Void)?
    @Published private(set) var permissionMessage = ""
    @Published var isEnabled: Bool {
        didSet {
            dispatchPrecondition(condition: .onQueue(.main))
            defaults.set(isEnabled, forKey: Self.preferenceKey)
            if isEnabled { requestPermission() } else { invalidate(removeDelivered: true) }
        }
    }

    init(center: TrackNotificationCenter = UNUserNotificationCenter.current(), defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
        super.init()
    }

    static func shouldNotify(enabled: Bool, automatic: Bool, hasActiveWindow: Bool) -> Bool {
        enabled && (automatic || !hasActiveWindow)
    }

    func configure() {
        dispatchPrecondition(condition: .onQueue(.main))
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.category,
            actions: [
                UNNotificationAction(identifier: Self.pauseAction, title: "⏸ Pause", options: []),
                UNNotificationAction(identifier: Self.nextAction, title: "⏭ Next", options: [])
            ], intentIdentifiers: [], options: []
        )])
        invalidate(removeDelivered: true)
    }

    func refreshPermission() {
        dispatchPrecondition(condition: .onQueue(.main))
        center.getNotificationSettings { [weak self] settings in
            let denied = settings.authorizationStatus == .denied
            DispatchQueue.main.async {
                self?.permissionMessage = denied
                    ? "Allow macAmp notifications in macOS System Settings." : ""
            }
        }
    }

    private func requestPermission(completion: (@Sendable (Bool) -> Void)? = nil) {
        center.requestAuthorization(options: [.alert]) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.permissionMessage = error != nil ? "Could not request notification permission."
                    : (granted ? "" : "Allow macAmp notifications in macOS System Settings.")
                completion?(granted)
            }
        }
    }

    /// Invalidate asynchronous permission/delivery work on every track selection.
    /// Keep the delivered card until its replacement is ready when notifying.
    func invalidate(removeDelivered: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        generation &+= 1
        queuedContent = nil
        currentToken = nil
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        if removeDelivered { center.removeDeliveredNotifications(withIdentifiers: [Self.identifier]) }
    }

    func show(artist: String?, title: String, duration: TimeInterval?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isEnabled else { return }
        let token = generation
        requestPermission { [weak self] granted in
            guard let self, granted, self.isEnabled, self.generation == token else { return }
            let content = UNMutableNotificationContent()
            let cleanArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
            content.title = cleanArtist?.isEmpty == false ? cleanArtist! : ""
            content.body = Self.body(title: title, duration: duration)
            content.categoryIdentifier = Self.category
            content.userInfo = ["generation": token]
            // A constant request identifier replaces the delivered notification,
            // rather than merely grouping an ever-growing history of cards.
            self.queuedContent = content
            self.currentToken = token
            self.deliverQueuedContent()
        }
    }

    static func body(title: String, duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration > 0 else { return title }
        let seconds = Int(duration.rounded(.down))
        return "\(title) · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    /// A conservative fallback for files without separate ID3 artist/title
    /// data. It intentionally preserves the remainder after the first dash:
    /// “Artist - Song - Remix” is one song title, not three fields.
    static func artistAndTitle(fromFilename filename: String) -> (artist: String, title: String)? {
        let normalized = filename.replacingOccurrences(of: "_", with: " ")
        for separator in [" - ", "-"] {
            guard let range = normalized.range(of: separator) else { continue }
            let artist = String(normalized[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = String(normalized[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !artist.isEmpty, !title.isEmpty { return (artist, title) }
        }
        return nil
    }

    private func deliverQueuedContent() {
        guard !isAdding, let content = queuedContent else { return }
        queuedContent = nil
        isAdding = true
        let token = generation
        center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isAdding = false
                if token != self.generation {
                    self.center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
                } else if let error {
                    NSLog("Track notification delivery failed: %@", error.localizedDescription)
                }
                self.deliverQueuedContent()
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let token = notification.request.content.userInfo["generation"] as? Int
        DispatchQueue.main.async {
            completionHandler(self.isEnabled && token == self.currentToken ? [.banner, .list] : [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            defer { completionHandler() }
            guard identifier == Self.identifier else { return }
            switch action {
            case UNNotificationDefaultActionIdentifier: self.onShowWindows?()
            case Self.pauseAction: self.onPause?()
            case Self.nextAction: self.onNext?()
            default: break
            }
        }
    }
}
