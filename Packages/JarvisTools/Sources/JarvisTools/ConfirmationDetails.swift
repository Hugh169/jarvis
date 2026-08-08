import Foundation
import JarvisCore

/// Turns a tool call's arguments into the rows shown on the confirmation
/// window.
///
/// Pure and package-level so it can be tested against real argument shapes
/// without standing up a window. The rule it exists to serve: what the user
/// approves must be what they were shown, so nothing here silently drops a
/// field that carries meaning.
public enum ConfirmationDetails {
    /// Arguments worth reading before you say yes, in the order a person
    /// checks them: who it goes to, then what it says.
    ///
    /// Anything not on this list still gets a row — an unlisted argument is
    /// more likely to be one nobody thought about than one that doesn't
    /// matter. The list only fixes the order.
    private static let priority = [
        "to", "recipient", "destination", "path", "url", "app_name", "app",
        "shortcut", "subject", "title", "name", "body", "content", "text",
        "message",
    ]

    /// Long values are kept, not truncated: a mail body is exactly the thing
    /// you need to read in full. The window scrolls instead.
    /// Cut only at a length no human reads anyway, so a runaway argument
    /// can't push the buttons off screen.
    static let valueLimit = 4_000

    public static func rows(from input: JSONValue) -> [ConfirmationRequest.Detail] {
        guard case .object(let fields) = input, !fields.isEmpty else { return [] }

        let ordered = fields.sorted { lhs, rhs in
            switch (priority.firstIndex(of: lhs.key), priority.firstIndex(of: rhs.key)) {
            case let (l?, r?): return l < r
            // A known argument sorts above an unknown one; two unknowns sort
            // alphabetically so the order is at least stable between turns.
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.key < rhs.key
            }
        }

        return ordered.compactMap { key, value in
            guard let text = display(value), !text.isEmpty else { return nil }
            return ConfirmationRequest.Detail(
                label: humanise(key),
                value: String(text.prefix(valueLimit))
            )
        }
    }

    /// Renders a value the way it will be acted on. Arrays and objects are
    /// summarised rather than dropped — `attachments: 2 items` is a poor
    /// description but an honest one, and showing nothing would hide that the
    /// argument was there at all.
    private static func display(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): text
        case .number(let number):
            number == number.rounded() && abs(number) < 1e15
                ? String(Int(number))
                : String(number)
        case .bool(let flag): flag ? "yes" : "no"
        case .array(let items): "\(items.count) item\(items.count == 1 ? "" : "s")"
        case .object(let fields): "\(fields.count) field\(fields.count == 1 ? "" : "s")"
        case .null: nil
        }
    }

    /// `app_name` reads as "App name". The label sits next to the raw tool
    /// name in the window, so the mapping stays legible either way.
    private static func humanise(_ key: String) -> String {
        let spaced = key.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}
