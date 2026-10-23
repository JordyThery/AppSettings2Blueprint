import Foundation
import Testing
@testable import AppSettings2Blueprint

/// What `codesign -dvvv -r- --arch <arch>` reports for one slice.
private struct CodesignSlice {
    var cdHash: String?
    var teamID: String?
    var signingID: String?
    var designatedRequirement: String?

    /// Only these tests run codesign; the app never does.
    static func read(path: String, architecture: String) throws -> CodesignSlice {
        let output = try run("/usr/bin/codesign", ["-dvvv", "-r-", "--arch", architecture, path])
        func field(_ name: String) -> String? {
            output.split(separator: "\n").first { $0.hasPrefix("\(name)=") }
                .map { String($0.dropFirst(name.count + 1)) }
        }
        // An explicit DR prints as `designated => …`, an implicit one as `# designated => …`.
        let requirement = output.split(separator: "\n").lazy
            .map { $0.hasPrefix("# ") ? $0.dropFirst(2) : $0 }
            .first { $0.hasPrefix("designated => ") }
            .map { String($0.dropFirst("designated => ".count)) }
        let team = field("TeamIdentifier")
        return CodesignSlice(
            cdHash: field("CDHash"),
            teamID: team == "not set" ? nil : team,
            signingID: field("Identifier"),
            designatedRequirement: requirement
        )
    }
}

private func run(_ tool: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

private func lipoArchs(_ executable: String) throws -> [String] {
    try run("/usr/bin/lipo", ["-archs", executable])
        .split(whereSeparator: \.isWhitespace).map(String.init)
}

private struct Subject: CustomTestStringConvertible, Sendable {
    let path: String
    let expectedState: DetectedSigningState
    var testDescription: String { URL(filePath: path).lastPathComponent }
}

/// Apps on this Mac covering Apple, Developer ID and App Store signing. Apps that
/// are not installed are skipped rather than failed.
private let subjects: [Subject] = [
    Subject(path: "/System/Cryptexes/App/System/Applications/Safari.app", expectedState: .apple),
    Subject(path: "/System/Applications/Calculator.app", expectedState: .apple),
    Subject(path: "/Applications/Microsoft Outlook.app", expectedState: .developerID),
    Subject(path: "/Applications/Developer.app", expectedState: .appStore),
].filter { FileManager.default.fileExists(atPath: $0.path) }

@Suite("CodeSignatureInspector vs codesign")
struct CodeSignatureInspectorTests {
    @Test(arguments: subjects)
    fileprivate func matchesCodesignForEverySlice(subject: Subject) throws {
        let inspection = try CodeSignatureInspector.inspect(URL(filePath: subject.path))
        #expect(inspection.verification == .valid)
        let executable = try #require(inspection.executablePath)
        let lipo = try lipoArchs(executable)
        #expect(inspection.slices.map(\.architecture) == lipo)

        for slice in inspection.slices {
            let expected = try CodesignSlice.read(path: subject.path, architecture: slice.architecture)
            #expect(slice.cdHash == expected.cdHash, "CDHash \(slice.architecture)")
            #expect(slice.cdHash?.count == 40)
            #expect(slice.signingID == expected.signingID, "SigningID \(slice.architecture)")
            #expect(slice.designatedRequirement == expected.designatedRequirement, "DR \(slice.architecture)")
            if expected.teamID == nil && slice.signingState == .apple {
                #expect(slice.teamID == CodeSignatureInspector.appleTeamPlaceholder)
            } else {
                #expect(slice.teamID == expected.teamID, "TeamID \(slice.architecture)")
            }
            #expect(slice.signingState == subject.expectedState, "SigningState \(slice.architecture)")
        }
    }

    @Test func universalAppSlicesHaveDifferentCDHashes() throws {
        let universal = try #require(
            subjects.lazy.compactMap { try? CodeSignatureInspector.inspect(URL(filePath: $0.path)) }
                .first { $0.slices.count > 1 },
            "No universal app found on this Mac"
        )
        let hashes = universal.slices.compactMap(\.cdHash)
        #expect(hashes.count == universal.slices.count)
        #expect(Set(hashes).count == hashes.count)
    }

    @Test func composedIdentifierUsesBundleIDAndDesignatedRequirement() throws {
        let safari = try #require(subjects.first { $0.path.hasSuffix("Safari.app") })
        let inspection = try CodeSignatureInspector.inspect(URL(filePath: safari.path))
        let requirement = try #require(inspection.designatedRequirement)
        #expect(inspection.composedIdentifier == "com.apple.Safari {\(requirement)}")
        #expect(inspection.suggestedPathPrefix == safari.path + "/")
        let holds1 = inspection.defaultSlices.allSatisfy(\.isAppleSilicon)
        #expect(holds1)
    }

    @Test func bareExecutableIsInspected() throws {
        let inspection = try CodeSignatureInspector.inspect(URL(filePath: "/bin/ls"))
        #expect(!inspection.isBundle)
        #expect(inspection.suggestedPathPrefix == "/bin/ls")
        let holds2 = inspection.slices.allSatisfy { $0.signingState == .apple }
        #expect(holds2)
        let holds3 = inspection.slices.allSatisfy { $0.teamID == CodeSignatureInspector.appleTeamPlaceholder }
        #expect(holds3)
    }

    @Test func missingPartsGiveNoComposedIdentifier() {
        #expect(CodeSignatureInspector.composedIdentifier(bundleID: nil, designatedRequirement: "anchor apple") == nil)
        #expect(CodeSignatureInspector.composedIdentifier(bundleID: "com.example", designatedRequirement: "") == nil)
    }

    @Test func unsignedBinaryIsNeverApple() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appending(path: "ls-unsigned")
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: copy.path(percentEncoded: false))
        _ = try run("/usr/bin/codesign", ["--remove-signature", copy.path(percentEncoded: false)])

        let inspection = try CodeSignatureInspector.inspect(copy)
        #expect(inspection.verification != .valid)
        let holds4 = inspection.slices.allSatisfy { $0.signingState == .unknown }
        #expect(holds4)
        let holds5 = inspection.slices.allSatisfy { $0.teamID == nil }
        #expect(holds5)
        let holds6 = inspection.slices.allSatisfy { $0.signingState.declarationValue == nil }
        #expect(holds6)
    }
}

