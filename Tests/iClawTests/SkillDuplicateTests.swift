import Testing
import Foundation
@testable import iClawCore

// MARK: - Catalog Duplicate Filtering

@Suite("SkillCatalogDuplicates")
struct SkillCatalogDuplicateTests {

    @Test func fetchCatalogFiltersOutBuiltInSkills() async {
        // Simulate a catalog response that includes a skill matching a built-in name
        let catalogJSON = """
        {
            "version": 1,
            "skills": [
                {"name": "Research Skill", "filename": "ResearchSkill.md", "description": "Duplicate", "version": 1, "handle": null},
                {"name": "Unique Skill", "filename": "UniqueSkill.md", "description": "Not a duplicate", "version": 1, "handle": null}
            ]
        }
        """.data(using: .utf8)!

        // Build a stub URLSession that returns our catalog JSON
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogStubProtocol.self]
        CatalogStubProtocol.responseData = catalogJSON
        let session = URLSession(configuration: config)

        let catalog = SkillCatalog(session: session)

        // Ensure built-in skills are loaded so the filter has something to match
        _ = await SkillLoader.shared.awaitActiveSkills()

        await catalog.fetchCatalog()

        let names = await catalog.catalog.map(\.name)
        #expect(!names.contains("Research Skill"), "Built-in skill should be filtered from catalog")
        #expect(names.contains("Unique Skill"), "Non-duplicate skill should remain in catalog")
    }

    @Test func installSilentlySkipsDuplicateOfBuiltIn() async throws {
        // Ensure built-in skills are loaded
        _ = await SkillLoader.shared.awaitActiveSkills()

        let catalog = SkillCatalog()
        let duplicateSkill = CatalogSkill(
            name: "Research Skill",
            filename: "ResearchSkill.md",
            description: "Duplicate",
            version: 1,
            handle: nil
        )

        // Should not throw — silently skips
        try await catalog.install(duplicateSkill)

        // Should not be tracked as installed
        let installed = await catalog.isInstalled(duplicateSkill)
        #expect(!installed, "Duplicate skill should not be recorded as installed")
    }
}

// MARK: - Import Duplicate Detection

@Suite("SkillImportDuplicates")
struct SkillImportDuplicateTests {

    @MainActor
    @Test func importSkillThrowsForBuiltInDuplicate() async throws {
        // Ensure built-in skills are loaded
        _ = await SkillLoader.shared.awaitActiveSkills()

        // Create a temporary .md file that parses to a skill with a built-in name
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillImportTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let skillContent = """
        # Research Skill

        A duplicate skill.

        ## Examples
        - research something
        - look something up
        """
        let fileURL = tempDir.appendingPathComponent("ResearchSkill.md")
        try skillContent.write(to: fileURL, atomically: true, encoding: .utf8)

        // Should throw SkillImportError.duplicatesBuiltInSkill
        await #expect(throws: SkillImportError.self) {
            _ = try await SkillLoader.shared.importSkill(from: fileURL)
        }
    }
}

// MARK: - Stub URL Protocol

private final class CatalogStubProtocol: URLProtocol {
    nonisolated(unsafe) static var responseData: Data = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
