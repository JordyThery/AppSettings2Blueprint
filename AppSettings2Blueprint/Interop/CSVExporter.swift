import Foundation

/// Writes App Settings Utility's CSV layouts exactly as jq's `@csv` does:
/// every header and string quoted with `"` doubled, numbers bare, null empty,
/// one `\n` after every line.
nonisolated enum CSVExporter {
    // Ported from cantscript/AppSettingsUtility (MIT) — create_csv and export_local_csv in appSettingsUtility.sh
    static func export(_ document: CSVDocument) -> String {
        let header = document.format.columns.map(CSVField.text)
        return ([header] + document.fieldRows).map(line).joined()
    }

    static func line(_ fields: [CSVField]) -> String {
        fields.map(cell).joined(separator: ",") + "\n"
    }

    private static func cell(_ field: CSVField) -> String {
        switch field {
        case .text(let text): "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        case .bare(let text): text
        case .null: ""
        }
    }
}
