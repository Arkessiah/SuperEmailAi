import SwiftUI

/// Ask AI (v1, rule-based): type a natural-language cleanup instruction; it's
/// parsed into a filter, previewed with a live count, then executed via the
/// bulk engine. 100% local, no model.
struct AskAIView: View {
    @EnvironmentObject var manager: MailManager
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var intent: MailManager.AIIntent?
    @State private var count: Int?
    @State private var isCounting = false
    @State private var isWorking = false

    private let examples = [
        "Borra todo de @nike.com de más de 6 meses",
        "Elimina los no leídos de más de 1 año",
        "Borra los correos de game-mail.net",
        "Limpia lo leído de más de 90 días"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Ask AI", systemImage: "sparkles").font(.title2.bold())
                Text("Escribe qué limpiar en \(scope). Lo movido va a la Papelera.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "text.bubble").foregroundStyle(.secondary)
                TextField("p. ej. borra boletines de más de 6 meses no leídos…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit(interpret)
            }
            .padding(10)
            .background(Color.appControl, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text("Ejemplos").font(.caption).foregroundStyle(.secondary)
                ForEach(examples, id: \.self) { example in
                    Button(example) { text = example; interpret() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }

            Divider()

            Group {
                if let intent {
                    if isCounting {
                        HStack { ProgressView().controlSize(.small); Text("Calculando…").foregroundStyle(.secondary) }
                    } else if intent.isEmpty {
                        Label("No entendí ningún filtro. Prueba con remitente, antigüedad o leído/no leído.",
                              systemImage: "questionmark.circle")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                    } else if let count {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Entendido: \(intent.summary)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Label(
                                count == 0 ? "Nada que mover" : "Se moverán \(count) correos a la Papelera",
                                systemImage: count == 0 ? "checkmark.circle" : "trash"
                            )
                            .font(.headline)
                            .foregroundStyle(count == 0 ? .green : .red)
                        }
                    }
                } else {
                    Text("Escribe una instrucción y pulsa Interpretar.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 40, alignment: .leading)

            HStack {
                Button("Cancelar") { dismiss() }
                Spacer()
                Button("Interpretar", action: interpret)
                Button(role: .destructive) {
                    guard let intent else { return }
                    isWorking = true
                    Task { await manager.aiExecute(intent); dismiss() }
                } label: {
                    if isWorking { ProgressView().controlSize(.small) } else { Text("Ejecutar") }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled((count ?? 0) == 0 || isWorking)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var scope: String {
        if let account = manager.currentAccount {
            return "\(account) · \(manager.currentMailbox)"
        }
        return "todas las cuentas · \(manager.currentMailbox)"
    }

    private func interpret() {
        let parsed = manager.parseAICommand(text)
        intent = parsed
        count = nil
        guard !parsed.isEmpty else { return }
        Task {
            isCounting = true
            count = await manager.aiCount(parsed)
            isCounting = false
        }
    }
}
