import Foundation

/// Named mapping profiles on disk.
///
/// Layout under `~/.config/ps2mc`:
///
///     profiles/<slug>.json   one profile each
///     state.json             which profile is active
///     config.json            the pre-profiles single config, migrated on first run
///
/// Profiles are plain `Config` files, so anything written by an older version — or by hand
/// — still loads, and a profile can be copied between machines on its own.
public final class ProfileStore {
    public struct Profile: Identifiable, Equatable {
        public let id: String       // slug, and the filename stem
        public var name: String     // what the UI shows
        public var url: URL
        /// Built-ins are restored if deleted and cannot be renamed in place.
        public var isBuiltIn: Bool
    }

    private struct State: Codable {
        var activeProfile: String?
    }

    public static let shared = ProfileStore()

    public private(set) var profiles: [Profile] = []
    public private(set) var activeID: String

    private let directory: URL
    private let profilesDirectory: URL
    private let stateURL: URL

    /// Slug of the shipped Minecraft mapping.
    public static let recommendedID = "minecraft-recommended"

    public init(directory: URL = Config.directory) {
        self.directory = directory
        self.profilesDirectory = directory.appendingPathComponent("profiles", isDirectory: true)
        self.stateURL = directory.appendingPathComponent("state.json")
        self.activeID = ProfileStore.recommendedID
        bootstrap()
    }

    // MARK: - Setup

    private func bootstrap() {
        try? FileManager.default.createDirectory(
            at: profilesDirectory, withIntermediateDirectories: true)

        // Ship the recommended mapping, refreshing it each launch so improvements reach
        // existing installs. Anything the user changes belongs in their own profile.
        let recommended = profilesDirectory
            .appendingPathComponent("\(Self.recommendedID).json")
        try? Config.minecraftRecommended.save(to: recommended)

        migrateLegacyConfigIfNeeded()
        reload()

        let state = (try? JSONDecoder().decode(
            State.self, from: Data(contentsOf: stateURL))) ?? State()
        if let active = state.activeProfile, profiles.contains(where: { $0.id == active }) {
            activeID = active
        } else {
            activeID = profiles.first?.id ?? Self.recommendedID
        }
    }

    /// Move a pre-profiles `config.json` into the profile folder rather than discarding or
    /// overwriting it — it is the user's existing tuning, and it should still be there
    /// after an upgrade.
    private func migrateLegacyConfigIfNeeded() {
        let legacy = directory.appendingPathComponent("config.json")
        let destination = profilesDirectory.appendingPathComponent("my-settings.json")
        guard FileManager.default.fileExists(atPath: legacy.path),
              !FileManager.default.fileExists(atPath: destination.path) else { return }
        do {
            try FileManager.default.copyItem(at: legacy, to: destination)
            // Keep the original in place: the CLI's --config still points at it, and
            // silently deleting someone's settings file is never the right move.
            var state = State()
            state.activeProfile = "my-settings"
            try? JSONEncoder().encode(state).write(to: stateURL)
        } catch {
            FileHandle.standardError.write(
                "ps2mc: could not migrate config.json — \(error.localizedDescription)\n"
                    .data(using: .utf8)!)
        }
    }

    public func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: profilesDirectory, includingPropertiesForKeys: nil)) ?? []
        profiles = files
            .filter { $0.pathExtension == "json" }
            .map { url in
                let id = url.deletingPathExtension().lastPathComponent
                return Profile(id: id, name: Self.displayName(for: id), url: url,
                               isBuiltIn: id == Self.recommendedID)
            }
            // Built-in first, then alphabetical — a stable order the UI can rely on.
            .sorted { ($0.isBuiltIn ? 0 : 1, $0.name) < ($1.isBuiltIn ? 0 : 1, $1.name) }
    }

    // MARK: - Access

    public func profile(id: String) -> Profile? { profiles.first { $0.id == id } }
    public var active: Profile? { profile(id: activeID) }

    public func url(for id: String) -> URL {
        profilesDirectory.appendingPathComponent("\(id).json")
    }

    public func load(id: String) -> Config {
        (try? Config.load(from: url(for: id))) ?? Config.minecraftRecommended
    }

    public func loadActive() -> Config { load(id: activeID) }

    public func setActive(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeID = id
        var state = State()
        state.activeProfile = id
        try? JSONEncoder().encode(state).write(to: stateURL)
    }

    // MARK: - Mutation

    @discardableResult
    public func create(name: String, from config: Config) throws -> Profile {
        let id = Self.slug(name)
        guard !id.isEmpty else { throw ProfileError.invalidName(name) }
        let destination = url(for: id)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ProfileError.alreadyExists(name)
        }
        try config.save(to: destination)
        reload()
        guard let created = profile(id: id) else { throw ProfileError.invalidName(name) }
        return created
    }

    public func save(_ config: Config, id: String) throws {
        guard id != Self.recommendedID else { throw ProfileError.builtInReadOnly }
        try config.save(to: url(for: id))
    }

    public func delete(id: String) throws {
        guard id != Self.recommendedID else { throw ProfileError.builtInReadOnly }
        try FileManager.default.removeItem(at: url(for: id))
        reload()
        if activeID == id { setActive(profiles.first?.id ?? Self.recommendedID) }
    }

    public func rename(id: String, to name: String) throws {
        guard id != Self.recommendedID else { throw ProfileError.builtInReadOnly }
        let config = load(id: id)
        let created = try create(name: name, from: config)
        try? FileManager.default.removeItem(at: url(for: id))
        reload()
        if activeID == id { setActive(created.id) }
    }

    // MARK: - Naming

    /// Filenames are slugs; the display name is recovered from the slug so a profile copied
    /// in by hand still shows up sensibly.
    public static func displayName(for id: String) -> String {
        if id == recommendedID { return "Minecraft (Recommended)" }
        return id.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    public static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let pieces = name.lowercased().unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
        return String(pieces).split(separator: "-").joined(separator: "-")
    }
}

public enum ProfileError: LocalizedError {
    case alreadyExists(String)
    case invalidName(String)
    case builtInReadOnly

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let name):
            return "a profile named “\(name)” already exists"
        case .invalidName(let name):
            return "“\(name)” is not a usable profile name — use letters or numbers"
        case .builtInReadOnly:
            return "the recommended profile is read-only; duplicate it to make changes"
        }
    }
}
