import AppKit
import MScanCore

@MainActor
enum ScanPrint {
    static func present(headers: [String], rows: [[String]]) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let width = max(150, info.paperSize.width - info.leftMargin - info.rightMargin)
        let content = makeTextView(headers: headers, rows: rows, width: width)
        let operation = NSPrintOperation(view: content, printInfo: info)
        operation.jobTitle = inventoryText("MScan Scan Results")
        operation.run()
    }

    // A list of labeled fields works on portrait paper even when the scanner
    // shows every column. Long comments and IPv6 addresses wrap naturally.
    static func makeTextView(headers: [String], rows: [[String]], width: CGFloat) -> NSTextView {
        let output = NSMutableAttributedString()
        func append(_ value: String, font: NSFont) {
            output.append(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: NSColor.black]))
        }
        append(inventoryText("MScan · Scan Results") + "\n", font: .boldSystemFont(ofSize: 19))
        let date = Date.now.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale))
        append(L10n.format("print.summary", date, rows.count, table: "Inventory") + "\n", font: .systemFont(ofSize: 10))
        for (index, row) in rows.enumerated() {
            append("\n" + L10n.format("print.device", index + 1, table: "Inventory") + "\n", font: .boldSystemFont(ofSize: 12))
            for (label, value) in zip(headers, row) where !value.isEmpty {
                append(label + inventoryText("print.separator"), font: .boldSystemFont(ofSize: 10))
                append(value + "\n", font: .systemFont(ofSize: 10))
            }
        }
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 50))
        view.isEditable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(output)
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
            let bounds = layout.usedRect(for: container)
            view.setFrameSize(NSSize(width: width, height: max(50, ceil(bounds.maxY))))
        }
        return view
    }
}
