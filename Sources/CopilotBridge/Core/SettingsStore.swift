import Foundation

/// Loads/saves AppSettings to Application Support as JSON.
enum SettingsStore {
    /// Overridable for tests. Defaults to the real Application Support location.
    nonisolated(unsafe) static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CopilotBridge", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("settings.json")
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    static func save(_ settings: AppSettings) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Safety net: if we're about to write empty profiles over a file that currently
        // has profiles, back the old file up first so the user can recover. Cheap and
        // only triggers on the (rare, unexpected) profile-clearing write.
        if settings.profiles.isEmpty, existingHasProfiles() {
            ConfigWriter.backup(fileURL)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    private static func existingHasProfiles() -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let old = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return false
        }
        return !old.profiles.isEmpty
    }
}
