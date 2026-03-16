import SwiftUI

struct MessageListView: View {
    @EnvironmentObject var manager: MailManager
    @Binding var showMoveSheet: Bool
    @Binding var moveTarget: ContentView.MoveTarget?
    @State private var searchText = ""
    @State private var showDeleteConfirmation = false
    @State private var messagesToDelete: [MailMessage] = []

    var displayedMessages: [MailMessage] {
        if searchText.isEmpty { return manager.filteredMessages }
        let query = searchText.lowercased()
        return manager.filteredMessages.filter {
            $0.subject.lowercased().contains(query) ||
            $0.sender.lowercased().contains(query) ||
            $0.senderAddress.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with sender info and actions
            if let sender = manager.selectedSender {
                SenderHeader(
                    sender: sender,
                    showMoveSheet: $showMoveSheet,
                    moveTarget: $moveTarget,
                    showDeleteConfirmation: $showDeleteConfirmation,
                    messagesToDelete: $messagesToDelete
                )
            }

            // Search within results
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filtrar por asunto, remitente...", text: $searchText)
                    .textFieldStyle(.plain)

                Spacer()

                // Bulk actions
                if !manager.selectedMessages.isEmpty {
                    BulkActionButtons(
                        showMoveSheet: $showMoveSheet,
                        moveTarget: $moveTarget,
                        showDeleteConfirmation: $showDeleteConfirmation,
                        messagesToDelete: $messagesToDelete
                    )
                }

                // Select all / none
                Button {
                    if manager.selectedMessages.count == displayedMessages.count {
                        manager.deselectAll()
                    } else {
                        manager.selectAll()
                    }
                } label: {
                    Text(manager.selectedMessages.count == displayedMessages.count ? "Deseleccionar" : "Seleccionar todo")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Message table
            if displayedMessages.isEmpty {
                ContentUnavailableView {
                    Label(
                        manager.allMessages.isEmpty ? "Sin correos" : "Sin resultados",
                        systemImage: manager.allMessages.isEmpty ? "tray" : "magnifyingglass"
                    )
                } description: {
                    if manager.allMessages.isEmpty {
                        Text("Pulsa Cmd+R para cargar correos del buzon seleccionado")
                    } else {
                        Text("Prueba con otro termino de busqueda")
                    }
                }
            } else {
                Table(displayedMessages, selection: $manager.selectedMessages) {
                    TableColumn("") { msg in
                        Image(systemName: msg.isRead ? "envelope.open" : "envelope.fill")
                            .foregroundStyle(msg.isRead ? Color.secondary : Color.blue)
                            .font(.caption)
                    }
                    .width(24)

                    TableColumn("Remitente") { msg in
                        VStack(alignment: .leading) {
                            Text(msg.sender)
                                .font(.system(.body, weight: msg.isRead ? .regular : .semibold))
                                .lineLimit(1)
                            Text(msg.senderAddress)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("Asunto") { msg in
                        Text(msg.subject)
                            .font(.system(.body, weight: msg.isRead ? .regular : .semibold))
                            .lineLimit(2)
                    }
                    .width(min: 200, ideal: 350)

                    TableColumn("Fecha") { msg in
                        Text(msg.dateReceived, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Buzon") { msg in
                        Text(msg.mailbox)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 80)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if !ids.isEmpty {
                        Button(role: .destructive) {
                            manager.selectedMessages = ids
                            messagesToDelete = manager.allMessages.filter { ids.contains($0.id) }
                            showDeleteConfirmation = true
                        } label: {
                            Label("Eliminar \(ids.count) correos", systemImage: "trash")
                        }

                        Button {
                            manager.selectedMessages = ids
                            moveTarget = .selected
                            showMoveSheet = true
                        } label: {
                            Label("Mover \(ids.count) correos...", systemImage: "folder")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showDeleteConfirmation) {
            DeleteConfirmationView(messages: messagesToDelete) {
                Task { await manager.deleteSelectedMessages() }
            }
        }
    }
}

// MARK: - Sender Header

struct SenderHeader: View {
    @EnvironmentObject var manager: MailManager
    let sender: SenderGroup
    @Binding var showMoveSheet: Bool
    @Binding var moveTarget: ContentView.MoveTarget?
    @Binding var showDeleteConfirmation: Bool
    @Binding var messagesToDelete: [MailMessage]

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(sender.displayName)
                    .font(.title2.bold())
                HStack(spacing: 8) {
                    Text(sender.address)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("@\(sender.domain)")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .cornerRadius(4)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Text("\(sender.count) correos")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    messagesToDelete = sender.messages
                    // Select them so deleteSelectedMessages works
                    manager.selectedMessages = Set(sender.messages.map(\.id))
                    showDeleteConfirmation = true
                } label: {
                    Label("Eliminar todos", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button {
                    moveTarget = .sender(sender)
                    showMoveSheet = true
                } label: {
                    Label("Mover todos", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
    }
}

// MARK: - Bulk Action Buttons

struct BulkActionButtons: View {
    @EnvironmentObject var manager: MailManager
    @Binding var showMoveSheet: Bool
    @Binding var moveTarget: ContentView.MoveTarget?
    @Binding var showDeleteConfirmation: Bool
    @Binding var messagesToDelete: [MailMessage]

    var body: some View {
        HStack(spacing: 6) {
            Text("\(manager.selectedMessages.count) seleccionados")
                .font(.caption)
                .foregroundStyle(.blue)

            Button(role: .destructive) {
                messagesToDelete = manager.allMessages.filter { manager.selectedMessages.contains($0.id) }
                showDeleteConfirmation = true
            } label: {
                Label("Eliminar", systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(.red)

            Button {
                moveTarget = .selected
                showMoveSheet = true
            } label: {
                Label("Mover a...", systemImage: "folder")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }
    }
}
