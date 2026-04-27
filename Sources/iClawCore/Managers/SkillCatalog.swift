import Foundation

// MARK: - Catalog Models

/// A single entry in the remote skill catalog index.
struct CatalogSkill: Codable, Sendable, Identifiable {
    var id: String { filename }
    let name: String
    let filename: String
    let description: String
    let version: Int
    let handle: String?
}

/// The top-level catalog response from geticlaw.com/skills/catalog.json.
struct SkillCatalogIndex: Codable, Sendable {
    let version: Int
    let skills: [CatalogSkill]
}

// MARK: - Installed Catalog Record

/// Tracks a skill installed from the remote catalog (persisted in UserDefaults).
struct InstalledCatalogSkill: Codable, Sendable, Identifiable {
    var id: String { filename }
    let name: String
    let filename: String
    let version: Int
    let dateInstalled: Date
}

// MARK: - Skill Catalog

/// Fetches the remote skill catalog and manages install/uninstall of catalog skills.
actor SkillCatalog {
    static let shared = SkillCatalog()

    private static let catalogURL = URL(string: "\(AppConfig.websiteURL)/skills/catalog.json")!
    private static let skillsBaseURL = URL(string: "\(AppConfig.websiteURL)/skills/")!
    private static let installedKey = "iClaw_installedCatalogSkills"

    /// Skills directory path (computed independently to avoid MainActor isolation).
    private static let skillsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("iClaw/Skills")
    }()

    private let session: URLSession

    private(set) var catalog: [CatalogSkill] = []
    private(set) var installedSkills: [InstalledCatalogSkill] = []
    private(set) var isFetching = false
    private(set) var lastError: String?

    init(session: URLSession = .shared) {
        self.session = session
        self.installedSkills = Self.loadInstalled()
    }

    // MARK: - Fetch Catalog

    /// Fetches the skill catalog index from the remote server.
    func fetchCatalog() async {
        isFetching = true
        lastError = nil
        defer { isFetching = false }

        do {
            var request = URLRequest(url: Self.catalogURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                lastError = "Server returned an error"
                return
            }

            let index = try JSONDecoder().decode(SkillCatalogIndex.self, from: data)

            // Filter out catalog skills that duplicate locally bundled skills
            let localNames = Set(await SkillLoader.shared.loadedSkills.map { $0.name.lowercased() })
            catalog = index.skills.filter { !localNames.contains($0.name.lowercased()) }

            let filtered = index.skills.count - self.catalog.count
            Log.engine.debug("Fetched skill catalog: \(self.catalog.count) skills (filtered \(filtered) duplicates), version \(index.version)")
        } catch {
            lastError = error.localizedDescription
            Log.engine.debug("Failed to fetch skill catalog: \(error)")
        }
    }

    // MARK: - Install / Uninstall

    /// Downloads and installs a skill from the catalog.
    func install(_ skill: CatalogSkill) async throws {
        // Silently skip if this duplicates a locally bundled skill
        let localNames = Set(await SkillLoader.shared.loadedSkills.map { $0.name.lowercased() })
        if localNames.contains(skill.name.lowercased()) {
            Log.engine.debug("Skipping catalog install of '\(skill.name)': duplicates a built-in skill")
            return
        }

        let fileURL = Self.skillsBaseURL.appendingPathComponent(skill.filename)

        let (data, response) = try await session.data(from: fileURL)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SkillCatalogError.downloadFailed
        }

        guard let content = String(data: data, encoding: .utf8), !content.isEmpty else {
            throw SkillCatalogError.invalidContent
        }

        // Write to imported skills directory
        let dir = Self.skillsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let destination = dir.appendingPathComponent(skill.filename)
        try content.write(to: destination, atomically: true, encoding: .utf8)

        // Track installation
        let record = InstalledCatalogSkill(
            name: skill.name,
            filename: skill.filename,
            version: skill.version,
            dateInstalled: Date()
        )
        installedSkills.removeAll { $0.filename == skill.filename }
        installedSkills.append(record)
        persistInstalled()

        Log.engine.debug("Installed catalog skill: \(skill.name)")
    }

    /// Removes an installed catalog skill.
    func uninstall(_ skill: CatalogSkill) {
        // Remove file
        let filePath = Self.skillsDirectory.appendingPathComponent(skill.filename)
        try? FileManager.default.removeItem(at: filePath)

        // Remove tracking record
        installedSkills.removeAll { $0.filename == skill.filename }
        persistInstalled()

        Log.engine.debug("Uninstalled catalog skill: \(skill.name)")
    }

    /// Whether a catalog skill is currently installed.
    func isInstalled(_ skill: CatalogSkill) -> Bool {
        installedSkills.contains { $0.filename == skill.filename }
    }

    /// Whether an installed skill has a newer version available.
    func hasUpdate(_ skill: CatalogSkill) -> Bool {
        guard let installed = installedSkills.first(where: { $0.filename == skill.filename }) else {
            return false
        }
        return skill.version > installed.version
    }

    // MARK: - Persistence

    private func persistInstalled() {
        if let data = try? JSONEncoder().encode(installedSkills) {
            UserDefaults.standard.set(data, forKey: Self.installedKey)
        }
    }

    private static func loadInstalled() -> [InstalledCatalogSkill] {
        guard let data = UserDefaults.standard.data(forKey: installedKey) else { return [] }
        return (try? JSONDecoder().decode([InstalledCatalogSkill].self, from: data)) ?? []
    }
}

// MARK: - Errors

enum SkillCatalogError: LocalizedError {
    case downloadFailed
    case invalidContent
    var errorDescription: String? {
        switch self {
        case .downloadFailed: "Failed to download skill file"
        case .invalidContent: "Skill file was empty or invalid"
        }
    }
}
