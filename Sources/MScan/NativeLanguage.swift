import AppKit
import MScanCore

/// AppKit creates its standard menu labels in the launch language. Refresh
/// titles on existing menus without replacing their targets or key equivalents.
@MainActor
final class NativeLanguage: NSObject {
    static let shared = NativeLanguage()
    private let aliases = L10n.menuTitleAliases()
    private var updating = false
    private var localeObserver: NSObjectProtocol?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(menuOpening(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                L10n.refresh()
                self?.refresh()
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(didLaunch(_:)),
            name: NSApplication.didFinishLaunchingNotification, object: nil)
    }

    @objc private func didLaunch(_ notification: Notification) { refresh() }

    static var fileDialogsNeedRelaunch: Bool {
        guard let launch = Bundle.main.preferredLocalizations.first else { return false }
        return Locale(identifier: launch).language.languageCode != L10n.locale.language.languageCode
    }

    func refresh() {
        update()
        // SwiftUI and AppKit can populate menus after the scene update.
        RunLoop.main.perform(inModes: [.default, .eventTracking]) { [weak self] in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    @objc private func menuOpening(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        var root = menu
        while let parent = root.supermenu { root = parent }
        guard root === NSApp.mainMenu else { return }
        refresh()
    }

    private func update() {
        guard !updating, let main = NSApp.mainMenu else { return }
        updating = true
        defer { updating = false }
        for (index, item) in main.items.enumerated() {
            guard let menu = item.submenu else { continue }
            let key = aliases[item.title]
            guard index == 0 || ["File", "Edit", "View", "Window", "Help"].contains(key) else { continue }
            if let key { setTitle(L10n.text(key, table: "NativeMenu"), on: item) }
            localize(menu, formattedKeys: index == 0 ? ["About %@", "Hide %@", "Quit %@"] :
                        key == "Window" ? ["Move All to %@", "Move to %@"] : [])
        }
    }

    private func localize(_ menu: NSMenu, formattedKeys: [String]) {
        // Services belong to their providers. Window names and the names of
        // files are data, even when they happen to match a standard command.
        guard menu !== NSApp.servicesMenu else { return }
        for item in menu.items where !item.isSeparatorItem {
            if item.action == #selector(NSWindow.makeKeyAndOrderFront(_:)) { continue }
            if let key = aliases[item.title] {
                setTitle(L10n.text(key, table: "NativeMenu"), on: item)
            } else if let title = formattedTitle(item.title, keys: formattedKeys) {
                setTitle(title, on: item)
            }
            if let submenu = item.submenu {
                // SwiftUI updates MScan's own commands when those menus open.
                guard item.menu === NSApp.mainMenu || aliases[submenu.title] != nil || submenu.title.isEmpty else { continue }
                localize(submenu, formattedKeys: [])
            }
        }
    }

    private func formattedTitle(_ title: String, keys: [String]) -> String? {
        for (pattern, key) in aliases where keys.contains(key) {
            guard let placeholder = pattern.range(of: "%@") else { continue }
            let prefix = pattern[..<placeholder.lowerBound], suffix = pattern[placeholder.upperBound...]
            guard title.hasPrefix(prefix), title.hasSuffix(suffix), title.count > prefix.count + suffix.count else { continue }
            let name = String(title.dropFirst(prefix.count).dropLast(suffix.count))
            return L10n.format(key, name, table: "NativeMenu")
        }
        return nil
    }

    private func setTitle(_ title: String, on item: NSMenuItem) {
        if item.title != title { item.title = title }
        if let menu = item.submenu, menu.title != title { menu.title = title }
    }
}
