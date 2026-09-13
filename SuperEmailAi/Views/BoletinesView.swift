import SwiftUI

/// "Boletines" (ARK-203): senders by volume and read rate, the suggested ones to
/// unsubscribe from, and a bulk "unsubscribe + clean their inbox" with confirmation.
struct BoletinesView: View {
    @EnvironmentObject var manager: MailManager
    @Environment(\.dismiss) private var dismiss

    @State private var stats: [SenderStat] = []
    @State private var cache: [String: SenderUnsubscribe] = [:]
    @State private var criteria = SuggestionCriteria()
    @State private var onlySuggested = true
    @State private var selection: Set<String> = []
    @State private var cleanup: CleanupMode = .none
    @State private var confirming = false
    @State private var isRunning = false
    @State private var result: BulkResult?

    private var shown: [SenderStat] {
        stats.filter { $0.total >= criteria.minMessages && (!onlySuggested || criteria.suggests($0)) }
    }

    private var inboxToClean: Int {
        stats.filter { selection.contains($0.address) }.reduce(0) { $0 + $1.inInbox }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Boletines").font(.title2.bold())
                Text("Remitentes por volumen y por lo poco que los lees. Elige varios y date de baja de todos a la vez.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Toggle("Solo sugeridos", isOn: $onlySuggested)
                Stepper("Mín. \(criteria.minMessages) correos", value: $criteria.minMessages, in: 1...200)
                Stepper("Máx. \(criteria.maxReadPercent) % leídos", value: $criteria.maxReadPercent, in: 0...100, step: 5)
                Spacer()
                Button("Seleccionar todos") { selection = Set(shown.map(\.address)) }
                    .disabled(shown.isEmpty)
            }
            .font(.callout)

            List(shown) { stat in
                row(stat)
            }
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView(
                        onlySuggested ? "Nada que sugerir" : "Sin remitentes",
                        systemImage: "tray",
                        description: Text(onlySuggested ? "Ningún remitente cumple el criterio: prueba a ajustarlo."
                                                        : "El índice todavía no tiene correo suficiente.")
                    )
                }
            }

            if let result { resultBox(result) }

            HStack {
                Picker("", selection: $cleanup) {
                    ForEach(CleanupMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 210)
                Spacer()
                Button("Cerrar") { dismiss() }
                Button {
                    confirming = true
                } label: {
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Darse de baja (\(selection.count))")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || isRunning)
            }
        }
        .padding(20)
        .frame(width: 740, height: 600)
        .task { reload() }
        .confirmationDialog("¿Darse de baja de \(selection.count) remitentes?", isPresented: $confirming) {
            Button(cleanup == .delete ? "Darse de baja y borrar" : "Darse de baja",
                   role: cleanup == .delete ? .destructive : nil) {
                Task { await run() }
            }
        } message: {
            Text(confirmationText)
        }
    }

    private var confirmationText: String {
        var text = "Se hará en un clic donde el boletín lo admita; el resto te quedará a mano (un enlace o un correo)."
        switch cleanup {
        case .none: break
        case .archive: text += " Además se archivarán \(inboxToClean) correos de su bandeja de entrada."
        case .delete: text += " Además se moverán a la Papelera \(inboxToClean) correos de su bandeja de entrada."
        }
        if cleanup != .none { text += " Lo que tengas en otras carpetas no se toca." }
        return text
    }

    private func row(_ stat: SenderStat) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selection.contains(stat.address) },
                set: { on in
                    if on { selection.insert(stat.address) } else { selection.remove(stat.address) }
                }
            ))
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.name.isEmpty ? stat.address : stat.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(stat.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text("\(stat.total) correos · \(stat.inInbox) en bandeja · \(Int((stat.readRatio * 100).rounded())) % leídos")
                .font(.caption)
                .foregroundStyle(.secondary)
            badge(for: stat.address)
        }
    }

    @ViewBuilder
    private func badge(for sender: String) -> some View {
        if let entry = cache[sender] {
            if let date = entry.unsubscribedAt {
                Label("Baja \(date.formatted(date: .abbreviated, time: .omitted))", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else if entry.oneClick {
                tag("Un clic", .green)
            } else if entry.link != nil {
                tag("Enlace", .blue)
            } else if entry.mailto != nil {
                tag("Correo", .blue)
            } else {
                tag("Sin baja", .secondary)
            }
        } else {
            tag("Sin datos", .secondary)
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

    private func resultBox(_ r: BulkResult) -> some View {
        let sorted = r.outcomes.sorted { $0.key < $1.key }
        let done = sorted.filter { $0.value == .unsubscribed }.count
        let none = sorted.filter { $0.value == .noOption }.count
        let pending = sorted.filter { entry in
            switch entry.value {
            case .manualLink, .manualMail: true
            default: false
            }
        }
        let failed = sorted.compactMap { entry -> (sender: String, why: String)? in
            if case .failed(let why) = entry.value { return (entry.key, why) }
            return nil
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(done) dados de baja · \(pending.count) a mano · \(none) sin forma de baja · \(failed.count) fallos"
                     + (r.cleaned > 0 ? " · \(r.cleaned) correos limpiados" : ""))
                    .font(.callout.weight(.medium))
                ForEach(pending, id: \.key) { entry in
                    HStack {
                        Text(entry.key).font(.caption)
                        Spacer()
                        switch entry.value {
                        case .manualLink(let url):
                            Button("Abrir enlace") { NSWorkspace.shared.open(url) }.controlSize(.small)
                        case .manualMail(let mailto):
                            Button("Escribir correo") {
                                if let url = URL(string: "mailto:" + mailto) { NSWorkspace.shared.open(url) }
                            }
                            .controlSize(.small)
                        default:
                            EmptyView()
                        }
                    }
                }
                ForEach(failed, id: \.sender) { item in
                    Text("\(item.sender): \(item.why)").font(.caption).foregroundStyle(.red)
                }
                ForEach(r.cleanupFailures, id: \.self) { failure in
                    Text(failure).font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
        .padding(10)
        .background(Color.appControl, in: RoundedRectangle(cornerRadius: 8))
    }

    private func run() async {
        isRunning = true
        result = await manager.bulkUnsubscribe.run(senders: Array(selection), cleanup: cleanup)
        selection.removeAll()
        isRunning = false
        reload()
    }

    private func reload() {
        let data = manager.bulkUnsubscribe.senders()
        stats = data.stats
        cache = data.cache
    }
}
