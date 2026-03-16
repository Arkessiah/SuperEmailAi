import SwiftUI

struct DuplicatesView: View {
    @EnvironmentObject var manager: MailManager
    @State private var expandedGroup: UUID?
    @State private var showDeleteConfirmation = false
    @State private var groupToDelete: DuplicateGroup?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Correos Duplicados")
                        .font(.title2.bold())
                    Text("\(manager.duplicateGroups.count) grupos de duplicados encontrados (\(totalDuplicates) correos extra)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Button {
                    manager.findDuplicates()
                } label: {
                    Label("Buscar duplicados", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .background(.quaternary.opacity(0.5))

            Divider()

            if manager.duplicateGroups.isEmpty {
                ContentUnavailableView {
                    Label("Sin duplicados", systemImage: "checkmark.circle")
                } description: {
                    Text("No se encontraron correos duplicados (mismo remitente y asunto)")
                }
            } else {
                List {
                    ForEach(manager.duplicateGroups) { group in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedGroup == group.id },
                                set: { expandedGroup = $0 ? group.id : nil }
                            )
                        ) {
                            ForEach(group.messages) { msg in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(msg.subject)
                                            .lineLimit(1)
                                        Text(msg.dateReceived, style: .date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(msg.mailbox)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.subject)
                                        .font(.body.bold())
                                        .lineLimit(1)
                                    Text(group.sender)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text("\(group.count) copias")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.orange.opacity(0.15))
                                    .foregroundStyle(.orange)
                                    .cornerRadius(6)

                                Button(role: .destructive) {
                                    groupToDelete = group
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Eliminar extras", systemImage: "trash")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showDeleteConfirmation) {
            if let group = groupToDelete {
                let extras = Array(group.messages.dropFirst())
                DeleteConfirmationView(messages: extras) {
                    Task { await deleteKeepingOne(group) }
                }
            }
        }
    }

    private var totalDuplicates: Int {
        manager.duplicateGroups.reduce(0) { $0 + $1.count - 1 }
    }

    private func deleteKeepingOne(_ group: DuplicateGroup) async {
        let toDelete = Array(group.messages.dropFirst())
        let ids = toDelete.map(\.messageId)

        do {
            _ = try await MailBridge.shared.deleteMessages(
                ids: ids,
                mailbox: toDelete.first?.mailbox ?? "INBOX",
                account: nil
            )
            let idsToRemove = Set(toDelete.map(\.id))
            await MainActor.run {
                manager.allMessages.removeAll { idsToRemove.contains($0.id) }
                manager.findDuplicates()
            }
        } catch {
            await MainActor.run {
                manager.errorMessage = error.localizedDescription
            }
        }
    }
}
