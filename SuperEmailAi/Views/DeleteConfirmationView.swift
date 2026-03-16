import SwiftUI

struct DeleteConfirmationView: View {
    let messages: [MailMessage]
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var senderBreakdown: [(sender: String, count: Int)] {
        let grouped = Dictionary(grouping: messages, by: \.senderAddress)
        return grouped.map { (sender: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.red)
                VStack(alignment: .leading) {
                    Text("Confirmar eliminacion")
                        .font(.title3.bold())
                    Text("Esta accion no se puede deshacer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            // Summary
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Correos a eliminar:")
                        .font(.headline)
                    Spacer()
                    Text("\(messages.count)")
                        .font(.title2.bold())
                        .foregroundStyle(.red)
                }

                // Estimated space (rough: ~50KB per email average)
                let estimatedKB = messages.count * 50
                HStack {
                    Text("Espacio estimado a liberar:")
                        .font(.subheadline)
                    Spacer()
                    Text(formatSize(estimatedKB))
                        .font(.subheadline.bold())
                        .foregroundStyle(.green)
                }
            }
            .padding()

            Divider()

            // Breakdown by sender
            Text("Desglose por remitente:")
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 8)

            List {
                ForEach(senderBreakdown, id: \.sender) { item in
                    HStack {
                        Text(item.sender)
                            .lineLimit(1)
                        Spacer()
                        Text("\(item.count) correos")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 200)

            Divider()

            // Actions
            HStack {
                Button("Cancelar") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(role: .destructive) {
                    onConfirm()
                    dismiss()
                } label: {
                    Label("Eliminar \(messages.count) correos", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480, height: 450)
    }

    private func formatSize(_ kb: Int) -> String {
        if kb >= 1024 * 1024 {
            return String(format: "%.1f GB", Double(kb) / 1024.0 / 1024.0)
        } else if kb >= 1024 {
            return String(format: "%.1f MB", Double(kb) / 1024.0)
        } else {
            return "\(kb) KB"
        }
    }
}
