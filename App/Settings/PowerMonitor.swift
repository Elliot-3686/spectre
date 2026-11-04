import AppKit
import IOKit.ps

/// Battery / Low Power Mode / lock / sleep / screensaver — all from system
/// notifications (IOKit power-source callback, workspace and distributed
/// notifications). No polling.
final class PowerMonitor {
    private(set) var onBattery = false
    private(set) var lowPowerMode = false
    private(set) var screenLocked = false
    private(set) var screensAsleep = false
    private(set) var systemAsleep = false
    private(set) var screensaver = false

    var onChange: (() -> Void)?

    /// Nobody can see anything: stop everything.
    var suspended: Bool { screenLocked || screensAsleep || systemAsleep || screensaver }
    var prefersEconomy: Bool { onBattery || lowPowerMode }

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var runLoopSource: CFRunLoopSource?

    init() {
        refreshPower()
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(ws, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        observe(ws, NSWorkspace.willSleepNotification) { $0.systemAsleep = true }
        observe(ws, NSWorkspace.didWakeNotification) { $0.systemAsleep = false }
        observe(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.screenLocked = true }
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.screenLocked = false }

        let dnc = DistributedNotificationCenter.default()
        observe(dnc, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
        observe(dnc, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false }
        observe(dnc, Notification.Name("com.apple.screensaver.didstart")) { $0.screensaver = true }
        observe(dnc, Notification.Name("com.apple.screensaver.didstop")) { $0.screensaver = false }

        observe(NotificationCenter.default, Notification.Name.NSProcessInfoPowerStateDidChange) {
            $0.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                me.refreshPower()
                me.onChange?()
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            runLoopSource = src
        }
    }

    deinit {
        for (c, t) in tokens { c.removeObserver(t) }
        if let s = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ apply: @escaping (PowerMonitor) -> Void) {
        let t = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            apply(self)
            self.onChange?()
        }
        tokens.append((center, t))
    }

    private func refreshPower() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { onBattery = false; return }
        if let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? {
            onBattery = type == kIOPSBatteryPowerValue
        }
    }
}
