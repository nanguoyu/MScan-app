import Foundation
import Observation
import os

public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    public static let preferenceKey = "interfaceLanguage"

    public static var current: Self {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    public func identifier(preferences: [String]) -> String {
        guard self == .system else { return rawValue }
        for preference in preferences {
            switch Locale(identifier: preference).language.languageCode?.identifier.lowercased() {
            case "zh": return Self.simplifiedChinese.rawValue
            case "en": return Self.english.rawValue
            default: continue
            }
        }
        return Self.english.rawValue
    }

    // Capture launch arguments before installing a volatile override for AppKit.
    // The global and app-specific preferences remain owned by System Settings.
    private static let launchArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["AppleLanguages"] as? [String]
    private static let launchPreferences = Locale.preferredLanguages

    private static var systemPreferences: [String] {
        if let launchArguments { return launchArguments }
        let defaults = UserDefaults.standard
        if let id = Bundle.main.bundleIdentifier,
           let preferred = defaults.persistentDomain(forName: id)?["AppleLanguages"] as? [String] { return preferred }
        return defaults.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? launchPreferences
    }

    /// Set only this process's argument domain, before AppKit loads its menus.
    public static func prepareForLaunch() {
        let preferred = systemPreferences
        _ = launchPreferences
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleLanguages"] = [current.identifier(preferences: preferred)]
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    public var resolvedLocale: Locale {
        let language = identifier(preferences: Self.systemPreferences)
        let region = Locale.autoupdatingCurrent.region?.identifier
        return Locale(identifier: region.map { language + "_" + $0 } ?? language)
    }
}

/// Reading a translation registers a dependency on the current locale with
/// SwiftUI, including for views that obtain text from an observable scanner.
/// Network tasks read the same setting without hopping to the main actor.
private final class LanguageContext: Observable, Sendable {
    private let registrar = ObservationRegistrar()
    private let storage = OSAllocatedUnfairLock(initialState: AppLanguage.current.resolvedLocale)

    var locale: Locale {
        registrar.access(self, keyPath: \.locale)
        return storage.withLock { $0 }
    }

    @MainActor func select(_ value: Locale) {
        guard storage.withLock({ $0 != value }) else { return }
        registrar.withMutation(of: self, keyPath: \.locale) {
            storage.withLock { $0 = value }
        }
    }
}

public enum L10n {
    private static let context = LanguageContext()
    @TaskLocal public static var languageOverride: AppLanguage?
    public static var locale: Locale { languageOverride?.resolvedLocale ?? context.locale }

    @MainActor public static func refresh(_ choice: AppLanguage = .current) {
        context.select(choice.resolvedLocale)
    }

    private static let bundles: [String: Bundle] = {
        let resources = Bundle.module
        var result: [String: Bundle] = [:]
        for language in [AppLanguage.english, .simplifiedChinese] {
            guard let folder = resources.localizations.first(where: {
                $0.caseInsensitiveCompare(language.rawValue) == .orderedSame
            }), let url = resources.resourceURL?.appendingPathComponent(folder + ".lproj"),
                  let bundle = Bundle(url: url) else { continue }
            result[language.rawValue] = bundle
        }
        return result
    }()

    /// Known standard menu titles are matched in either supported language.
    /// Do not translate arbitrary document names or service-provided data.
    public static func menuTitleAliases() -> [String: String] {
        var aliases: [String: String] = [:]
        for bundle in bundles.values {
            guard let url = bundle.url(forResource: "NativeMenu", withExtension: "strings"),
                  let data = try? Data(contentsOf: url),
                  let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { continue }
            for (key, title) in values { aliases[title] = key }
        }
        return aliases
    }

    public static func text(_ key: String, table: String) -> String {
        let code = locale.language.languageCode == .chinese ? AppLanguage.simplifiedChinese.rawValue : AppLanguage.english.rawValue
        return bundles[code]?.localizedString(forKey: key, value: nil, table: table) ?? key
    }

    /// Translate app errors on demand. Cocoa can supply a message in the OS
    /// language, so provide our own fallback for system file and decoding errors.
    public static func errorDescription(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            let key: String?
            switch CocoaError.Code(rawValue: ns.code) {
            case .fileReadNoPermission: key = "You don’t have permission to read this file."
            case .fileWriteNoPermission: key = "You don’t have permission to write this file."
            case .fileReadNoSuchFile, .fileNoSuchFile: key = "The file could not be found."
            case .fileWriteOutOfSpace: key = "The disk is full."
            case .fileWriteVolumeReadOnly: key = "The volume is read-only."
            case .fileReadCorruptFile: key = "The file is damaged or unreadable."
            default: key = nil
            }
            if let key { return text(key, table: "Application") }
        }
        if let native = Bundle.main.preferredLocalizations.first,
           Locale(identifier: native).language.languageCode == locale.language.languageCode {
            return ns.localizedDescription
        }
        return format("The operation failed (%1$@, code %2$ld).", ns.domain, ns.code, table: "Application")
    }

    public static func format(_ key: String, _ arguments: CVarArg..., table: String) -> String {
        String(format: text(key, table: table), locale: locale, arguments: arguments)
    }
}
