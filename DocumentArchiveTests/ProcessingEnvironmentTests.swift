import Foundation
import Testing
@testable import DocumentArchive

/// The one seam type (#44): a task-local, so tests running in parallel each see their own.
@Suite struct ProcessingEnvironmentTests {
    private func environment(apiKey: String, defaultsSuite: String) -> ProcessingEnvironment {
        var environment = ProcessingEnvironment.live
        let config = MistralConfig(apiKey: apiKey, ocrModel: "ocr", chatModel: "chat", useOCR: true, useLLM: true)
        environment.mistralConfig = { config }
        environment.defaultsSuite = defaultsSuite
        return environment
    }

    /// Unit tests never use the stored key or the real settings, as before (`TestEnvironment.isIsolated`).
    @Test func liveIsIsolatedWhileTestsRun() {
        let live = ProcessingEnvironment.live
        #expect(live.mistralConfig() == nil)
        #expect(MistralConfig.current() == nil)
        #expect(live.session === URLSession.shared)
        #expect(live.defaultsSuite == nil)
        #expect(live.textLayerEnabled())
        #expect(live.cleanupMode() == .off)
        #expect(live.cleanupFilter() == .color)
        #expect(live.rewriteHook == nil)
        #expect(live.encodeHook == nil)
    }

    @Test func concurrentTasksEachSeeTheirOwnEnvironment() async {
        let (defaultsA, nameA) = TestSupport.makeDefaults()
        let (defaultsB, nameB) = TestSupport.makeDefaults()
        defer {
            TestSupport.removeDefaults(nameA)
            TestSupport.removeDefaults(nameB)
        }
        defaultsA.set(false, forKey: AutoClassifier.autoCreateCorrespondentsKey)
        defaultsB.set(true, forKey: AutoClassifier.autoCreateCorrespondentsKey)
        let environments = [environment(apiKey: "key-A", defaultsSuite: nameA),
                            environment(apiKey: "key-B", defaultsSuite: nameB)]

        let seen = await withTaskGroup(of: (String?, Bool).self) { group in
            for environment in environments {
                group.addTask {
                    await ProcessingEnvironment.$current.withValue(environment) {
                        // Let the other task run in between.
                        try? await Task.sleep(for: .milliseconds(20))
                        let autoCreate = await AutoClassifier.autoCreateCorrespondents
                        return (MistralConfig.current()?.apiKey, autoCreate)
                    }
                }
            }
            var results: [(String?, Bool)] = []
            for await result in group { results.append(result) }
            return results.sorted { ($0.0 ?? "") < ($1.0 ?? "") }
        }

        #expect(seen.map(\.0) == ["key-A", "key-B"])
        #expect(seen.map(\.1) == [false, true])
        #expect(MistralConfig.current() == nil, "outside withValue it is live again")
    }

    /// `Task {}` inherits the environment; `Task.detached` does not, which is why
    /// `DocumentImporter.processAndWait` captures it before detaching.
    @Test func taskInheritsTheEnvironmentButDetachedDoesNot() async {
        let environment = environment(apiKey: "key-inherited", defaultsSuite: "unused")
        let (inherited, detached) = await ProcessingEnvironment.$current.withValue(environment) {
            let inherited = await Task { MistralConfig.current()?.apiKey }.value
            let detached = await Task.detached { MistralConfig.current()?.apiKey }.value
            return (inherited, detached)
        }
        #expect(inherited == "key-inherited")
        #expect(detached == nil)
    }
}
