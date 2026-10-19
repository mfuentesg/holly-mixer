import Foundation
import Observation
import SwiftUI

/// The language the app shows. "System" follows the device when it is Spanish, otherwise English.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english, spanish

    var id: String { rawValue }

    /// Shown in the language picker; each language is written in itself.
    var title: String {
        switch self {
        case .system: return L("System")
        case .english: return "English"
        case .spanish: return "Español"
        }
    }

    /// "en" or "es" once "System" is resolved.
    var code: String {
        switch self {
        case .english: return "en"
        case .spanish: return "es"
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("es") ? "es" : "en"
        }
    }
}

/// Holds the chosen language. SwiftUI texts (`Text("…")`, `Button("…")`, `Label("…")`…) are translated
/// from `es.lproj/Localizable.strings` using the `\.locale` set on the root view; plain `String` values
/// go through `L(_:)`. The English text is the key, so English needs no table.
@MainActor
@Observable
final class Localization {
    static let shared = Localization()
    nonisolated static let storageKey = "appLanguage"

    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
            ActiveLanguage.select(language.code)
        }
    }

    /// For SwiftUI's `\.locale` and for dates and numbers.
    var locale: Locale { Locale(identifier: language.code) }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey).flatMap(AppLanguage.init(rawValue:))
        language = stored ?? .system
        ActiveLanguage.select(language.code)
    }
}

/// The bundle that answers `L(_:)`: the `es.lproj` folder for Spanish, the main bundle otherwise.
/// A plain global so any thread can read it.
enum ActiveLanguage {
    static private(set) var code = "en"
    static private(set) var bundle = Bundle.main

    static func select(_ newCode: String) {
        code = newCode
        if newCode != "en", let path = Bundle.main.path(forResource: newCode, ofType: "lproj"),
           let languageBundle = Bundle(path: path) {
            bundle = languageBundle
        } else {
            bundle = Bundle.main
        }
    }

    static var locale: Locale { Locale(identifier: code) }
}

/// Translates a text that is not shown through `Text("…")`. Interpolated values work like in
/// `String(localized:)`: `L("Bus \(number)")` looks up "Bus %lld".
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: ActiveLanguage.bundle, locale: ActiveLanguage.locale)
}

extension Date {
    /// Date and time in the app's language, not the device's.
    func hollyMixer(date: Date.FormatStyle.DateStyle = .omitted, time: Date.FormatStyle.TimeStyle = .omitted) -> String {
        formatted(Date.FormatStyle(date: date, time: time).locale(ActiveLanguage.locale))
    }
}

/// Globe button that picks the app language (System, English or Español).
struct LanguageMenu: View {
    @Environment(Localization.self) private var localization

    var body: some View {
        Menu {
            Picker("Language", selection: Bindable(localization).language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textControl)
                .frame(width: 44, height: 44)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .accessibilityLabel("Language")
    }
}
