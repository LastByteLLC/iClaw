import Foundation

// Mode routing: activation, deactivation, and remote-device dispatch.
// Extracted from `ToolRouter+Helpers.swift` for file-size reasons.
// Behavior unchanged. See `Docs/Routing.md` for stage ordering.

// MARK: - Mode Routing

extension ToolRouter {

    /// Sets the skill from a mode config and routes to allowed tools (or conversational).
    func routeWithinMode(name: String, config: ModeConfig) -> RoutingResult {
        currentSkill = Skill(
            name: name,
            description: config.displayName,
            systemPrompt: config.systemPrompt,
            tools: [],
            examples: []
        )

        if config.allowedTools.isEmpty {
            return .conversational
        }

        let allowedSet = Set(config.allowedTools.map { $0.lowercased() })
        let filteredCore = availableTools.filter { allowedSet.contains($0.name.lowercased()) }
        let filteredFM = fmTools.filter { allowedSet.contains($0.name.lowercased()) }

        // If only one tool is allowed, route directly to it
        if filteredCore.count + filteredFM.count == 1 {
            if let tool = filteredCore.first { return .tools([tool]) }
            if let tool = filteredFM.first { return .fmTools([tool]) }
        }

        // Multiple allowed tools — return the filtered set (engine caps at 3)
        if !filteredCore.isEmpty || !filteredFM.isEmpty {
            if filteredFM.isEmpty { return .tools(Array(filteredCore.prefix(maxToolsToReturn))) }
            if filteredCore.isEmpty { return .fmTools(Array(filteredFM.prefix(maxToolsToReturn))) }
            return .mixed(
                core: Array(filteredCore.prefix(maxToolsToReturn)),
                fm: Array(filteredFM.prefix(max(0, maxToolsToReturn - filteredCore.prefix(maxToolsToReturn).count)))
            )
        }

        return .conversational
    }

    /// Handles routing when a mode is active. Returns nil if the mode was just deactivated
    /// (so normal routing can proceed for the exit message).
    func checkModeOverride(input: String, mode: (name: String, config: ModeConfig)) -> RoutingResult? {
        let lower = input.lowercased().trimmingCharacters(in: .whitespaces)

        // Check exit: chip toggle (e.g. #rubberduck while in rubber duck mode)
        let chipNames = InputParsingUtilities.extractToolChipNames(from: input)
        for chip in chipNames {
            if let modeMatch = ToolManifest.modeForChip(chip), modeMatch.name == mode.name {
                deactivateMode()
                return nil
            }
        }

        // Check exit: exit phrase match
        for phrase in mode.config.exitPhrases {
            if lower.contains(phrase.lowercased()) {
                deactivateMode()
                return nil
            }
        }

        return routeWithinMode(name: mode.name, config: mode.config)
    }

    /// Checks if a chip in the input activates a mode (before normal chip routing).
    /// Skips chips that match a direct tool name — those are handled by `checkToolChips` instead.
    func checkModeChipActivation(input: String) -> RoutingResult? {
        let chipNames = InputParsingUtilities.extractToolChipNames(from: input)
        for chip in chipNames {
            // Skip if this chip matches a registered CoreTool or FMTool name —
            // let normal chip routing handle it so #rewrite routes to RewriteTool
            // instead of activating Rewrite mode.
            let matchesCoreTool = availableTools.contains { ToolNameNormalizer.matches($0.name, chip) }
            let matchesFMTool = fmTools.contains { ToolNameNormalizer.matches($0.chipName, chip) }
            if matchesCoreTool || matchesFMTool {
                // If input is bare (no text beyond chip) and tool has a modeConfig,
                // activate mode instead of routing to the tool directly.
                let stripped = InputParsingUtilities.stripToolChips(from: input)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if stripped.isEmpty, let modeMatch = ToolManifest.modeForChip(chip) {
                    activateMode(name: modeMatch.name, config: modeMatch.config, groupId: UUID())
                    return routeWithinMode(name: modeMatch.name, config: modeMatch.config)
                }
                continue
            }

            if let modeMatch = ToolManifest.modeForChip(chip) {
                activateMode(name: modeMatch.name, config: modeMatch.config, groupId: UUID())
                return routeWithinMode(name: modeMatch.name, config: modeMatch.config)
            }
        }
        return nil
    }
}

// MARK: - Remote Device Routing

#if CONTINUITY_ENABLED
extension ToolRouter {

    /// Checks for `#remote` chip prefix (e.g. `#remote spotlight query`, `#remote mac spotlight query`).
    func checkRemoteChip(input: String) async -> RoutingResult? {
        guard await ContinuityManager.isEnabled else { return nil }

        let lower = input.lowercased().trimmingCharacters(in: .whitespaces)
        guard lower.hasPrefix("#remote") else { return nil }

        var remainder = String(lower.dropFirst("#remote".count)).trimmingCharacters(in: .whitespaces)
        var targetType: RemoteDevice.DeviceType? = nil

        // Check for device type qualifier
        if remainder.hasPrefix("mac ") {
            targetType = .mac
            remainder = String(remainder.dropFirst("mac ".count))
        } else if remainder.hasPrefix("phone ") || remainder.hasPrefix("iphone ") {
            targetType = .phone
            remainder = String(remainder.dropFirst(remainder.hasPrefix("phone ") ? "phone ".count : "iphone ".count))
        }

        // Extract tool name (first word of remainder) and query (rest)
        let parts = remainder.components(separatedBy: .whitespaces)
        guard let toolName = parts.first, !toolName.isEmpty else { return nil }
        let query = parts.dropFirst().joined(separator: " ")

        await ContinuityManager.shared.refreshDevices()
        let devices = await ContinuityManager.shared.availableDevices

        let candidates = devices.filter { device in
            let hasType = targetType == nil || device.deviceType == targetType
            let hasTool = device.availableTools.contains { $0.lowercased() == toolName }
            return hasType && hasTool
        }

        guard let target = candidates.first else {
            Log.router.debug("No remote device available for #remote \(toolName)")
            return nil
        }

        let proxy = RemoteToolProxy(
            name: toolName.capitalized,
            targetDeviceID: target.id,
            targetDeviceName: target.displayName,
            query: query
        )
        return .tools([proxy])
    }

    /// After local routing fails, check if any remote device has a matching tool.
    func checkRemoteDevices(input: String) async -> RoutingResult? {
        guard await ContinuityManager.isEnabled else { return nil }

        await ContinuityManager.shared.refreshDevices()
        let devices = await ContinuityManager.shared.availableDevices
        guard !devices.isEmpty else { return nil }

        // Try ML classification to get the tool name, then check remote availability
        let mlResults = await classifyWithML(input: input)
        guard let topResult = mlResults.first, topResult.confidence > 0.3 else { return nil }

        let toolName = topResult.label
        let hasLocally = availableTools.contains { $0.name.lowercased() == toolName.lowercased() }
            || fmTools.contains { $0.name.lowercased() == toolName.lowercased() }
        guard !hasLocally else { return nil }

        // Check if any remote device has this tool
        let remoteDevice = devices.first { device in
            device.availableTools.contains { $0.lowercased() == toolName.lowercased() }
        }
        guard let target = remoteDevice else { return nil }

        Log.router.debug("Routing '\(toolName)' to remote \(target.displayName)")
        let proxy = RemoteToolProxy(
            name: toolName,
            targetDeviceID: target.id,
            targetDeviceName: target.displayName
        )
        return .tools([proxy])
    }
}
#endif
