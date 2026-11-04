import AppKit

/// Knows whether Spotify is running / playing, and what it plays.
/// Event driven only: NSWorkspace launch/quit + Spotify's distributed
/// "PlaybackStateChanged" notification. No polling, no AppleScript loop.
final class SpotifyMonitor {
    static let bundleID = "com.spotify.client"

    enum PlayerState: Equatable { case unknown, playing, paused, stopped }

    private(set) var isRunning = false
    private(set) var state: PlayerState = .unknown
    private(set) var title: String?
    private(set) var artist: String?
    private(set) var pid: pid_t?

    var onChange: (() -> Void)?

    private var tokens: [NSObjectProtocol] = []

    init() {
        refreshRunning()
        let ws = NSWorkspace.shared.notificationCenter
        tokens.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.bundleID else { return }
            self?.refreshRunning()
            self?.onChange?()
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.bundleID else { return }
            self?.isRunning = false
            self?.pid = nil
            self?.state = .stopped
            self?.title = nil
            self?.artist = nil
            self?.onChange?()
        })
        let dnc = DistributedNotificationCenter.default()
        tokens.append(dnc.addObserver(forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] n in
            self?.handlePlayback(n.userInfo)
        })
    }

    deinit {
        for t in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(t)
            DistributedNotificationCenter.default().removeObserver(t)
        }
    }

    private func refreshRunning() {
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
        isRunning = app != nil
        pid = app?.processIdentifier
        if !isRunning { state = .stopped }
    }

    private func handlePlayback(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        switch (info["Player State"] as? String)?.lowercased() {
        case "playing": state = .playing
        case "paused": state = .paused
        case "stopped": state = .stopped
        default: break
        }
        if let t = info["Name"] as? String, !t.isEmpty { title = t }
        if let a = info["Artist"] as? String, !a.isEmpty { artist = a }
        if !isRunning { refreshRunning() }
        onChange?()
    }

    var nowPlaying: String? {
        guard let title else { return nil }
        if let artist { return "\(title) — \(artist)" }
        return title
    }
}
