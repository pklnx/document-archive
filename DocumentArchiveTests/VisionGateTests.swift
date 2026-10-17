import Foundation
import PDFKit
import Testing
@testable import DocumentArchive

/// Regression tests for #60: Apple Vision text recognition crashed (SIGSEGV) when several
/// requests ran at once. `VisionGate` runs one request at a time, process-wide.
@Suite struct VisionGateTests {
    /// Recognizes the first page of `data`. `PDFPage` is not `Sendable`, so every task opens its
    /// own document.
    private static func recognize(_ data: Data, environment: ProcessingEnvironment) async -> RecognizedPage {
        guard let page = PDFDocument(data: data)?.page(at: 0) else {
            Issue.record("sample PDF not readable")
            return RecognizedPage()
        }
        return await TextLayer.recognize(page, environment: environment)
    }

    /// Many recognitions started at once, from two environments (two "imports"): never more than
    /// one Vision request in flight, and every one finishes with its text.
    @Test func concurrentRecognitionsRunOneAtATime() async throws {
        let probe = VisionProbe()
        let environments = [probe.environment(), probe.environment()]
        let data = TestSupport.samplePDF(lines: ["Rechnung Nr. 4711", "Stadtwerke Bonn"])

        let results = await withTaskGroup(of: RecognizedPage.self) { group in
            for index in 0..<8 {
                let environment = environments[index % 2]
                group.addTask { await Self.recognize(data, environment: environment) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        let state = probe.snapshot
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0.lines.joined(separator: " ").contains("Rechnung") })
        #expect(state.maxInFlight == 1)
        #expect(state.began == Array(repeating: .recognizeText, count: 8))
        #expect(state.ended == 8)
        #expect(state.inFlight == 0)
        #expect(state.onMainThread == 0)
    }

    /// Page detection for the photo cleanup goes through the same gate as text recognition.
    @Test func pageDetectionSharesTheGateWithTextRecognition() async throws {
        let probe = VisionProbe()
        let environment = probe.environment()
        let photo = TestSupport.photographedPage(lines: ["Lieferschein"], width: 600, height: 800)
        let data = TestSupport.samplePDF(lines: ["Rechnung"])

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                if index.isMultiple(of: 2) {
                    group.addTask { _ = await ImageCleanup.detectPage(in: photo, environment: environment) }
                } else {
                    group.addTask { _ = await Self.recognize(data, environment: environment) }
                }
            }
        }

        let state = probe.snapshot
        #expect(state.maxInFlight == 1)
        #expect(state.began.filter { $0 == .recognizeText }.count == 3)
        #expect(state.began.contains { $0 != .recognizeText })
        #expect(state.ended == state.began.count)
    }

    /// A recognition whose task is cancelled while it waits for the gate gives up (empty page)
    /// and does not block the ones behind it.
    @Test func cancelledRecognitionDoesNotBlockTheGate() async throws {
        let probe = VisionProbe()
        let environment = probe.environment()
        let data = TestSupport.samplePDF(lines: ["Rechnung"])

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Self.recognize(data, environment: environment)
        }
        #expect(await cancelled.value.lines.isEmpty)
        let next = await Self.recognize(data, environment: environment)
        #expect(next.lines.joined().contains("Rechnung"))
        #expect(probe.snapshot.began == [.recognizeText])
    }
}
