import Foundation

/// Approximate official API list prices for estimating the *equivalent* cost of token
/// usage. The user is on a fixed Copilot subscription, so this is a "what would these
/// tokens cost at the underlying provider's API" figure, not a real bill.
///
/// Prices are USD per 1,000,000 tokens, input/output separate. These are approximate
/// list prices as of 2026-07 and WILL drift — update the table when providers change
/// pricing. Unknown models price at 0.
struct ModelPrice: Equatable {
    let inputPerM: Double
    let outputPerM: Double
}

enum ModelPricing {
    /// Keyed by a normalized model id (lowercased, `[1m]`/date suffix stripped).
    static let table: [String: ModelPrice] = [
        // OpenAI
        "gpt-5": ModelPrice(inputPerM: 1.25, outputPerM: 10.0),
        "gpt-5-mini": ModelPrice(inputPerM: 0.25, outputPerM: 2.0),
        "gpt-4o": ModelPrice(inputPerM: 2.5, outputPerM: 10.0),
        "gpt-4o-mini": ModelPrice(inputPerM: 0.15, outputPerM: 0.6),
        "gpt-4.1": ModelPrice(inputPerM: 2.0, outputPerM: 8.0),
        "gpt-4-turbo": ModelPrice(inputPerM: 10.0, outputPerM: 30.0),
        "o1": ModelPrice(inputPerM: 15.0, outputPerM: 60.0),
        "o3": ModelPrice(inputPerM: 2.0, outputPerM: 8.0),
        "o4-mini": ModelPrice(inputPerM: 1.1, outputPerM: 4.4),
        // Anthropic
        "claude-opus-4": ModelPrice(inputPerM: 15.0, outputPerM: 75.0),
        "claude-sonnet-4": ModelPrice(inputPerM: 3.0, outputPerM: 15.0),
        "claude-haiku-4": ModelPrice(inputPerM: 0.8, outputPerM: 4.0),
        // Google
        "gemini-2.5-pro": ModelPrice(inputPerM: 1.25, outputPerM: 10.0),
        "gemini-2.5-flash": ModelPrice(inputPerM: 0.3, outputPerM: 2.5),
    ]

    /// Cost in USD for a resolved model id and its input/output token split.
    static func cost(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        guard let price = price(for: model) else { return 0 }
        return Double(inputTokens) / 1_000_000 * price.inputPerM
            + Double(outputTokens) / 1_000_000 * price.outputPerM
    }

    /// Resolves a price by exact normalized id, then by model family keywords.
    static func price(for model: String) -> ModelPrice? {
        let id = normalize(model)
        if let exact = table[id] { return exact }

        // Family fallback: match on family + size keyword so dated/suffixed ids still price.
        if id.contains("claude") || id.contains("opus") || id.contains("sonnet") || id.contains("haiku") {
            if id.contains("opus") { return table["claude-opus-4"] }
            if id.contains("sonnet") { return table["claude-sonnet-4"] }
            if id.contains("haiku") { return table["claude-haiku-4"] }
        }
        if id.contains("gemini") {
            if id.contains("flash") { return table["gemini-2.5-flash"] }
            return table["gemini-2.5-pro"]
        }
        if id.hasPrefix("gpt-5") { return id.contains("mini") ? table["gpt-5-mini"] : table["gpt-5"] }
        if id.hasPrefix("gpt-4o") { return id.contains("mini") ? table["gpt-4o-mini"] : table["gpt-4o"] }
        if id.hasPrefix("o1") { return table["o1"] }
        if id.hasPrefix("o3") { return table["o3"] }
        if id.hasPrefix("o4") { return table["o4-mini"] }
        return nil
    }

    private static func normalize(_ model: String) -> String {
        var id = model.lowercased()
        if id.hasSuffix("[1m]") { id = String(id.dropLast(4)) }
        // Strip a trailing 8-digit date, e.g. claude-3.5-sonnet-20240620.
        let parts = id.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            id = parts.dropLast().joined(separator: "-")
        }
        return id
    }
}
