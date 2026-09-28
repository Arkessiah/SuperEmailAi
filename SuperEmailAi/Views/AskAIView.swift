import SwiftUI

/// Ask AI: type an instruction in plain Spanish and get one of two things out of it — a one-off
/// cleanup right now, parsed locally with no model at all and previewed with a live count, or a
/// **rule** that keeps doing it, built by asking the on-device model one closed question at a time
/// (`RuleInterview`) and handed to the editor for the user to read before it ever runs.
struct AskAIView: View {
    @EnvironmentObject var manager: MailManager
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var intent: MailManager.AIIntent?
    @State private var count: Int?
    @State private var isCounting = false
    @State private var isWorking = false
    @State private var proposed: Rule?
    @State private var isAsking = false
    @State private var aiProblem: String?

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
                Text(MailboxResolver.trash(in: [manager.currentMailbox]) != nil
                     ? "Estás en la Papelera: ahí el borrado es definitivo, así que no se limpia desde aquí. Hazlo desde Mail."
                     : "Escribe qué limpiar en \(scope). Lo movido va a la Papelera.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "text.bubble").foregroundStyle(.secondary)
                TextField("p. ej. borra los de ofertas@tienda.com de más de 6 meses no leídos…", text: $text)
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
                if isAsking {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Preparando la regla…").foregroundStyle(.secondary)
                    }
                } else if let aiProblem {
                    Label(aiProblem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let intent {
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

            if canMakeRules {
                Text("«Crear regla» no limpia nada ahora: propone una regla que lo siga haciendo, "
                     + "limitada a \(scope), y te la abre para que la leas antes de encenderla.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !inTrash {
                Label(manager.aiAvailability.message, systemImage: "sparkles.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancelar") { dismiss() }
                Spacer()
                Button("Interpretar", action: interpret)
                if canMakeRules {
                    Button("Crear regla", action: askForRule)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isAsking)
                }
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
        // The model takes seconds to load and none to stay loaded, so it's paid for now, while the
        // user is still typing.
        .onAppear {
            manager.ai.refreshAvailability()
            if manager.aiAvailability.isReady { manager.ai.prewarm() }
        }
        // Same way a rule proposed from a message opens (MessageListView): the rules sheet with the
        // editor already up, so the user lands where the rule will live.
        .sheet(item: $proposed) { rule in RulesView(prefill: rule) }
    }

    private var inTrash: Bool { MailboxResolver.trash(in: [manager.currentMailbox]) != nil }

    /// No rules from the Trash: one scoped to it would either do nothing or delete for good.
    private var canMakeRules: Bool { !inTrash && manager.aiAvailability.isReady }

    private func askForRule() {
        aiProblem = nil
        isAsking = true
        Task {
            do {
                proposed = try await manager.proposeRule(from: text)
            } catch {
                aiProblem = error.localizedDescription
            }
            isAsking = false
        }
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
        aiProblem = nil
        guard !parsed.isEmpty else { return }
        Task {
            isCounting = true
            count = await manager.aiCount(parsed)
            isCounting = false
        }
    }
}
