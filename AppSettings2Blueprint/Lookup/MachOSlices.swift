import Foundation

/// One architecture slice of a Mach-O executable.
nonisolated struct MachOSlice: Hashable, Sendable {
    let cpuType: Int32
    let cpuSubtype: Int32

    /// The name `lipo -archs` prints, e.g. `arm64`, `arm64e`, `arm64e.x1`, `x86_64`.
    var architecture: String { MachOSlices.architectureName(cpuType: cpuType, cpuSubtype: cpuSubtype) }

    var isAppleSilicon: Bool { architecture.hasPrefix("arm") }
}

/// Reads the architecture slices from a Mach-O file's header: the equivalent of
/// `lipo -archs`, without running lipo.
nonisolated enum MachOSlices {
    private static let fatMagic: UInt32 = 0xCAFE_BABE
    private static let fatMagic64: UInt32 = 0xCAFE_BABF
    private static let thinMagics: Set<UInt32> = [0xFEED_FACE, 0xFEED_FACF]
    private static let thinCigams: Set<UInt32> = [0xCEFA_EDFE, 0xCFFA_EDFE]
    /// Java class files share the fat magic; real fat files have only a handful of slices.
    private static let maxFatSlices: UInt32 = 32

    private static let cpuArchABI64: Int32 = 0x0100_0000
    private static let cpuArchABI64_32: Int32 = 0x0200_0000
    private static let cpuTypeX86: Int32 = 7
    private static let cpuTypeARM: Int32 = 12
    /// Capability bits in the subtype (for arm64e: pointer-authentication ABI).
    private static let subtypeMask: Int32 = Int32(bitPattern: 0xFF00_0000)

    /// Returns the slices of the Mach-O file at `url`, in file order, or an empty
    /// array when the file is not a Mach-O executable.
    static func slices(at url: URL) -> [MachOSlice] {
        // A FIFO or device file would block the read; only regular files can be Mach-O.
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return [] }
        let magic = bigEndian32(header, at: 0)

        if magic == fatMagic || magic == fatMagic64 {
            let count = bigEndian32(header, at: 4)
            guard count > 0, count <= maxFatSlices else { return [] }
            let entrySize = magic == fatMagic64 ? 32 : 20
            guard let table = try? handle.read(upToCount: Int(count) * entrySize),
                  table.count == Int(count) * entrySize else { return [] }
            return (0..<Int(count)).map { index in
                let offset = index * entrySize
                return MachOSlice(
                    cpuType: Int32(bitPattern: bigEndian32(table, at: offset)),
                    cpuSubtype: Int32(bitPattern: bigEndian32(table, at: offset + 4))
                )
            }
        }
        if thinMagics.contains(magic) {
            return [MachOSlice(cpuType: Int32(bitPattern: bigEndian32(header, at: 4)),
                               cpuSubtype: Int32(bitPattern: headerSubtype(handle, bigEndian: true)))]
        }
        if thinCigams.contains(magic) {
            return [MachOSlice(cpuType: Int32(bitPattern: littleEndian32(header, at: 4)),
                               cpuSubtype: Int32(bitPattern: headerSubtype(handle, bigEndian: false)))]
        }
        return []
    }

    /// Architecture names as `lipo` and `codesign --arch` spell them (from <mach/machine.h>).
    static func architectureName(cpuType: Int32, cpuSubtype: Int32) -> String {
        let subtype = cpuSubtype & ~subtypeMask
        switch cpuType {
        case cpuTypeX86 | cpuArchABI64:
            return subtype == 8 ? "x86_64h" : "x86_64"
        case cpuTypeX86:
            return "i386"
        case cpuTypeARM | cpuArchABI64:
            switch subtype {
            case 0: return "arm64"
            case 1: return "arm64v8"
            case 2: return "arm64e"
            case 3: return "arm64.x1"
            case 12: return "arm64e.x1"
            default: break
            }
        case cpuTypeARM | cpuArchABI64_32:
            return "arm64_32"
        default:
            break
        }
        return "cputype \(cpuType) subtype \(subtype)"
    }

    private static func headerSubtype(_ handle: FileHandle, bigEndian: Bool) -> UInt32 {
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return 0 }
        return bigEndian ? bigEndian32(data, at: 0) : littleEndian32(data, at: 0)
    }

    private static func bigEndian32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return data[start..<start + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func littleEndian32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return data[start..<start + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }
}
