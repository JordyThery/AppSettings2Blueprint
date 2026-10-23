import Foundation

// Ported from cantscript/AppSettingsUtility (MIT) — reads the CSV layouts that
// create_csv and export_local_csv in appSettingsUtility.sh write.
/// Reads App Settings Utility CSV files. The layout is recognised from the header
/// row, which must match one of the two column lists exactly and in order.
nonisolated enum CSVImporter {
    struct ImportError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func importDocument(_ text: String) throws -> CSVDocument {
        // Blank lines (often a trailing one left by an editor) are not rows.
        let records = try parse(text).filter { $0 != [.null] }
        guard let header = records.first else { throw ImportError(message: "The file is empty.") }
        let names = header.map { $0.value ?? "" }
        guard let format = CSVFormat.allCases.first(where: { $0.columns == names }) else {
            throw ImportError(message: "The header row does not match either App Settings Utility layout (BundleID-Lookup or Local-Mac-Apps).")
        }
        let rows = records.dropFirst()
        for (index, row) in rows.enumerated() where row.count != format.columns.count {
            throw ImportError(message: "Row \(index + 2) has \(row.count) columns; expected \(format.columns.count).")
        }
        switch format {
        case .bundleIDLookup: return .bundleIDLookup(rows.map(BundleIDLookupRow.init(fields:)))
        case .localMacApps: return .localMacApps(rows.map(LocalMacAppRow.init(fields:)))
        }
    }

    /// RFC 4180 parsing that remembers whether each cell was quoted. Accepts `\n`
    /// and `\r\n` line endings and newlines inside quoted cells.
    static func parse(_ text: String) throws -> [[CSVField]] {
        var records: [[CSVField]] = []
        var record: [CSVField] = []
        var cell = ""
        var quoted = false
        var inQuotes = false
        var cellStarted = false
        var iterator = Array(text.unicodeScalars).makeIterator()
        var pending: Unicode.Scalar?

        func endCell() {
            record.append(quoted ? .text(cell) : (cell.isEmpty ? .null : .bare(cell)))
            cell = ""
            quoted = false
            cellStarted = false
        }
        func endRecord() {
            endCell()
            records.append(record)
            record = []
        }

        while let scalar = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if scalar == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { cell.unicodeScalars.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    cell.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"" where !cellStarted:
                inQuotes = true
                quoted = true
                cellStarted = true
            case "\"":
                throw ImportError(message: "A quote appears inside an unquoted cell (record \(records.count + 1)).")
            case ",":
                endCell()
            case "\r":
                if let next = iterator.next(), next != "\n" { pending = next }
                endRecord()
            case "\n":
                endRecord()
            default:
                if quoted { throw ImportError(message: "Text follows a closing quote (record \(records.count + 1)).") }
                cell.unicodeScalars.append(scalar)
                cellStarted = true
            }
        }
        if inQuotes { throw ImportError(message: "A quoted cell is not closed.") }
        // A final line without a trailing newline still counts.
        if cellStarted || !record.isEmpty { endRecord() }
        return records
    }
}
