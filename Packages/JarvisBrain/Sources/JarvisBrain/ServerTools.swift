import Foundation
import JarvisTools

/// Tools Anthropic runs on its own servers. Unlike everything in `JarvisTools`,
/// these are declared and never executed here: the model calls them mid-turn,
/// the results come back as content blocks in the same response, and JARVIS
/// only has to carry those blocks back on the next request.
///
/// The practical consequences are in `AnthropicClient`: extra content-block
/// types in the stream, and a `pause_turn` stop reason when the server-side
/// loop hits its iteration cap.
public enum ServerTool {
    /// The web search tool.
    ///
    /// Two versions exist and the model decides which one is legal. The
    /// `_20260209` variant filters results with code before they reach the
    /// context window, which is both more accurate and cheaper — but it is only
    /// available from Sonnet 4.6 / Opus 4.6 upward. Haiku 4.5 has to use the
    /// basic variant, and sending it the new one is a 400.
    ///
    /// Do **not** also declare a code-execution tool alongside the `_20260209`
    /// variant: it already runs code under the hood for filtering, and a second
    /// execution environment confuses the model.
    public static func webSearch(
        version: WebSearchVersion,
        maxUses: Int? = nil,
        userLocation: UserLocation? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .string(version.rawValue),
            "name": .string("web_search"),
        ]
        if let maxUses { object["max_uses"] = .number(Double(maxUses)) }
        if let userLocation { object["user_location"] = userLocation.jsonValue }
        return .object(object)
    }

    public enum WebSearchVersion: String, Sendable {
        /// Dynamic filtering. Opus 4.6+ and Sonnet 4.6+ only.
        case filtered = "web_search_20260209"
        /// The original. Works everywhere, including Haiku.
        case basic = "web_search_20250305"
    }

    /// Biases results toward where the user actually is. Every field is
    /// optional; an empty location is the same as sending none.
    public struct UserLocation: Sendable, Equatable {
        public var city: String?
        public var region: String?
        /// ISO 3166-1 alpha-2, e.g. "AU".
        public var country: String?
        /// IANA identifier, e.g. "Australia/Sydney".
        public var timezone: String?

        public init(
            city: String? = nil,
            region: String? = nil,
            country: String? = nil,
            timezone: String? = nil
        ) {
            self.city = city
            self.region = region
            self.country = country
            self.timezone = timezone
        }

        public var isEmpty: Bool {
            city == nil && region == nil && country == nil && timezone == nil
        }

        var jsonValue: JSONValue {
            var object: [String: JSONValue] = ["type": .string("approximate")]
            if let city { object["city"] = .string(city) }
            if let region { object["region"] = .string(region) }
            if let country { object["country"] = .string(country) }
            if let timezone { object["timezone"] = .string(timezone) }
            return .object(object)
        }
    }
}

extension ModelTier {
    /// Which web search variant this model will accept.
    public var webSearchVersion: ServerTool.WebSearchVersion {
        switch self {
        case .fast: .basic
        case .standard, .deep: .filtered
        }
    }
}
