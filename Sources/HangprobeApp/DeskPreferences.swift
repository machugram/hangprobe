import Foundation
import HangprobeCore

/// Persists desk-session state so Hangprobe opens where you left off.
enum DeskPreferences {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let selectionHint = "hangprobe.desk.selectionHint"
        static let seconds = "hangprobe.desk.seconds"
        static let threshold = "hangprobe.desk.threshold"
        static let appearance = "hangprobe.desk.appearance"
        static let inspectorTab = "hangprobe.desk.inspectorTab"
        static let leafFirst = "hangprobe.desk.leafFirst"
        static let stackFilter = "hangprobe.desk.stackFilter"
    }

    struct SelectionHint: Codable, Equatable {
        var place: String
        var bundleID: String?
        var app: String
        var serial: String?
    }

    static var selectionHint: SelectionHint? {
        get {
            guard let data = defaults.data(forKey: Key.selectionHint) else { return nil }
            return try? JSONDecoder().decode(SelectionHint.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.selectionHint)
            } else {
                defaults.removeObject(forKey: Key.selectionHint)
            }
        }
    }

    static var seconds: Int {
        get {
            let value = defaults.object(forKey: Key.seconds) as? Int ?? 1
            return (1...3).contains(value) ? value : 1
        }
        set { defaults.set(newValue, forKey: Key.seconds) }
    }

    static var threshold: Int {
        get {
            let value = defaults.object(forKey: Key.threshold) as? Int ?? 250
            return (50...3000).contains(value) ? value : 250
        }
        set { defaults.set(newValue, forKey: Key.threshold) }
    }

    static var appearance: AppearanceMode {
        get {
            guard let raw = defaults.string(forKey: Key.appearance),
                  let mode = AppearanceMode(rawValue: raw) else { return .system }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Key.appearance) }
    }

    static var inspectorTab: InspectorTab {
        get {
            guard let raw = defaults.string(forKey: Key.inspectorTab),
                  let tab = InspectorTab(rawValue: raw) else { return .appFocus }
            return tab
        }
        set { defaults.set(newValue.rawValue, forKey: Key.inspectorTab) }
    }

    static var leafFirst: Bool {
        get {
            if defaults.object(forKey: Key.leafFirst) == nil { return true }
            return defaults.bool(forKey: Key.leafFirst)
        }
        set { defaults.set(newValue, forKey: Key.leafFirst) }
    }

    static var stackFilter: String {
        get { defaults.string(forKey: Key.stackFilter) ?? "" }
        set { defaults.set(newValue, forKey: Key.stackFilter) }
    }

    static func hint(from app: RunningApp) -> SelectionHint {
        SelectionHint(
            place: app.place.rawValue,
            bundleID: app.bundleID,
            app: app.app,
            serial: app.serial
        )
    }

    static func match(_ hint: SelectionHint, in apps: [RunningApp]) -> RunningApp? {
        if let bundle = hint.bundleID, !bundle.isEmpty,
           let hit = apps.first(where: {
               $0.bundleID == bundle && $0.place.rawValue == hint.place && $0.serial == hint.serial
           }) {
            return hit
        }
        return apps.first {
            $0.app == hint.app && $0.place.rawValue == hint.place && $0.serial == hint.serial
        }
    }
}
