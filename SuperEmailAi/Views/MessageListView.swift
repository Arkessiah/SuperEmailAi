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
        Group {
            if manager.isReadingOpen {
                HSplitView {
                    listColumn
                        .frame(minWidth: 380)
                    MessageDetailPane()
                        .cardStyle()
                        .padding(8)
                        .frame(minWidth: 340, idealWidth: 460)
                        .background(Color.appBackground)
                }
            } else {
                listColumn
            }
        }
        .sheet(isPresented: $showDeleteConfirmation) {
            DeleteConfirmationView(messages: messagesToDelete) {
                Task { await manager.deleteSelectedMessages() }
            }
        }
    }

    // MARK: - Loading overlay

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Cargando correos…")
                .font(.headline)
            if let progress = manager.loadProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 240)
                Text("\(Int(progress * 100))%")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText())
            }
            Text(manager.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut, value: manager.loadProgress)
    }

    // MARK: - List column

    private var listColumn: some View {
        VStack(spacing: 0) {
            if let sender = manager.selectedSender {
                SenderHeader(
                    sender: sender,
                    showMoveSheet: $showMoveSheet,
                    moveTarget: $moveTarget,
                    showDeleteConfirmation: $showDeleteConfirmation,
                    messagesToDelete: $messagesToDelete
                )
            }

            // Search + bulk actions
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filtrar por asunto, remitente...", text: $searchText)
                    .textFieldStyle(.plain)

                Spacer()

                if !manager.selectedMessages.isEmpty {
                    BulkActionButtons(
                        showMoveSheet: $showMoveSheet,
                        moveTarget: $moveTarget,
                        showDeleteConfirmation: $showDeleteConfirmation,
                        messagesToDelete: $messagesToDelete
                    )
                }

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

            if manager.isLoading && manager.allMessages.isEmpty {
                loadingView
            } else if displayedMessages.isEmpty {
                ContentUnavailableView {
                    Label(
                        manager.allMessages.isEmpty ? "Sin correos" : "Sin resultados",
                        systemImage: manager.allMessages.isEmpty ? "tray" : "magnifyingglass"
                    )
                } description: {
                    Text(manager.allMessages.isEmpty
                         ? "Selecciona un buzón para cargar correos"
                         : "Prueba con otro termino de busqueda")
                }
            } else {
                List(selection: $manager.selectedMessages) {
                    ForEach(displayedMessages) { msg in
                        MessageRow(message: msg)
                            .tag(msg.id)
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                Task { await manager.openForReading(msg) }
                            })
                            .contextMenu {
                                let targets = manager.selectedMessages.contains(msg.id)
                                    ? displayedMessages.filter { manager.selectedMessages.contains($0.id) }
                                    : [msg]
                                Button {
                                    Task { await manager.openForReading(msg) }
                                } label: {
                                    Label("Abrir", systemImage: "envelope.open")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    manager.selectedMessages = Set(targets.map(\.id))
                                    messagesToDelete = targets
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Eliminar \(targets.count)", systemImage: "trash")
                                }
                                Button {
                                    manager.selectedMessages = Set(targets.map(\.id))
                                    moveTarget = .selected
                                    showMoveSheet = true
                                } label: {
                                    Label("Mover \(targets.count)…", systemImage: "folder")
                                }
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.appBackground)
    }
}

// MARK: - Message Row (email-style)

struct MessageRow: View {
    let message: MailMessage

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(message.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(message.sender)
                        .font(.system(.body, weight: message.isRead ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(message.dateReceived, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(message.subject)
                    .font(.subheadline)
                    .foregroundStyle(message.isRead ? .secondary : .primary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
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

// MARK: - Message Detail (reading pane)

struct MessageDetailPane: View {
    @EnvironmentObject var manager: MailManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    manager.closeReading()
                } label: {
                    Label("Cerrar", systemImage: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding(8)

            Divider()

            if let msg = manager.openedMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(msg.subject)
                        .font(.title3.bold())
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(msg.sender)
                            .font(.subheadline.weight(.medium))
                        Text("<\(msg.senderAddress)>")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(msg.dateReceived.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)

                Divider()

                if manager.isLoadingBody {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let html = manager.openedHTML {
                    HTMLView(html: html)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(manager.openedBody)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
