import Foundation

struct Skill: Codable {
    let name: String
    let description: String
    let systemPrompt: String
    let tools: [ToolDefinition]
}

struct ToolDefinition: Codable {
    let name: String
    let description: String
    let parameters: [String: String]
}

@MainActor
class SkillLoader {
    static let shared = SkillLoader()
    
    @Published var loadedSkills: [Skill] = []
    
    private init() {
        loadBuiltInSkills()
    }
    
    func loadBuiltInSkills() {
        // Placeholder for built-in skills
    }
    
    func loadSkill(from url: URL) throws {
        let content = try String(contentsOf: url)
        // Basic Markdown parsing (regex or manual)
        // For now, assume a specific format for parsing
        
        let name = "Custom Skill"
        let description = "Description"
        let systemPrompt = "Custom instructions"
        
        let skill = Skill(name: name, description: description, systemPrompt: systemPrompt, tools: [])
        loadedSkills.append(skill)
    }
}
