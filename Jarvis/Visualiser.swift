import Foundation
import JarvisCore
import JarvisBrain
import JarvisTools

/// Turns a finished answer into something to look at.
///
/// The main model will not reliably call a display tool — that was established
/// the hard way with `display_schedule`, which survived a system-prompt rule, a
/// prescriptive tool description and a nudge attached to the tool result, and
/// was still ignored. So this doesn't ask. A second, cheap call runs with
/// `tool_choice` forced to `display_cards`, and the API will not let the model
/// return anything else.
///
/// It runs *while JARVIS is speaking*, so none of it lands on the latency
/// budget: by the time the sentence being spoken has finished, the panel has
/// filled in underneath it.
@MainActor
enum Visualiser {
    /// Haiku regardless of the turn's tier. The work is transcription of an
    /// answer that already exists, not reasoning about it, and this runs on
    /// every turn — the cheapest capable model is the right one.
    private static let tier = ModelTier.fast

    private static let instructions = """
        You turn an answer that has already been given into a compact visual \
        panel. You are not answering the question and you are not adding \
        anything that isn't in the answer — no invented figures, no facts you \
        weren't given.

        Pick the blocks that suit what's there. Label/value facts carry most \
        answers. Use a stat only for a number that deserves to be large. Use a \
        map when a specific place is discussed and you are confident of its \
        coordinates. Use an image only for a URL that appears in what you were \
        given — never invent one.

        Keep it to what someone would want at a glance: at most five blocks, \
        short labels, values worth reading. If the answer genuinely has nothing \
        worth showing — a yes, an acknowledgement, a one-line confirmation — \
        return a single note block with the key point.
        """

    /// Fire-and-forget. A failure here costs the visual and nothing else; the
    /// answer has already been spoken by the time this runs.
    static func illustrate(
        question: String,
        answer: String,
        apiKey: String,
        into appState: AppState
    ) async {
        guard !apiKey.isEmpty, answer.count > 24 else { return }

        let brain = AnthropicClient(apiKey: apiKey)
        let definition = DisplayCardsTool(present: { _ in }).definitionForForcing

        let stream = await brain.stream(
            model: tier.modelID,
            system: [Anthropic.SystemBlock(text: instructions, cached: true)],
            messages: [
                .user("""
                    The user asked: \(question)

                    JARVIS answered: \(answer)

                    Put that answer on screen.
                    """)
            ],
            tools: [definition],
            toolChoice: Anthropic.MessagesRequest.forcing(DisplayCardsTool.name),
            maxTokens: 2048
        )

        do {
            for try await event in stream {
                guard case .toolUse(let use) = event, use.name == DisplayCardsTool.name else {
                    continue
                }
                guard let deck = DisplayCardsTool.deck(from: use.input) else {
                    DebugLog.write("visualiser: no usable blocks")
                    return
                }
                // Never overwrite something richer that the turn itself
                // produced — a timeline or a detail pane was a deliberate
                // choice, this is the fallback.
                guard appState.cards == nil, appState.schedule == nil,
                      appState.detailMarkdown == nil else { return }
                appState.cards = deck
                DebugLog.write("visualiser: \(deck.blocks.count) block(s)")
                return
            }
        } catch {
            DebugLog.write("visualiser failed: \(error.localizedDescription)")
        }
    }
}

private extension DisplayCardsTool {
    /// The tool definition on its own. The instance exists only to reach the
    /// static schema through a value, since the presenter is irrelevant here —
    /// this call never executes the tool, it only reads the arguments.
    var definitionForForcing: JSONValue { Self.apiDefinition }
}
