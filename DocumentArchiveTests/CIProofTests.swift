import Testing

/// TEMPORARY (#43 part 1): proves that a failed expectation shows up as an annotation and the
/// result bundle is uploaded. Reverted before review.
@Suite struct CIProofTests {
    @Test func deliberatelyFails() {
        #expect(1 + 1 == 3, "deliberate failure for the CI proof run")
    }
}
