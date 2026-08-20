import Foundation
import Security
import os
import os.log

private let settingsLog = OSLog(subsystem: "com.inhaq.fluent", category: "Settings")

enum AppSettingsStorage {
    private static let bundleID = Bundle.main.bundleIdentifier ?? "com.inhaq.fluent"

    /// In-memory mirror of the settings file, plus whether the one-time Keychain
    /// migration has run.
    ///
    /// Every `load` previously read and JSON-decoded the file **twice** — once
    /// inside the migration check and once for the value itself — and the
    /// migration check re-ran forever after completing. `AppState.init()` makes
    /// four `load` calls, so launch paid eight file reads and eight decodes for
    /// a file that is a few hundred bytes. This caches it instead.
    private struct Cache {
        var settings: [String: String]?
        var migrationChecked = false
    }

    private static let cache = OSAllocatedUnfairLock(initialState: Cache())

    /// Resolved once. The previous computed property ran `fileExists` and
    /// possibly `createDirectory` on every access, and was touched twice per
    /// load/save.
    private static let storageDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent(AppName.displayName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    private static let settingsFileURL: URL = storageDirectory.appendingPathComponent(".settings")

    // MARK: - Public API

    static func load(account: String) -> String? {
        migrateFromKeychainIfNeeded(account: account)
        return cachedSettings()[account]
    }

    /// Persists `value`. Returns `false` if the write failed, in which case the
    /// value is *not* cached and a subsequent `load` will report what is
    /// actually on disk.
    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        mutate { $0[account] = value }
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        mutate { $0.removeValue(forKey: account) }
    }

    // MARK: - File I/O

    /// The settings dictionary, reading from disk at most once per process.
    private static func cachedSettings() -> [String: String] {
        cache.withLock { state in
            if let settings = state.settings { return settings }
            let settings = readSettingsFromDisk()
            state.settings = settings
            return settings
        }
    }

    /// Applies `transform` to the settings and persists the result, committing
    /// to the in-memory cache **only if the write succeeded**.
    ///
    /// Committing first would make a failed save look successful until the next
    /// launch: reads would be served the value that never reached disk. On
    /// failure the cache is invalidated instead, so the next read goes back to
    /// disk and reports what is actually stored.
    ///
    /// The whole read–modify–write runs under the cache lock, not just the two
    /// ends of it. Saving the API key and the base URL concurrently otherwise
    /// interleaves — both read the same snapshot, each writes the file with only
    /// its own edit applied, and the loser's setting is silently lost.
    @discardableResult
    private static func mutate(_ transform: (inout [String: String]) -> Void) -> Bool {
        cache.withLock { state -> Bool in
            var updated = state.settings ?? readSettingsFromDisk()
            transform(&updated)

            do {
                try writeSettings(updated)
            } catch {
                state.settings = nil
                os_log(
                    .error,
                    log: settingsLog,
                    "Failed to persist settings: %{public}@",
                    error.localizedDescription
                )
                return false
            }

            state.settings = updated
            return true
        }
    }

    private static func readSettingsFromDisk() -> [String: String] {
        guard let data = try? Data(contentsOf: settingsFileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    /// Writes the settings file atomically. Throws so callers can tell a failed
    /// save from a successful one.
    private static func writeSettings(_ dict: [String: String]) throws {
        let data = try JSONEncoder().encode(dict)
        let url = settingsFileURL
        try data.write(to: url, options: [.atomic])
        // Restrict to owner-only read/write (0600). An atomic write replaces the
        // inode, so the mode has to be reapplied after every write. A failure
        // here means the data landed but the permissions did not — worth
        // logging, but not worth reporting the save as failed.
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            os_log(
                .error,
                log: settingsLog,
                "Settings file written but could not be restricted to 0600: %{public}@",
                error.localizedDescription
            )
        }
    }

    // MARK: - One-time migration from Keychain

    private static let migrationDoneKey = "keychain_migration_done"

    private static func migrateFromKeychainIfNeeded(account: String) {
        // Short-circuit on a cached flag so this costs nothing after the first
        // call, instead of re-reading the file on every load.
        let alreadyChecked = cache.withLock { state -> Bool in
            if state.migrationChecked { return true }
            if let settings = state.settings, settings[migrationDoneKey] != nil {
                state.migrationChecked = true
                return true
            }
            return false
        }
        if alreadyChecked { return }

        if cachedSettings()[migrationDoneKey] != nil {
            cache.withLock { $0.migrationChecked = true }
            return
        }

        let keychainValue = loadFromKeychain(account: account)
        let hasValue = keychainValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        let committed = mutate { settings in
            if hasValue, let keychainValue {
                settings[account] = keychainValue
            }
            // Marked done either way, so a machine with nothing in the Keychain
            // never pays for the lookup again.
            settings[migrationDoneKey] = "true"
        }

        guard committed else {
            // The settings file did not persist. Deleting the Keychain item now
            // would destroy the only surviving copy of the user's API key, and
            // marking the migration checked would stop us ever retrying. Leave
            // both alone so the next launch tries again.
            os_log(
                .error,
                log: settingsLog,
                "Keychain migration aborted: settings write failed, legacy item left in place"
            )
            return
        }

        cache.withLock { $0.migrationChecked = true }
        if hasValue {
            deleteFromKeychain(account: account)
        }
    }

    // MARK: - Legacy Keychain helpers (for migration only)

    private static func loadFromKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: bundleID,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func deleteFromKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: bundleID,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
