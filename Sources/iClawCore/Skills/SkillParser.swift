import Foundation

/// A Swift 6 actor that parses AgentSkills formatted Markdown files.
actor SkillParser {

    /// Reserved chip names from built-in tools. Skill handles must not collide with these.
    private static let reservedChipNames: Set<String> = {
        var names = Set<String>()
        for tool in ToolRegistry.coreTools {
            names.insert(ToolNameNormalizer.normalizeStripped(tool.name))
            if let chipName = ToolManifest.entry(for: tool.name)?.chipName {
                names.insert(chipName.lowercased())
            }
        }
        for tool in ToolRegistry.fmTools {
            names.insert(ToolNameNormalizer.normalizeStripped(tool.name))
            names.insert(tool.chipName.lowercased())
        }
        return names
    }()

    /// Parses a Markdown skill file at the given URL and returns a Skill directly.
    func parseSkill(from url: URL) throws -> Skill {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        var name = ""
        var description = ""
        var examples: [String] = []
        var cacheDuration: CacheDuration?
        var handle: String?

        enum Section { case none, examples, cache, handle }
        var currentSection: Section = .none

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Extract Name (H1)
            if trimmedLine.hasPrefix("# ") && name.isEmpty {
                name = String(trimmedLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }

            // Detect Sections (H2)
            if trimmedLine.hasPrefix("## ") {
                let sectionName = String(trimmedLine.dropFirst(3)).lowercased()
                if sectionName.contains("examples") {
                    currentSection = .examples
                } else if sectionName.contains("cache") {
                    currentSection = .cache
                } else if sectionName.contains("handle") {
                    currentSection = .handle
                } else {
                    currentSection = .none
                }
                continue
            }

            // Extract Examples (bullet points under "Examples" section)
            if currentSection == .examples {
                if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") {
                    let example = String(trimmedLine.dropFirst(2))
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if !example.isEmpty {
                        examples.append(example)
                    }
                }
                continue
            }

            // Extract Cache duration (bullet under "Cache" section)
            if currentSection == .cache {
                if trimmedLine.hasPrefix("- unit:") || trimmedLine.hasPrefix("* unit:") {
                    let value = trimmedLine
                        .components(separatedBy: ":").dropFirst().joined(separator: ":")
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    cacheDuration = CacheDuration(rawValue: value)
                }
                continue
            }

            // Extract Handle (first non-empty line under "Handle" section, then reset)
            if currentSection == .handle {
                if !trimmedLine.isEmpty && handle == nil {
                    let candidate = trimmedLine
                        .replacingOccurrences(of: "#", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    if !candidate.isEmpty && !Self.reservedChipNames.contains(candidate) {
                        handle = candidate
                    } else if Self.reservedChipNames.contains(candidate) {
                        Log.engine.debug("Skill handle '#\(candidate)' conflicts with a built-in tool — ignored.")
                    }
                    currentSection = .none
                }
                continue
            }

            // Extract Description (lines after H1 and before next H2)
            if !name.isEmpty && currentSection == .none && !trimmedLine.isEmpty && !trimmedLine.hasPrefix("#") {
                if description.isEmpty {
                    description = trimmedLine
                } else {
                    description += " " + trimmedLine
                }
            }
        }

        // Extract Tool references (e.g., `currency_converter`)
        var toolsList: [ToolDefinition] = []
        var seenTools = Set<String>()
        let pattern = "`([a-zA-Z0-9_]+)` tool"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let matches = regex.matches(in: description, options: [], range: NSRange(location: 0, length: description.utf16.count))
            for match in matches {
                if let range = Range(match.range(at: 1), in: description) {
                    let toolName = String(description[range])
                    if !seenTools.contains(toolName) {
                        seenTools.insert(toolName)
                        toolsList.append(ToolDefinition(name: toolName, description: "", parameters: [:]))
                    }
                }
            }
        }

        // Strip "A skill for..." preamble for concise UI display; keep full text in systemPrompt.
        let displayDescription = stripPreamble(description)

        return Skill(
            name: name,
            description: displayDescription,
            systemPrompt: "You are an expert in \(name). \(description)",
            tools: toolsList,
            examples: examples,
            cacheDuration: cacheDuration,
            handle: handle
        )
    }

    /// Strips common preamble phrases like "A skill for..." from skill descriptions.
    private func stripPreamble(_ description: String) -> String {
        let prefixes = ["a skill for ", "a skill that ", "skill for ", "skill that "]
        let lowered = description.lowercased()
        for prefix in prefixes {
            if lowered.hasPrefix(prefix) {
                var stripped = String(description.dropFirst(prefix.count))
                // Capitalize the first letter of the remaining text
                if let first = stripped.first {
                    stripped = first.uppercased() + stripped.dropFirst()
                }
                return stripped
            }
        }
        return description
    }

    /// Returns a list of sample utterances for a skill at the given URL.
    func getSampleUtterances(from url: URL) async throws -> [String] {
        let skill = try parseSkill(from: url)
        return skill.examples
    }
}
