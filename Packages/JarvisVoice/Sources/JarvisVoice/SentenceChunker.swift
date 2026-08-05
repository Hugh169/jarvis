import Foundation

/// Buffers streamed text deltas and emits sentence-sized chunks for TTS
/// pipelining: flush on `.` `?` `!` followed by whitespace, or when the buffer
/// exceeds `maxChunkLength`, whichever comes first.
public struct SentenceChunker: Sendable {
    public let maxChunkLength: Int
    private var buffer = ""

    public init(maxChunkLength: Int = 120) {
        self.maxChunkLength = maxChunkLength
    }

    /// Append a streamed delta; returns zero or more completed sentences.
    public mutating func append(_ delta: String) -> [String] {
        buffer += delta
        var chunks: [String] = []
        while let chunk = extractChunk() {
            chunks.append(chunk)
        }
        return chunks
    }

    /// Flush whatever remains (call when the model stream ends).
    public mutating func flush() -> String? {
        let remainder = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return remainder.isEmpty ? nil : remainder
    }

    private mutating func extractChunk() -> String? {
        // Sentence boundary: terminator followed by whitespace.
        var boundary: String.Index?
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let character = buffer[index]
            if character == "." || character == "?" || character == "!" {
                let next = buffer.index(after: index)
                if next < buffer.endIndex, buffer[next].isWhitespace {
                    boundary = next
                    break
                }
                // Terminator at end of buffer: wait for more input — the model
                // may still be mid-number ("3.14") or mid-abbreviation.
            }
            index = buffer.index(after: index)
        }

        if let boundary {
            let chunk = String(buffer[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[boundary...])
            return chunk.isEmpty ? nil : chunk
        }

        // Length overflow: cut at the last whitespace before the limit.
        if buffer.count >= maxChunkLength {
            let limit = buffer.index(buffer.startIndex, offsetBy: maxChunkLength)
            let cutRange = buffer[..<limit].range(of: " ", options: .backwards)
            let cut = cutRange?.upperBound ?? limit
            let chunk = String(buffer[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[cut...])
            return chunk.isEmpty ? nil : chunk
        }
        return nil
    }
}
