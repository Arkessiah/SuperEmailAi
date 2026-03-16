import SwiftUI

struct FolderPickerSheet: View {
    @EnvironmentObject var manager: MailManager
    @Binding var moveTarget: ContentView.MoveTarget?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFolder: String = ""
    @State private var searchText = ""

    var filteredMailboxes: [String] {
        if searchText.isEmpty { return manager.mailboxes }
        return manager.mailboxes.filter {
            $0.lowercased().contains(searchText.lowercased())
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Mover correos a...")
                    .font(.title3.bold())
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()

            // Description
            Group {
                switch moveTarget {
                case .selected:
                    Text("Mover \(manager.selectedMessages.count) correos seleccionados")
                case .sender(let sender):
                    Text("Mover \(sender.count) correos de \(sender.displayName)")
                case .none:
                    Text("Selecciona correos primero")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal)

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Buscar carpeta...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary)
            .cornerRadius(8)
            .padding()

            // Folder list
            List(filteredMailboxes, id: \.self, selection: $selectedFolder) { folder in
                HStack {
                    Image(systemName: folderIcon(for: folder))
                        .foregroundStyle(.blue)
                    Text(folder)
                    Spacer()
                    if selectedFolder == folder {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedFolder = folder
                }
            }

            Divider()

            // Confirm button
            HStack {
                Spacer()
                Button("Mover aqui") {
                    guard !selectedFolder.isEmpty else { return }
                    Task {
                        switch moveTarget {
                        case .selected:
                            await manager.moveSelectedMessages(to: selectedFolder)
                        case .sender(let sender):
                            await manager.moveMessagesFromSender(sender, to: selectedFolder)
                        case .none:
                            break
                        }
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFolder.isEmpty)
            }
            .padding()
        }
        .frame(width: 400, height: 500)
    }

    private func folderIcon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("inbox") { return "tray.fill" }
        if lower.contains("sent") { return "paperplane.fill" }
        if lower.contains("trash") || lower.contains("papelera") { return "trash.fill" }
        if lower.contains("draft") || lower.contains("borrador") { return "pencil" }
        if lower.contains("junk") || lower.contains("spam") { return "xmark.bin.fill" }
        if lower.contains("archive") || lower.contains("archivo") { return "archivebox.fill" }
        return "folder.fill"
    }
}
