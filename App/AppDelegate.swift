import AppKit
import SwiftUI
import SpectreCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private(set) var model: AppModel!
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var measurement: MeasurementRun?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        buildMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Spectre")
            b.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let args = CommandLine.arguments
        if args.contains("--demo") { model.settings.demoMode = true }
        if let i = args.firstIndex(of: "--measure"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            let report = args.firstIndex(of: "--report").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "spectre-cpu.md"
            showMainWindow()
            measurement = MeasurementRun(delegate: self, seconds: secs, reportPath: report)
            measurement?.start()
            return
        }
        showMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: - Windows

    @objc func showMainWindow() {
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Spectre"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(red: 0.03, green: 0.035, blue: 0.045, alpha: 1)
            w.minSize = NSSize(width: 680, height: 400)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: MainView(model: model, settings: model.settings,
                                                             openSettings: { [weak self] in self?.showSettings() }))
            w.setFrameAutosaveName("SpectreMain")
            if !w.setFrameUsingName("SpectreMain") { w.center() }
            mainWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        model.windowView?.refreshVisibility()
    }

    func closeMainWindow() { mainWindow?.close() }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Réglages de Spectre"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: SettingsView(model: model, settings: model.settings,
                                                                 runDiagnostics: { [weak self] in self?.runDiagnostics() }))
            w.center()
            settingsWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.model.windowView?.refreshVisibility()
            let anyVisible = [self.mainWindow, self.settingsWindow].contains { $0?.isVisible == true }
            if !anyVisible { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func windowDidMiniaturize(_ notification: Notification) { model.windowView?.refreshVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { model.windowView?.refreshVisibility() }

    // MARK: - Diagnostics

    @objc func runDiagnostics() {
        let alert = NSAlert()
        alert.messageText = "Diagnostic en cours…"
        alert.informativeText = "Mesure de la précision et de la consommation pendant 10 secondes."
        Diagnostics.run(model: model, seconds: 10) { report in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(report, forType: .string)
            let done = NSAlert()
            done.messageText = "Diagnostic terminé (copié dans le presse-papiers)"
            done.informativeText = report
            done.runModal()
        }
    }

    // MARK: - Menus

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "À propos de Spectre", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Réglages…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Masquer Spectre", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quitter Spectre", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Fenêtre")
        windowMenu.addItem(withTitle: "Réduire", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Spectre", action: #selector(showMainWindow), keyEquivalent: "1").target = self
        windowItem.submenu = windowMenu
        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = model.settings
        let status = NSMenuItem(title: model.status.message, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let np = model.nowPlaying {
            let item = NSMenuItem(title: np, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(item("Ouvrir Spectre", #selector(showMainWindow)))

        let wp = item("Fond d'écran", #selector(toggleWallpaper))
        wp.state = s.wallpaperEnabled ? .on : .off
        menu.addItem(wp)
        let screens = WallpaperController.screens()
        if screens.count > 1 {
            let sub = NSMenu()
            for sc in screens {
                let it = item(sc.name, #selector(chooseScreen(_:)))
                it.representedObject = sc.id
                it.state = (s.wallpaperScreen == sc.id || (s.wallpaperScreen.isEmpty && sc.id == screens.first?.id)) ? .on : .off
                sub.addItem(it)
            }
            let parent = NSMenuItem(title: "Écran du fond d'écran", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        let modes = NSMenu()
        for m in VisualMode.allCases {
            let it = item(m.label, #selector(chooseWallpaperMode(_:)))
            it.representedObject = m.rawValue
            it.state = s.wallpaperMode == m ? .on : .off
            modes.addItem(it)
        }
        let modesParent = NSMenuItem(title: "Visuel du fond d'écran", action: nil, keyEquivalent: "")
        modesParent.submenu = modes
        menu.addItem(modesParent)
        let themes = NSMenu()
        for t in ThemeKind.allCases {
            let it = item(t.label, #selector(chooseTheme(_:)))
            it.representedObject = t.rawValue
            it.state = s.wallpaperTheme == t ? .on : .off
            themes.addItem(it)
        }
        let themesParent = NSMenuItem(title: "Thème du fond d'écran", action: nil, keyEquivalent: "")
        themesParent.submenu = themes
        menu.addItem(themesParent)
        let text = item("Afficher le texte sur le fond d'écran", #selector(toggleWallpaperText))
        text.state = (s.wallpaperShowFrequency || s.wallpaperShowNote || s.wallpaperShowTitle) ? .on : .off
        menu.addItem(text)

        menu.addItem(.separator())
        let demo = item("Mode démo", #selector(toggleDemo))
        demo.state = s.demoMode ? .on : .off
        menu.addItem(demo)
        menu.addItem(item("Réglages…", #selector(showSettings), key: ","))
        menu.addItem(item("Diagnostic…", #selector(runDiagnostics)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quitter Spectre", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleWallpaper() { model.settings.wallpaperEnabled.toggle() }
    @objc private func toggleDemo() { model.settings.demoMode.toggle() }
    @objc private func toggleWallpaperText() {
        let s = model.settings
        let on = !(s.wallpaperShowFrequency || s.wallpaperShowNote || s.wallpaperShowTitle)
        s.wallpaperShowFrequency = on; s.wallpaperShowNote = on; s.wallpaperShowTitle = on
    }
    @objc private func chooseScreen(_ sender: NSMenuItem) {
        model.settings.wallpaperScreen = sender.representedObject as? String ?? ""
        model.settings.wallpaperEnabled = true
    }
    @objc private func chooseWallpaperMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = VisualMode(rawValue: raw) { model.settings.wallpaperMode = m }
    }
    @objc private func chooseTheme(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let t = ThemeKind(rawValue: raw) { model.settings.wallpaperTheme = t }
    }
}