@Suite("Mach-O slices")
struct MachOSlicesTests {
    private func write(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data(bytes).write(to: url)
        return url
    }

    private func be(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    @Test func readsFatHeader() throws {
        // x86_64 (0x01000007/3), arm64e with ptrauth ABI bit (0x0100000c/0x80000002), arm64e.x1 (subtype 12).
        var bytes = be(0xCAFE_BABE) + be(3)
        for (type, subtype) in [(0x0100_0007, 3), (0x0100_000C, 0x8000_0002), (0x0100_000C, 0x8000_000C)] as [(UInt32, UInt32)] {
            bytes += be(type) + be(subtype) + be(0) + be(0) + be(0)
        }
        let url = try write(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let slices = MachOSlices.slices(at: url)
        #expect(slices.map(\.architecture) == ["x86_64", "arm64e", "arm64e.x1"])
        #expect(MachOSlices.preferredOrder(slices).map(\.architecture) == ["arm64e", "arm64e.x1", "x86_64"])
    }

    @Test func readsThinLittleEndianHeader() throws {
        let url = try write([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MachOSlices.slices(at: url).map(\.architecture) == ["arm64"])
    }

    @Test func rejectsNonMachO() throws {
        let java = try write(be(0xCAFE_BABE) + be(0x0034_0000))
        let text = try write(Array("#!/bin/sh\n".utf8))
        defer {
            try? FileManager.default.removeItem(at: java)
            try? FileManager.default.removeItem(at: text)
        }
        #expect(MachOSlices.slices(at: java).isEmpty)
        #expect(MachOSlices.slices(at: text).isEmpty)
    }

    @Test func matchesLipoForSafari() throws {
        let executable = "/System/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari"
        try #require(FileManager.default.fileExists(atPath: executable))
        let lipo = try lipoArchs(executable)
        #expect(MachOSlices.slices(at: URL(filePath: executable)).map(\.architecture) == lipo)
    }
}

@Suite("Local app scanner")
struct LocalAppScannerTests {
    @Test func stopsAtAppsAndSkipsSymlinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        for folder in ["Zeta.app/Contents/Helpers/Inner.app", "Vendor/alpha.app", "Utilities/Beta.app", "Other"] {
            try fm.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(at: root.appending(path: "Linked.app"), withDestinationURL: root.appending(path: "Utilities/Beta.app"))

        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        let results = LocalAppScanner.scan(folders: [rootPath, rootPath])
        #expect(results.map(\.name) == ["alpha", "Beta", "Zeta"])
        #expect(!results.contains { $0.name == "Inner" || $0.name == "Linked" })
    }

    @Test func defaultFoldersMatchAppSettingsUtility() {
        #expect(LocalAppScanner.defaultFolders == [
            "/Applications", "/System/Applications", "/System/Cryptexes/App/System/Applications",
        ])
    }

    @Test func acceptsAppsAndExecutablesOnly() {
        #expect(LocalAppScanner.entry(for: URL(filePath: "/System/Applications/Calculator.app"))?.name == "Calculator")
        #expect(LocalAppScanner.entry(for: URL(filePath: "/bin/ls"))?.name == "ls")
        #expect(LocalAppScanner.entry(for: URL(filePath: "/etc/hosts")) == nil)
        #expect(LocalAppScanner.entry(for: URL(filePath: "/System/Library")) == nil)
    }
}
