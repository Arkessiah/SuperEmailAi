import SwiftUI
import AppKit

/// Native NSTableView-backed message list: rock-solid multi-selection
/// (click / Cmd-click / Shift-click), native double-click to open, and
/// keyboard triage (J/K move, E archive, U read, Delete trash, Return open).
struct MessageTableView: NSViewRepresentable {
    let messages: [MailMessage]
    var importantSenders: Set<String> = []
    @Binding var selection: Set<String>
    var onOpen: (MailMessage) -> Void
    var onToggleImportant: (MailMessage) -> Void = { _ in }
    var onDelete: () -> Void
    var onArchive: () -> Void
    var onToggleRead: () -> Void
    var onLoadMore: () -> Void
    var onMove: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyTableView()
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.rowHeight = 54
        table.backgroundColor = .clear
        table.style = .inset
        table.intercellSpacing = NSSize(width: 0, height: 2)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.keyHandler = { [weak coordinator = context.coordinator] key in
            coordinator?.handleKey(key) ?? false
        }

        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        context.coordinator.tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = nsView.documentView as? NSTableView else { return }

        let oldIDs = context.coordinator.messages.map(\.id)
        let newIDs = messages.map(\.id)
        context.coordinator.messages = messages
        let importantChanged = context.coordinator.importantSenders != importantSenders
        context.coordinator.importantSenders = importantSenders
        if oldIDs != newIDs || importantChanged {
            table.reloadData()
        }

        let desired = IndexSet(messages.enumerated().compactMap { selection.contains($0.element.id) ? $0.offset : nil })
        if table.selectedRowIndexes != desired {
            context.coordinator.isSyncing = true
            table.selectRowIndexes(desired, byExtendingSelection: false)
            context.coordinator.isSyncing = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: MessageTableView
        var messages: [MailMessage]
        var importantSenders: Set<String> = []
        weak var tableView: NSTableView?
        var isSyncing = false

        init(_ parent: MessageTableView) {
            self.parent = parent
            self.messages = parent.messages
        }

        func numberOfRows(in tableView: NSTableView) -> Int { messages.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard messages.indices.contains(row) else { return nil }
            if row >= messages.count - 6 {
                DispatchQueue.main.async { self.parent.onLoadMore() }
            }
            let message = messages[row]
            let important = parent.importantSenders.contains(message.senderAddress)
            let hosting = NSHostingView(rootView: MessageRow(message: message, isImportant: important))
            hosting.layer?.backgroundColor = .clear
            return hosting
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let table = tableView else { return }
            let ids = table.selectedRowIndexes.compactMap { messages.indices.contains($0) ? messages[$0].id : nil }
            parent.selection = Set(ids)
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let table = tableView, table.clickedRow >= 0,
                  messages.indices.contains(table.clickedRow) else { return }
            parent.onOpen(messages[table.clickedRow])
        }

        /// Returns true if the key was handled.
        func handleKey(_ key: String) -> Bool {
            switch key {
            case "delete":
                parent.onDelete()
                return true
            case "\r":
                if let row = tableView?.selectedRow, messages.indices.contains(row) {
                    parent.onOpen(messages[row])
                    return true
                }
            case "j": move(by: 1); return true
            case "k": move(by: -1); return true
            case "e": parent.onArchive(); return true
            case "u": parent.onToggleRead(); return true
            default: break
            }
            return false
        }

        private func move(by delta: Int) {
            guard let table = tableView, !messages.isEmpty else { return }
            let current = table.selectedRow
            let start = current < 0 ? (delta > 0 ? -1 : messages.count) : current
            let next = max(0, min(messages.count - 1, start + delta))
            table.selectRowIndexes([next], byExtendingSelection: false)
            table.scrollRowToVisible(next)
        }

        // MARK: - Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table = tableView else { return }
            let clicked = table.clickedRow
            if clicked >= 0, !table.selectedRowIndexes.contains(clicked) {
                table.selectRowIndexes([clicked], byExtendingSelection: false)
            }
            let count = table.selectedRowIndexes.count
            guard count > 0 else { return }

            let open = NSMenuItem(title: "Abrir", action: #selector(openAction), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            menu.addItem(.separator())
            let del = NSMenuItem(title: "Eliminar \(count)", action: #selector(deleteAction), keyEquivalent: "")
            del.target = self
            menu.addItem(del)
            let mov = NSMenuItem(title: "Mover \(count)…", action: #selector(moveAction), keyEquivalent: "")
            mov.target = self
            menu.addItem(mov)

            if let row = table.selectedRowIndexes.first, messages.indices.contains(row) {
                let isImportant = importantSenders.contains(messages[row].senderAddress)
                menu.addItem(.separator())
                let star = NSMenuItem(
                    title: isImportant ? "Quitar importancia al remitente" : "Marcar remitente como importante",
                    action: #selector(toggleImportantAction), keyEquivalent: ""
                )
                star.target = self
                menu.addItem(star)
            }
        }

        @objc private func openAction() {
            guard let row = tableView?.selectedRow, messages.indices.contains(row) else { return }
            parent.onOpen(messages[row])
        }

        @objc private func deleteAction() { parent.onDelete() }
        @objc private func moveAction() { parent.onMove() }
        @objc private func toggleImportantAction() {
            guard let row = tableView?.selectedRow, messages.indices.contains(row) else { return }
            parent.onToggleImportant(messages[row])
        }
    }
}

/// NSTableView subclass that routes key presses to a handler before its defaults.
final class KeyTableView: NSTableView {
    var keyHandler: ((String) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {   // delete / forward-delete
            if keyHandler?("delete") == true { return }
        }
        if let chars = event.charactersIgnoringModifiers, keyHandler?(chars) == true {
            return
        }
        super.keyDown(with: event)
    }
}
