/*
 Locks the public benchmark's normalization and edit-distance behavior.
 Synthetic strings cover case, punctuation, whitespace, Unicode, and all edits.
 Aggregate WER is weighted by reference words rather than sample averages.
 No audio, model, environment variable, or private fixture enters this suite.
*/
import Testing
@testable import Steno

@Suite("WordErrorRateTests")
struct WordErrorRateTests {
    @Test func normalizationMatchesManifestContract() {
        #expect(
            TranscriptNormalizer.normalize("  Hello,\tWORLD! It’s 2026.  ")
                == "hello world it s 2026"
        )
        #expect(TranscriptNormalizer.normalize("CAFE\u{301}") == "café")
    }

    @Test func countsSubstitutionsInsertionsAndDeletions() {
        #expect(
            WordErrorRate.score(
                reference: "we ship useful software",
                hypothesis: "we shipped very useful"
            ) == WordErrorRateScore(editCount: 3, referenceWordCount: 4)
        )
    }

    @Test func treatsEquivalentFormattingAsExact() {
        let score = WordErrorRate.score(
            reference: "One-button recorder.",
            hypothesis: "one button RECORDER"
        )
        #expect(score.editCount == 0)
        #expect(score.rate == 0)
    }

    @Test func aggregateRateUsesAllReferenceWords() {
        let aggregate = WordErrorRate.aggregate([
            WordErrorRateScore(editCount: 1, referenceWordCount: 2),
            WordErrorRateScore(editCount: 1, referenceWordCount: 8),
        ])
        #expect(aggregate == WordErrorRateScore(editCount: 2, referenceWordCount: 10))
        #expect(aggregate.rate == 0.2)
    }

    @Test func emptyReferenceHasDefinedBehavior() {
        #expect(WordErrorRate.score(reference: "", hypothesis: "").rate == 0)
        #expect(WordErrorRate.score(reference: "", hypothesis: "invented words").rate == 1)
    }
}
