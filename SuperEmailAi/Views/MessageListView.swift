import SwiftUI

struct MessageListView: View {
    @EnvironmentObject var manager: MailManager
    @Binding var showMoveSheet: Bool
    @Binding var moveTarget: ContentView.MoveTarget?
    @State private var searchText = ""
    @State private var category: MailCategory? = nil
    @State private var showDeleteConfirmation = false
    @State private var messagesToDelete: [MailMessage] = []

    var displayedMessages: [MailMessage] {
        var list = manager.filteredMessages
        if let category {
            list = list.filter { manager.category(for: $0) == category }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            list = list.filter {
                $0.subject.lowercased().contains(query) ||
                $0.sender.lowercased().contains(query) ||
                $0.senderAddress.lowercased().contains(query)
            }
        }
        return list
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

                Menu {
                    Picker("Ordenar por", selection: $manager.messageSort) {
                        ForEach(MailManager.MessageSort.allCases, id: \.self) { sort in
                            Text(sort.rawValue).tag(sort)
                        }
                    }
                } label: {
                    Label("Orden: \(manager.messageSort.rawValue)", systemImage: "arrow.up.arrow.down")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Ordenar por fecha, importancia del remitente o tamaño")

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

            Picker("", selection: Binding(
                get: { category?.rawValue ?? "Todo" },
                set: { category = ($0 == "Todo") ? nil : MailCategory(rawValue: $0) }
            )) {
                Text("Todo").tag("Todo")
                ForEach(MailCategory.allCases, id: \.self) { c in
                    Text(c.rawValue).tag(c.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

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
                MessageTableView(
                    messages: displayedMessages,
                    importantSenders: manager.importantSenders,
                    selection: $manager.selectedMessages,
                    onOpen: { msg in Task { await manager.openForReading(msg) } },
                    onToggleImportant: { manager.toggleImportant($0.senderAddress) },
                    onDelete: {
                        if !manager.selectedMessages.isEmpty {
                            messagesToDelete = manager.allMessages.filter { manager.selectedMessages.contains($0.id) }
                            showDeleteConfirmation = true
                        }
                    },
                    onArchive: { Task { await manager.archiveSelection() } },
                    onToggleRead: { Task { await manager.toggleReadForSelection() } },
                    onLoadMore: { Task { await manager.loadMoreMessages() } },
                    onMove: {
                        if !manager.selectedMessages.isEmpty {
                            moveTarget = .selected
                            showMoveSheet = true
                        }
                    }
                )
            }
        }
        .background(Color.appBackground)
    }
}

// MARK: - Message Row (email-style)

struct MessageRow: View {
    let message: MailMessage
    var isImportant: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(message.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    if isImportant {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Text(message.sender)
                        .font(.system(.body, weight: message.isRead ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer()
                    if !message.sizeText.isEmpty {
                        Text(message.sizeText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(dateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(message.subject)
                    .font(.subheadline)
                    .foregroundStyle(message.isRead ? .secondary : .primary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    /// Time for today's messages, date for older ones (Mail/Spark style).
    private var dateText: String {
        if Calendar.current.isDateInToday(message.dateReceived) {
            return message.dateReceived.formatted(date: .omitted, time: .shortened)
        }
        return message.dateReceived.formatted(date: .abbreviated, time: .omitted)
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

                if manager.openedHTML != nil && !manager.showRemoteImages {
                    Button {
                        manager.showRemoteImages = true
                    } label: {
                        Label("Mostrar imágenes", systemImage: "photo")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .help("Cargar imágenes remotas (puede avisar al remitente de que abriste el correo)")
                }
            }
            .padding(8)

            Divider()

            if manager.openedUnsubscribeURL != nil {
                HStack(spacing: 8) {
                    Image(systemName: "nosign").foregroundStyle(.orange)
                    Text("Boletín")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { manager.unsubscribeFromOpened() } label: {
                        Label("Desuscribir", systemImage: "hand.raised").font(.caption)
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) {
                        Task { await manager.deleteAllFromOpenedSender() }
                    } label: {
                        Label("Borrar todos de este remitente", systemImage: "trash").font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.08))
                Divider()
            }

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
                    HTMLView(html: html, blockRemote: !manager.showRemoteImages)
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
