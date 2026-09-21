import SwiftUI

/// "Llévame a cero": bulk-clears the current mailbox by criteria, with a live
/// count preview before executing. Deleted messages go to Trash (recoverable).
struct CleanupSheet: View {
    @EnvironmentObject var manager: MailManager
    @Environment(\.dismiss) private var dismiss

    @State private var senderContains = ""
    @State private var ageIndex = 0
    @State private var keepUnread = true
    @State private var keepFlagged = true
    @State private var count: Int?
    @State private var isCounting = false
    @State private var isWorking = false
    @State private var countedKey: String?   // criteria the shown count belongs to

    private let ageOptions: [(label: String, days: Int?)] = [
        ("Cualquier antigüedad", nil),
        ("Más de 30 días", 30),
        ("Más de 90 días", 90),
        ("Más de 6 meses", 180),
        ("Más de 1 año", 365)
    ]

    private var criteria: MailManager.CleanupCriteria {
        MailManager.CleanupCriteria(
            senderContains: senderContains,
            olderThanDays: ageOptions[ageIndex].days,
            keepUnread: keepUnread,
            keepFlagged: keepFlagged
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Llévame a cero")
                    .font(.title2.bold())
                Text(inTrash
                     ? "Borra para siempre los correos de \(scope) según estos criterios: estás en la Papelera."
                     : "Mueve a la Papelera los correos de \(scope) según estos criterios.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Remitente, dominio o marca contiene (opcional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("p. ej. nike.com · newsletter@… · GAME", text: $senderContains)
                    .textFieldStyle(.roundedBorder)
            }

            Picker("Antigüedad", selection: $ageIndex) {
                ForEach(ageOptions.indices, id: \.self) { i in
                    Text(ageOptions[i].label).tag(i)
                }
            }
            Toggle("Conservar los no leídos", isOn: $keepUnread)
            Toggle("Conservar los destacados", isOn: $keepFlagged)

            Divider()

            HStack(spacing: 8) {
                if isCounting {
                    ProgressView().controlSize(.small)
                    Text("Calculando…").foregroundStyle(.secondary)
                } else if let count {
                    Image(systemName: count == 0 ? "checkmark.circle" : "trash")
                        .foregroundStyle(count == 0 ? .green : .red)
                    Text(count == 0
                         ? "Nada que mover con estos criterios"
                         : inTrash ? "Se borrarán para siempre \(count) correos" : "Se moverán \(count) correos a la Papelera")
                        .font(.headline)
                }
                Spacer()
            }

            HStack {
                Button("Cancelar") { dismiss() }
                Spacer()
                Button(role: .destructive) {
                    isWorking = true
                    Task { await manager.performCleanup(criteria); dismiss() }
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Vaciar")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                // Only with a count for exactly these criteria: never act on a stale number.
                .disabled((count ?? 0) == 0 || countedKey != refreshKey || isWorking || isCounting)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task(id: refreshKey) { await recount() }
        .onChange(of: refreshKey) { count = nil; countedKey = nil }
    }

    private var inTrash: Bool { MailboxResolver.trash(in: [manager.currentMailbox]) != nil }

    private var scope: String {
        if let account = manager.currentAccount {
            return "\(account) · \(manager.currentMailbox)"
        }
        return "todas las cuentas · \(manager.currentMailbox)"
    }

    private var refreshKey: String { "\(senderContains)-\(ageIndex)-\(keepUnread)-\(keepFlagged)" }

    private func recount() async {
        let key = refreshKey
        // Debounce: a new keystroke cancels this task before the count runs.
        try? await Task.sleep(nanoseconds: 400_000_000)
        if Task.isCancelled { return }
        isCounting = true
        let counted = await manager.cleanupCount(criteria)
        isCounting = false
        guard !Task.isCancelled, key == refreshKey else { return }   // criteria changed meanwhile
        count = counted
        countedKey = key
    }
}
