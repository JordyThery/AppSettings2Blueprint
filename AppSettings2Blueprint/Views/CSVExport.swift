import AppKit
import UniformTypeIdentifiers

/// Saves an App Settings Utility CSV with its usual `<prefix>_<timestamp>.csv` name.
enum CSVExport {
    static func save(_ document: CSVDocument) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = document.format.suggestedFileName()
        panel.message = "\(document.rowCount) row\(document.rowCount == 1 ? "" : "s") in App Settings Utility's \(document.format.filePrefix) layout."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try Data(CSVExporter.export(document).utf8).write(to: url, options: .atomic)
    }
}
