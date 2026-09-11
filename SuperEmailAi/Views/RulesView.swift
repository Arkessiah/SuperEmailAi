import SwiftUI

extension RuleAction {
    /// UI label (Spanish).
    var label: String {
        switch self {
        case .move(_, let box): "Mover a \(box)"
        case .archive: "Archivar"
        case .delete: "Borrar"
        case .markRead: "Marcar leído"
        case .flag: "Poner bandera"
        }
    }

    static func label(forKind kind: String) -> String {
        switch kind {
        case "move": "Mover"
        case "archive": "Archivar"
        case "delete": "Borrar"
        case "markRead": "Marcar leído"
        case "flag": "Poner bandera"
        default: kind
        }
    }
}

/// "Reglas" sheet (ARK-202): ordered list + history.
struct RulesView: View {
    @EnvironmentObject var rules: RuleRunner
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var editing: Rule?
    /// Pre-filled rule ("Crear regla desde este remitente…").
    var prefill: Rule?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Reglas").font(.title2.bold())
                Spacer()
                Picker("", selection: $tab) {
                    Text("Reglas").tag(0)
                    Text("Historial").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            if let error = rules.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if tab == 0 { ruleList } else { RuleHistoryList() }
            HStack {
                if tab == 0 {
                    Button("Nueva regla") { editing = Rule(name: "", action: .markRead) }
                }
                Spacer()
                Button("Cerrar") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .sheet(item: $editing) { rule in RuleEditorView(rule: rule) }
        .onAppear {
            rules.loadHistory()
            if let prefill { editing = prefill }
        }
    }

    private var ruleList: some View {
        List {
            ForEach(rules.rules) { rule in
                RuleRow(rule: rule) { editing = rule }
            }
            .onMove { rules.reorder(from: $0, to: $1) }
        }
        .overlay {
            if rules.rules.isEmpty {
                ContentUnavailableView("Sin reglas", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Crea una regla para que el correo nuevo se ordene solo."))
            }
        }
    }
}

private struct RuleRow: View {
    @EnvironmentObject var rules: RuleRunner
    let rule: Rule
    let onEdit: () -> Void
    @State private var pendingCount: Int?
    @State private var confirmApply = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { rules.setEnabled(rule.id, $0) }))
                .labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name.isEmpty ? "Sin nombre" : rule.name).font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let paused = rule.pausedReason {
                    HStack {
                        Label(paused, systemImage: "pause.circle.fill").font(.caption).foregroundStyle(.orange)
                        Button("Continuar") { rules.resume(rule.id) }.controlSize(.small)
                    }
                }
            }
            Spacer()
            Menu {
                Button("Editar…", action: onEdit)
                Button("Aplicar a lo que ya hay…") {
                    Task {
                        pendingCount = await rules.preview(rule).count
                        confirmApply = true
                    }
                }
                Divider()
                Button("Eliminar", role: .destructive) { rules.delete(rule.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .confirmationDialog("¿Aplicar «\(rule.name)» a \(pendingCount ?? 0) correos que ya tienes?",
                            isPresented: $confirmApply) {
            Button("Aplicar a \(pendingCount ?? 0)", role: .destructive) {
                Task { _ = await rules.applyToExisting(rule) }
            }
            .disabled((pendingCount ?? 0) == 0)
        }
    }

    private var summary: String {
        let joiner = rule.matchMode == .all ? " y " : " o "
        return "\(rule.action.label) · " + rule.conditions.map(RuleEngine.describe).joined(separator: joiner)
    }
}

private struct RuleHistoryList: View {
    @EnvironmentObject var rules: RuleRunner
    @State private var filter: String?
    @State private var batchToUndo: String?

    var body: some View {
        VStack(alignment: .leading) {
            Picker("Regla", selection: $filter) {
                Text("Todas").tag(String?.none)
                ForEach(rules.rules) { Text($0.name).tag(String?.some($0.id)) }
            }
            .onChange(of: filter) { _, id in rules.loadHistory(ruleId: id) }

            List(rules.history) { run in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(run.ruleName) · \(RuleAction.label(forKind: run.action))")
                            .font(.subheadline.weight(.medium))
                        Text("\(run.sender) — \(run.subject)").font(.caption).lineLimit(1)
                        Text("Motivo: \(run.reason)").font(.caption2).foregroundStyle(.secondary)
                        if let error = run.error {
                            Text(error).font(.caption2).foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(run.executedAt, format: .dateTime.day().month().hour().minute())
                            .font(.caption2).foregroundStyle(.secondary)
                        status(run)
                    }
                }
            }
        }
        .confirmationDialog("¿Deshacer toda esta ejecución?",
                            isPresented: Binding(get: { batchToUndo != nil }, set: { if !$0 { batchToUndo = nil } })) {
            Button("Deshacer ejecución") {
                if let batch = batchToUndo {
                    Task { await rules.undo(runIds: rules.runIds(ofBatch: batch)) }
                }
            }
        } message: {
            Text("No se aprende nada de los remitentes: si la regla estaba mal planteada, edítala.")
        }
    }

    @ViewBuilder
    private func status(_ run: RuleRun) -> some View {
        switch run.status {
        case .ok:
            Menu("Deshacer") {
                Button("Solo este correo (y excluir al remitente)") {
                    if let id = run.id { Task { await rules.undo(runIds: [id]) } }
                }
                Button("Toda la ejecución…") { batchToUndo = run.batchId }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
        case .failed: Text("Falló").font(.caption2).foregroundStyle(.red)
        case .undone: Text("Deshecho").font(.caption2).foregroundStyle(.secondary)
        case .undoFailed: Text("No se pudo deshacer").font(.caption2).foregroundStyle(.red)
        }
    }
}
