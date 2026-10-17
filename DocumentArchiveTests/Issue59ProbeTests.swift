import Foundation
import SwiftData
import Testing
@testable import DocumentArchive

// #59, PR 1, step 1. Scratch only: never merged.

/// The premise of hypothesis 1: a container nobody holds deallocates.
@Suite struct Issue59PremiseTests {
    @Test @MainActor func droppedContainerDeallocates() throws {
        weak var dropped: ModelContainer?
        try autoreleasepool {
            let container = try TestSupport.makeContainer()
            dropped = container
        }
        #expect(dropped == nil, "premise check: nil means a dropped container deallocates")
    }

    @Test @MainActor func droppedContainerFromArchiveStoreDeallocates() {
        weak var dropped: ModelContainer?
        autoreleasepool {
            let container = ArchiveStore.makeContainer(for: .inMemory(seed: false), migrate: {})
            dropped = container
        }
        #expect(dropped == nil, "premise check: nil means a dropped container deallocates")
    }
}

/// The crash probes. They crash the test host if hypothesis 1 holds, so they only run with
/// `TEST_RUNNER_DA_PROBE_59=a` or `=b`.
@Suite(.serialized) struct Issue59Probes {
    static let probe = ProcessInfo.processInfo.environment["DA_PROBE_59"] ?? ""

    /// (a) Insert into the main context without saving, release the container, let the run loop turn.
    @Test(.enabled(if: probe.contains("a"))) @MainActor func a_unsavedInsertThenRelease() async throws {
        weak var dropped: ModelContainer?
        try autoreleasepool {
            let container = try TestSupport.makeContainer()
            let document = Document(title: "Probe", pdfData: Data(), source: .file)
            let tag = ArchiveTag(name: "Probe")
            container.mainContext.insert(document)
            container.mainContext.insert(tag)
            document.toggleTag(tag)
            dropped = container
        }
        print("#59 probe a: container released: \(dropped == nil)")
        try await Task.sleep(for: TestSupport.scaled(.seconds(5)))
        print("#59 probe a: survived 5 s")
    }

    /// (c) Like (a), but the run loop turns once while the container still lives (an async test
    /// that inserted and awaited something), then the container is released.
    @Test(.enabled(if: probe.contains("c"))) @MainActor func c_runLoopTurnsThenRelease() async throws {
        weak var dropped: ModelContainer?
        do {
            let container = try TestSupport.makeContainer()
            container.mainContext.insert(ArchiveTag(name: "Probe"))
            try await Task.sleep(for: .milliseconds(100))
            container.mainContext.insert(ArchiveTag(name: "Probe 2"))
            dropped = container
        }
        print("#59 probe c: container released: \(dropped == nil)")
        for second in stride(from: 10, through: 90, by: 10) {
            try await Task.sleep(for: .seconds(10))
            print("#59 probe c: survived \(second) s")
        }
    }

    /// (b) Start processing, release the container during the detached analysis, then wait.
    @Test(.enabled(if: probe.contains("b"))) @MainActor func b_releaseDuringAnalysis() async throws {
        weak var dropped: ModelContainer?
        weak var droppedDocument: Document?
        do {
            let container = try TestSupport.makeContainer()
            let context = container.mainContext
            let document = Document(title: "Probe", pdfData: TestSupport.scanPDF(pages: [["Probe 59", "Second line"]]),
                                    source: .scan)
            context.insert(document)
            DocumentImporter.process(document, context: context, classify: true)
            // Let the processing task start: `isProcessing` is set and the analysis is detached.
            try await Task.sleep(for: .milliseconds(300))
            print("#59 probe b: isProcessing before release: \(document.isProcessing)")
            dropped = container
            droppedDocument = document
        }
        print("#59 probe b: container released right away: \(dropped == nil)")
        try await Task.sleep(for: TestSupport.scaled(.seconds(30)))
        print("#59 probe b: survived 30 s; container released: \(dropped == nil), document released: \(droppedDocument == nil)")
    }
}

#if canImport(MachO)
import MachO

/// Step 0: names the addresses of the crash in the SwiftData of this runtime (the crash report
/// has UUID 2449226e-2e13-3ad7-8ae3-5a808ecd2224, iOS 26.5 23F77). Runs with `DA_PROBE_59=s`.
@Suite struct Issue59Symbols {
    static let probe = ProcessInfo.processInfo.environment["DA_PROBE_59"] ?? ""

