import Testing
@testable import JarvisVoice

@Suite struct SentenceChunkerTests {
    @Test func splitsOnSentenceBoundaries() {
        var chunker = SentenceChunker()
        var chunks: [String] = []
        for delta in ["Good morn", "ing, sir. The wea", "ther is fine today. It "] {
            chunks += chunker.append(delta)
        }
        #expect(chunks == ["Good morning, sir.", "The weather is fine today."])
        chunks += chunker.append("may rain later.")
        #expect(chunker.flush() == "It may rain later.")
    }

    @Test func doesNotSplitInsideNumbers() {
        var chunker = SentenceChunker()
        let chunks = chunker.append("Pi is 3.14159 approximately. Yes.")
        #expect(chunks == ["Pi is 3.14159 approximately."])
        #expect(chunker.flush() == "Yes.")
    }

    @Test func trailingTerminatorWaitsForWhitespace() {
        var chunker = SentenceChunker()
        #expect(chunker.append("Done.").isEmpty)          // could be "Done.5" etc.
        #expect(chunker.append(" Next") == ["Done."])
        #expect(chunker.flush() == "Next")
    }

    @Test func longRunOnTextSplitsAtLengthLimit() {
        var chunker = SentenceChunker(maxChunkLength: 40)
        let text = String(repeating: "word ", count: 20) // 100 chars, no terminator
        let chunks = chunker.append(text)
        #expect(!chunks.isEmpty)
        for chunk in chunks {
            #expect(chunk.count <= 40)
        }
    }

    @Test func questionAndExclamationTerminate() {
        var chunker = SentenceChunker()
        let chunks = chunker.append("Really? Indeed! Quite so. ")
        #expect(chunks == ["Really?", "Indeed!", "Quite so."])
    }

    @Test func flushOnEmptyBufferReturnsNil() {
        var chunker = SentenceChunker()
        #expect(chunker.flush() == nil)
    }
}
