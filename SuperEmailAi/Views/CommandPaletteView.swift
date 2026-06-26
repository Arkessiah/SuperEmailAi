import SwiftUI

/// A command for the Cmd+K palette.
struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let action: () -> Void
}

/// Cmd+K command palette: fuzzy-filter and run a quick action.
struct CommandPaletteView: View {
    let commands: [PaletteCommand]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [PaletteCommand] {
        guard !query.isEmpty else { return commands }
        return commands.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("Buscar acción…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit(runFirst)
            }
            .padding(12)

            Divider()

            if filtered.isEmpty {
                Text("Sin acciones")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { command in
                    Button {
                        command.action()
                        dismiss()
                    } label: {
                        Label(command.title, systemImage: command.icon)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 480, height: 400)
        .background(Color.appCard)
    }

    private func runFirst() {
        if let first = filtered.first {
            first.action()
            dismiss()
        }
    }
}
