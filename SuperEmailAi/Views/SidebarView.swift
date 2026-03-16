import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var manager: MailManager
    @Binding var showDuplicates: Bool
    @State private var searchText = ""

    var filteredSenders: [SenderGroup] {
        if searchText.isEmpty { return manager.senderGroups }
        let query = searchText.lowercased()
        return manager.senderGroups.filter {
            $0.address.lowercased().contains(query) ||
            $0.displayName.lowercased().contains(query) ||
            $0.domain.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Buscar remitente o dominio...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.quaternary)
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // Sort picker
            HStack {
                Text("Ordenar:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $manager.sortOrder) {
                    ForEach(MailManager.SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: manager.sortOrder) {
                    manager.applySortOrder()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            // Action buttons
            HStack(spacing: 8) {
                Button {
                    manager.selectSender(nil)
                    showDuplicates = false
                } label: {
                    Label("Todos", systemImage: "tray.full")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Button {
                    manager.findDuplicates()
                    showDuplicates = true
                } label: {
                    Label("Duplicados", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Sender list
            List(filteredSenders, selection: Binding(
                get: { manager.selectedSender?.id },
                set: { id in
                    if let id, let sender = manager.senderGroups.first(where: { $0.id == id }) {
                        manager.selectSender(sender)
                        showDuplicates = false
                    }
                }
            )) { sender in
                SenderRow(sender: sender)
                    .tag(sender.id)
                    .contextMenu {
                        SenderContextMenu(sender: sender)
                    }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 280)
    }
}

// MARK: - Sender Row

struct SenderRow: View {
    let sender: SenderGroup

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(sender.displayName)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)
                Text(sender.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(sender.count)")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(sender.count > 50 ? .red : sender.count > 20 ? .orange : .primary)
                if sender.unreadCount > 0 {
                    Text("\(sender.unreadCount) sin leer")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Context Menu

struct SenderContextMenu: View {
    @EnvironmentObject var manager: MailManager
    let sender: SenderGroup

    var body: some View {
        Button {
            manager.selectSender(sender)
        } label: {
            Label("Ver correos (\(sender.count))", systemImage: "envelope")
        }

        Divider()

        // Navigate to sender view where delete has confirmation
        Button {
            manager.selectSender(sender)
        } label: {
            Label("Gestionar correos de \(sender.displayName)", systemImage: "slider.horizontal.3")
        }

        Menu("Mover todos a...") {
            ForEach(manager.mailboxes, id: \.self) { mb in
                Button(mb) {
                    Task { await manager.moveMessagesFromSender(sender, to: mb) }
                }
            }
        }
    }
}
