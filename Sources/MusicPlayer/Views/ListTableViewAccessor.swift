import SwiftUI
import AppKit

struct ListTableViewAccessor: NSViewRepresentable {
    let onResolve: (NSTableView?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            onResolve(resolveTableView(from: view))
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(resolveTableView(from: nsView))
        }
    }

    private func resolveTableView(from view: NSView) -> NSTableView? {
        var current: NSView? = view
        while let candidate = current {
            if let tableView = candidate as? NSTableView {
                return tableView
            }

            if let scrollView = candidate as? NSScrollView,
               let documentView = scrollView.documentView,
               let tableView = findTableView(in: documentView) {
                return tableView
            }

            current = candidate.superview
        }

        if let scrollView = view.enclosingScrollView,
           let documentView = scrollView.documentView,
           let tableView = findTableView(in: documentView) {
            return tableView
        }

        return findTableView(in: view)
    }

    private func findTableView(in root: NSView) -> NSTableView? {
        if let tableView = root as? NSTableView {
            return tableView
        }

        for child in root.subviews {
            if let found = findTableView(in: child) {
                return found
            }
        }
        return nil
    }
}

@MainActor
func centerListRow(_ row: Int, in tableView: NSTableView) {
    guard row >= 0, row < tableView.numberOfRows else { return }

    tableView.scrollRowToVisible(row)

    guard let scrollView = tableView.enclosingScrollView else { return }

    tableView.layoutSubtreeIfNeeded()
    let rowRect = tableView.rect(ofRow: row)
    guard !rowRect.isEmpty else { return }

    let viewportHeight = scrollView.contentView.bounds.height
    let maxOffsetY = max(0, tableView.bounds.height - viewportHeight)
    let desiredOffsetY = min(max(0, rowRect.midY - viewportHeight / 2), maxOffsetY)

    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: desiredOffsetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
