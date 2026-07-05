import Foundation

enum CopilotModelID {
    static let oneMSuffix = "[1m]"
    private static let claudeFamilies = ["opus", "sonnet", "haiku"]

    static func clientID(forUpstreamID upstreamID: String) -> String {
        guard upstreamID.lowercased().hasPrefix("claude-") else { return upstreamID }
        guard let parsed = parseClaudeID(upstreamID) else {
            return upstreamID.replacingOccurrences(of: ".", with: "-")
        }
        return parsed.clientID
    }

    static func claudeModelID(forUpstreamID upstreamID: String, contextWindow: Int?) -> String {
        let clientID = clientID(forUpstreamID: upstreamID)
        guard upstreamID.lowercased().hasPrefix("claude-") else { return clientID }
        guard let contextWindow, contextWindow >= 1_000_000 else { return clientID }
        return clientID.lowercased().hasSuffix(oneMSuffix) ? clientID : clientID + oneMSuffix
    }

    static func resolve(_ requested: String, in models: [CopilotUpstream.ModelInfo]) -> String {
        model(matching: requested, in: models)?.id ?? strippedOneMSuffix(requested)
    }

    static func model(matching requested: String, in models: [CopilotUpstream.ModelInfo]) -> CopilotUpstream.ModelInfo? {
        let stripped = strippedOneMSuffix(requested)
        var candidates = Set([requested, stripped, clientID(forUpstreamID: stripped)])
        if let upstream = upstreamCandidate(forClientID: stripped) {
            candidates.insert(upstream)
        }

        for model in models where identifiers(for: model).contains(where: candidates.contains) {
            return model
        }

        // Fuzzy fallback: only a case-insensitive EXACT match on any identifier. We
        // deliberately avoid prefix/substring matching, which would map e.g. "gpt-4"
        // onto "gpt-4o" or "gpt-4.1". If nothing matches exactly, return nil and let
        // the caller pass the requested id through to the upstream unchanged.
        let target = stripped.lowercased()
        return models.first { model in
            identifiers(for: model).contains { $0.lowercased() == target }
        }
    }

    static func strippedOneMSuffix(_ id: String) -> String {
        id.lowercased().hasSuffix(oneMSuffix) ? String(id.dropLast(oneMSuffix.count)) : id
    }

    private static func identifiers(for model: CopilotUpstream.ModelInfo) -> [String] {
        [
            model.id,
            model.clientID,
            model.claudeModelID,
            model.displayID,
            strippedOneMSuffix(model.claudeModelID),
            strippedOneMSuffix(model.displayID),
            clientID(forUpstreamID: model.id),
        ]
    }

    private static func upstreamCandidate(forClientID clientID: String) -> String? {
        parseClaudeID(clientID)?.upstreamID
    }

    private struct ClaudeIDParts {
        let family: String
        let version: String
        let suffix: String

        var clientID: String {
            "claude-\(family)-\(version.replacingOccurrences(of: ".", with: "-"))\(suffix)"
        }

        var upstreamID: String {
            "claude-\(family)-\(version)\(suffix)"
        }
    }

    private static func parseClaudeID(_ id: String) -> ClaudeIDParts? {
        var raw = strippedOneMSuffix(id).lowercased()
        raw = stripDateSuffix(raw)
        guard raw.hasPrefix("claude-") else { return nil }
        let body = String(raw.dropFirst("claude-".count))

        for family in claudeFamilies where body.hasPrefix(family + "-") {
            let rest = String(body.dropFirst(family.count + 1))
            if let parsed = parseVersionAndSuffix(rest) {
                return ClaudeIDParts(family: family, version: parsed.version, suffix: parsed.suffix)
            }
        }

        let parts = body.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }

        if parts[0].contains(".") {
            let versionBits = parts[0].split(separator: ".").map(String.init)
            guard versionBits.count == 2, parts.count >= 2, claudeFamilies.contains(parts[1]) else { return nil }
            return ClaudeIDParts(
                family: parts[1],
                version: "\(versionBits[0]).\(versionBits[1])",
                suffix: suffix(from: parts, after: 1)
            )
        }

        if parts.count >= 3,
           isDigits(parts[0]), isDigits(parts[1]), claudeFamilies.contains(parts[2]) {
            return ClaudeIDParts(
                family: parts[2],
                version: "\(parts[0]).\(parts[1])",
                suffix: suffix(from: parts, after: 2)
            )
        }

        if parts.count >= 2, isDigits(parts[0]), claudeFamilies.contains(parts[1]) {
            return ClaudeIDParts(
                family: parts[1],
                version: parts[0],
                suffix: suffix(from: parts, after: 1)
            )
        }

        return nil
    }

    private static func parseVersionAndSuffix(_ value: String) -> (version: String, suffix: String)? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first else { return nil }

        if first.contains(".") {
            let versionBits = first.split(separator: ".").map(String.init)
            guard versionBits.count == 2 else { return nil }
            return ("\(versionBits[0]).\(versionBits[1])", suffix(from: parts, after: 0))
        }

        if parts.count >= 2, isDigits(parts[0]), isDigits(parts[1]) {
            return ("\(parts[0]).\(parts[1])", suffix(from: parts, after: 1))
        }

        if isDigits(first) {
            return (first, suffix(from: parts, after: 0))
        }

        return nil
    }

    private static func stripDateSuffix(_ id: String) -> String {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, last.count == 8, isDigits(last) else { return id }
        return parts.dropLast().joined(separator: "-")
    }

    private static func suffix(from parts: [String], after index: Int) -> String {
        let suffixParts = parts.dropFirst(index + 1)
        return suffixParts.isEmpty ? "" : "-" + suffixParts.joined(separator: "-")
    }

    private static func isDigits(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy(\.isNumber)
    }
}
