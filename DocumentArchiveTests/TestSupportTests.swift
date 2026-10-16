import Foundation
import Testing

/// The test waits are scaled by `DA_TEST_TIMEOUT_SCALE`, so the nightly Thread Sanitizer run
/// (`TestPlans/Nightly.xctestplan`, scale 5) does not time out on the slowed-down OCR suites (#43).
@Suite struct TestSupportTests {
    @Test func timeoutScaleComesFromTheEnvironment() {
        #expect(TestSupport.timeoutScale(from: ["DA_TEST_TIMEOUT_SCALE": "5"]) == 5)
        #expect(TestSupport.timeoutScale(from: ["DA_TEST_TIMEOUT_SCALE": "2.5"]) == 2.5)
    }

    @Test(arguments: [[:], ["DA_TEST_TIMEOUT_SCALE": ""], ["DA_TEST_TIMEOUT_SCALE": "fast"],
                      ["DA_TEST_TIMEOUT_SCALE": "0"], ["DA_TEST_TIMEOUT_SCALE": "-3"],
                      ["DA_TEST_TIMEOUT_SCALE": "inf"], ["DA_TEST_TIMEOUT_SCALE": "nan"]])
    func missingOrInvalidScaleIsOne(environment: [String: String]) {
        #expect(TestSupport.timeoutScale(from: environment) == 1)
    }

    @Test func scaledMultipliesByTheScaleOfThisRun() {
        #expect(TestSupport.scaled(.seconds(10)) == .seconds(10) * TestSupport.timeoutScale)
        #expect(TestSupport.scaled(.zero) == .zero)
    }
}
