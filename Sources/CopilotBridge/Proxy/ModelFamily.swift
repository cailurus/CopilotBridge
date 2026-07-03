enum ModelFamily {
    static let order = ["Anthropic", "Microsoft", "GPT", "o-series", "Gemini", "Other"]

    static func family(of model: CopilotUpstream.ModelInfo) -> String {
        let lower = [model.id, model.name, model.vendor]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if lower.contains("anthropic") { return "Anthropic" }
        if lower.contains("claude") || lower.contains("opus") || lower.contains("sonnet") || lower.contains("haiku") {
            return "Anthropic"
        }
        if lower.contains("microsoft") || lower.hasPrefix("mai-") || lower.contains(" mai-") {
            return "Microsoft"
        }
        if lower.contains("gemini") { return "Gemini" }
        if lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") { return "o-series" }
        if lower.contains("gpt") { return "GPT" }
        return "Other"
    }
}