    @Test(.enabled(if: probe.contains("s"))) func s_symbolicateTheTrap() throws {
        _ = try TestSupport.makeContainer()   // SwiftData is loaded
        var found = false
        for index in 0..<_dyld_image_count() {
            guard let raw = _dyld_get_image_name(index), let header = _dyld_get_image_header(index) else { continue }
            let path = String(cString: raw)
            guard path.hasSuffix("/SwiftData.framework/SwiftData") || path.hasSuffix("/SwiftData.framework/Versions/A/SwiftData")
            else { continue }
            found = true
            let base = UnsafeRawPointer(header)
            var uuid = "?"
            var command = base.advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<header.pointee.ncmds {
                let load = command.load(as: load_command.self)
                if load.cmd == UInt32(LC_UUID) {
                    uuid = UUID(uuid: command.load(as: uuid_command.self).uuid).uuidString
                }
                command = command.advanced(by: Int(load.cmdsize))
            }
            print("#59 SwiftData \(path) uuid \(uuid) base 0x\(String(UInt(bitPattern: base), radix: 16)) runtime \(ProcessInfo.processInfo.operatingSystemVersionString)")
            func symbol(_ address: UnsafeRawPointer) -> String {
                var info = Dl_info()
                guard dladdr(address, &info) != 0 else { return "no image" }
                let file = info.dli_fname.map { String(cString: $0) }.map { ($0 as NSString).lastPathComponent } ?? "?"
                guard let name = info.dli_sname, let start = info.dli_saddr else { return "\(file): no symbol" }
                return "\(file): \(String(cString: name)) + \(Int(bitPattern: address) - Int(bitPattern: start))"
            }
            for offset in [0x89338, 0x89468, 0x89490, 0x89494, 0x894a0, 0x894bc, 0x118d4c, 0x118d7c] {
                print("#59 +0x\(String(offset, radix: 16)) = \(symbol(base.advanced(by: offset)))")
            }
            // The code around the trap, to disassemble, and the strings it refers to (adrp + add).
            let start = 0x88e00, end = 0x89600
            var hex: [String] = []
            for offset in stride(from: start, to: end, by: 4) {
                hex.append(String(format: "%08x", base.load(fromByteOffset: offset, as: UInt32.self)))
            }
            for chunk in stride(from: 0, to: hex.count, by: 16) {
                print("#59 code +0x\(String(start + chunk * 4, radix: 16)): \(hex[chunk..<min(chunk + 16, hex.count)].joined(separator: " "))")
            }
            var pending: [UInt32: Int] = [:]   // register -> page address
            for offset in stride(from: start, to: end, by: 4) {
                let insn = base.load(fromByteOffset: offset, as: UInt32.self)
                let pc = Int(bitPattern: base) + offset
                if insn & 0x9F00_0000 == 0x9000_0000 {
                    let immlo = Int((insn >> 29) & 3), immhi = Int((insn >> 5) & 0x7FFFF)
                    var imm = (immhi << 2) | immlo
                    if imm & (1 << 20) != 0 { imm -= 1 << 21 }
                    pending[insn & 0x1F] = (pc & ~0xFFF) + (imm << 12)
                } else if insn & 0xFFC0_0000 == 0x9100_0000, let page = pending[(insn >> 5) & 0x1F] {
                    let target = page + Int((insn >> 10) & 0xFFF)
                    pending[(insn >> 5) & 0x1F] = nil
                    guard let pointer = UnsafeRawPointer(bitPattern: target) else { continue }
                    let where_ = symbol(pointer)
                    var text = ""
                    if where_ != "no image" {
                        for i in 0..<160 {
                            let byte = pointer.load(fromByteOffset: i, as: UInt8.self)
                            if byte == 0 { break }
                            text.append(byte >= 32 && byte < 127 ? Character(UnicodeScalar(byte)) : "?")
                        }
                    }
                    print("#59 ref at +0x\(String(offset, radix: 16)) -> 0x\(String(target, radix: 16)) (\(where_)) \"\(text)\"")
                }
            }
        }
        #expect(found)
    }
}
#endif
