import SwiftUI

// MARK: - Skills Settings

struct SkillsSettingsView: View {
    private var settings = SkillSettingsManager.shared
    private var skillLoader = SkillLoader.shared
    private var settingsNav = SettingsNavigation.shared
    @State private var showFileImporter = false
    @State private var importError: String?
    @State private var newFeedURL = ""
    @State private var isValidating = false
    @State private var validationError: String?
    @State private var catalogSkills: [CatalogSkill] = []
    @State private var catalogInstalled: Set<String> = []
    @State private var catalogUpdates: Set<String> = []
    @State private var isFetchingCatalog = false
    @State private var catalogError: String?
    @State private var installingSkill: String?

    var body: some View {
        Form {
            Section(String(localized: "Skills", bundle: .iClawCore)) {
                ForEach(skillLoader.loadedSkills) { skill in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(skill.name)
                            Text(skill.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if !skill.isBuiltIn {
                            Button {
                                skillLoader.removeImportedSkill(name: skill.name)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                                    .accessibilityHidden(true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(String(format: String(localized: "Remove %@", bundle: .iClawCore), skill.name)))
                        }
                        Toggle(skill.name, isOn: Binding(
                            get: { !settings.disabledSkillNames.contains(skill.name) },
                            set: { enabled in
                                if enabled {
                                    settings.disabledSkillNames.remove(skill.name)
                                } else {
                                    settings.disabledSkillNames.insert(skill.name)
                                }
                            }
                        ))
                        .labelsHidden()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(Text(settings.disabledSkillNames.contains(skill.name) ? "Off" : "On"))
                }

                Button(String(localized: "Import Skill...", bundle: .iClawCore)) {
                    showFileImporter = true
                }
                .fileImporter(
                    isPresented: $showFileImporter,
                    allowedContentTypes: [.plainText]
                ) { result in
                    switch result {
                    case .success(let url):
                        guard url.startAccessingSecurityScopedResource() else { return }
                        defer { url.stopAccessingSecurityScopedResource() }
                        Task {
                            do {
                                _ = try await skillLoader.importSkill(from: url)
                                importError = nil
                            } catch {
                                importError = error.localizedDescription
                            }
                        }
                    case .failure(let error):
                        importError = error.localizedDescription
                    }
                }

                if let importError {
                    Text(importError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section(String(localized: "Skill Catalog", bundle: .iClawCore)) {
                if isFetchingCatalog {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading catalog…", bundle: .iClawCore)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let catalogError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(catalogError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(String(localized: "Retry", bundle: .iClawCore)) { Task { await refreshCatalog() } }
                } else if catalogSkills.isEmpty {
                    Text("No skills available", bundle: .iClawCore)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(catalogSkills) { skill in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(skill.name)
                                Text(skill.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if installingSkill == skill.filename {
                                ProgressView()
                                    .controlSize(.small)
                            } else if catalogInstalled.contains(skill.filename) {
                                if catalogUpdates.contains(skill.filename) {
                                    Button(String(localized: "Update", bundle: .iClawCore)) {
                                        Task { await installCatalogSkill(skill) }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                Button {
                                    Task { await uninstallCatalogSkill(skill) }
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .contentShape(Rectangle())
                                        .accessibilityHidden(true)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(String(format: String(localized: "Remove %@", bundle: .iClawCore), skill.name)))
                            } else {
                                Button(String(localized: "Get", bundle: .iClawCore)) {
                                    Task { await installCatalogSkill(skill) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }

            Section(String(localized: "News Sources", bundle: .iClawCore)) {
                // Built-in feeds
                ForEach(NewsTool.builtInFeeds, id: \.url) { feed in
                    feedRow(name: feed.name, url: feed.url, iconDomain: feed.iconDomain, isDeletable: false)
                }

                // Custom feeds
                ForEach(settings.customFeeds) { feed in
                    feedRow(name: feed.name, url: feed.url, iconDomain: nil, isDeletable: true)
                }

                // Add feed input
                HStack {
                    TextField(String(localized: "RSS or website URL", bundle: .iClawCore), text: $newFeedURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { validateAndAdd() }
                    if isValidating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button(String(localized: "Add", bundle: .iClawCore)) { validateAndAdd() }
                        .disabled(newFeedURL.isEmpty || isValidating)
                }

                if let validationError {
                    Text(validationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task { await refreshCatalog() }
        .task(id: settingsNav.pendingSkillImport) {
            guard let url = settingsNav.pendingSkillImport else { return }
            settingsNav.pendingSkillImport = nil
            do {
                _ = try await skillLoader.importSkill(from: url)
                importError = nil
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    // MARK: - Catalog Actions

    private func refreshCatalog() async {
        isFetchingCatalog = true
        catalogError = nil
        let catalog = SkillCatalog.shared
        await catalog.fetchCatalog()
        catalogSkills = await catalog.catalog
        catalogError = await catalog.lastError
        var installed = Set<String>()
        var updates = Set<String>()
        for skill in catalogSkills {
            if await catalog.isInstalled(skill) { installed.insert(skill.filename) }
            if await catalog.hasUpdate(skill) { updates.insert(skill.filename) }
        }
        catalogInstalled = installed
        catalogUpdates = updates
        isFetchingCatalog = false
    }

    private func installCatalogSkill(_ skill: CatalogSkill) async {
        installingSkill = skill.filename
        do {
            try await SkillCatalog.shared.install(skill)
            // Reload into SkillLoader
            let dir = SkillSettingsManager.importedSkillsDirectory
            let fileURL = dir.appendingPathComponent(skill.filename)
            var loaded = try await SkillParser().parseSkill(from: fileURL)
            loaded.isBuiltIn = false
            skillLoader.loadedSkills.removeAll { $0.name == loaded.name && !$0.isBuiltIn }
            skillLoader.loadedSkills.append(loaded)
            catalogInstalled.insert(skill.filename)
            catalogUpdates.remove(skill.filename)
        } catch {
            importError = error.localizedDescription
        }
        installingSkill = nil
    }

    private func uninstallCatalogSkill(_ skill: CatalogSkill) async {
        await SkillCatalog.shared.uninstall(skill)
        skillLoader.loadedSkills.removeAll { $0.name == skill.name && !$0.isBuiltIn }
        catalogInstalled.remove(skill.filename)
        catalogUpdates.remove(skill.filename)
    }

    @ViewBuilder
    private func feedRow(name: String, url: String, iconDomain: String? = nil, isDeletable: Bool) -> some View {
        HStack {
            let domain = iconDomain ?? URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "")
            if let domain,
               let faviconURL = URL(string: "https://icons.duckduckgo.com/ip3/\(domain).ico") {
                AsyncImage(url: faviconURL) { image in
                    image.resizable()
                } placeholder: {
                    Image(systemName: "dot.radiowaves.up.forward")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text(name)
            Spacer()
            if isDeletable {
                Button {
                    settings.customFeeds.removeAll { $0.url == url }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(format: String(localized: "Remove %@", bundle: .iClawCore), name)))
            }
            Toggle("", isOn: Binding(
                get: { !settings.disabledFeedURLs.contains(url) },
                set: { enabled in
                    if enabled {
                        settings.disabledFeedURLs.remove(url)
                    } else {
                        settings.disabledFeedURLs.insert(url)
                    }
                }
            ))
            .labelsHidden()
        }
    }

    private func validateAndAdd() {
        let urlString = newFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return }
        isValidating = true
        validationError = nil

        Task {
            let validator = FeedValidator()
            let result = await validator.validate(urlString)

            isValidating = false
            switch result {
            case .validFeed(let url, let title):
                let name = title ?? url.host ?? urlString
                settings.customFeeds.append(
                    CustomFeedRecord(id: UUID(), name: name, url: url.absoluteString)
                )
                newFeedURL = ""
                validationError = nil
            case .invalid(let reason):
                validationError = reason
            }
        }
    }
}
