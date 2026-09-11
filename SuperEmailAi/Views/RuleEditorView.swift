import SwiftUI

/// Editable form of a condition (SwiftUI can't bind to enum payloads directly).
struct ConditionDraft: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case senderContains = "Remitente contiene", senderIs = "Remitente es", domainIs = "Dominio es"
        case subjectContains = "Asunto contiene", olderThanDays = "Más de N días", newerThanDays = "Menos de N días"
        case unread = "Sin leer", read = "Leído", accountIs = "Cuenta es", mailboxIs = "Buzón es"
        case largerThanKB = "Pesa más de (KB)", important = "Remitente en Importantes"
        case newsletters = "Remitente en Boletines"
        var id: String { rawValue }
        var needsText: Bool { [.senderContains, .senderIs, .domainIs, .subjectContains, .accountIs, .mailboxIs].contains(self) }
        var needsNumber: Bool { [.olderThanDays, .newerThanDays, .largerThanKB].contains(self) }
    }

    let id = UUID()
    var kind: Kind
    var text: String
    var number: Int

    init(kind: Kind = .senderContains, text: String = "", number: Int = 30) {
        self.kind = kind
        self.text = text
        self.number = number
    }

    init(_ c: RuleCondition) {
        switch c {
        case .senderContains(let s): self.init(kind: .senderContains, text: s)
        case .senderIs(let s): self.init(kind: .senderIs, text: s)
        case .domainIs(let s): self.init(kind: .domainIs, text: s)
        case .subjectContains(let s): self.init(kind: .subjectContains, text: s)
        case .olderThanDays(let n): self.init(kind: .olderThanDays, number: n)
        case .newerThanDays(let n): self.init(kind: .newerThanDays, number: n)
        case .isRead(let r): self.init(kind: r ? .read : .unread)
        case .accountIs(let s): self.init(kind: .accountIs, text: s)
        case .mailboxIs(let s): self.init(kind: .mailboxIs, text: s)
        case .largerThanKB(let n): self.init(kind: .largerThanKB, number: n)
        case .senderInImportant: self.init(kind: .important)
        case .senderInNewsletters: self.init(kind: .newsletters)
        }
    }

    var condition: RuleCondition {
        switch kind {
        case .senderContains: .senderContains(text)
        case .senderIs: .senderIs(text)
        case .domainIs: .domainIs(text)
        case .subjectContains: .subjectContains(text)
        case .olderThanDays: .olderThanDays(number)
        case .newerThanDays: .newerThanDays(number)
        case .unread: .isRead(false)
        case .read: .isRead(true)
        case .accountIs: .accountIs(text)
        case .mailboxIs: .mailboxIs(text)
        case .largerThanKB: .largerThanKB(number)
        case .important: .senderInImportant
        case .newsletters: .senderInNewsletters
        }
    }
}

struct RuleEditorView: View {
    @EnvironmentObject var rules: RuleRunner
    @EnvironmentObject var manager: MailManager
    @Environment(\.dismiss) private var dismiss

    enum ActionKind: String, CaseIterable, Identifiable {
        case move = "Mover a…", archive = "Archivar", delete = "Borrar", markRead = "Marcar leído", flag = "Poner bandera"
        var id: String { rawValue }
    }

    @State private var draft: Rule
    @State private var conditions: [ConditionDraft]
    @State private var actionKind: ActionKind
    @State private var moveAccount: String
    @State private var moveMailbox: String
    @State private var newAlways = ""
    @State private var newNever = ""
    @State private var preview: (count: Int, sample: [MailMessage])?
    @State private var isPreviewing = false

    init(rule: Rule) {
        _draft = State(initialValue: rule)
        _conditions = State(initialValue: rule.conditions.map(ConditionDraft.init))
        var kind = ActionKind.markRead, account = "", mailbox = ""
        switch rule.action {
        case .move(let a, let b): kind = .move; account = a; mailbox = b
        case .archive: kind = .archive
        case .delete: kind = .delete
        case .markRead: kind = .markRead
        case .flag: kind = .flag
        }
        _actionKind = State(initialValue: kind)
        _moveAccount = State(initialValue: account)
        _moveMailbox = State(initialValue: mailbox)
    }

    /// The rule as currently edited.
    private var current: Rule {
        var r = draft
        r.conditions = conditions.map(\.condition)
        r.action = switch actionKind {
        case .move: .move(account: moveAccount, mailbox: moveMailbox)
        case .archive: .archive
        case .delete: .delete
        case .markRead: .markRead
        case .flag: .flag
        }
        return r
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && (!conditions.isEmpty || !draft.alwaysSenders.isEmpty)
            && (actionKind != .move || (!moveAccount.isEmpty && !moveMailbox.isEmpty))
    }

    private var mailboxes: [String] { manager.accounts.first { $0.name == moveAccount }?.mailboxes ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.name.isEmpty ? "Nueva regla" : draft.name).font(.title2.bold())
            Form {
                TextField("Nombre", text: $draft.name)
                Toggle("Activa", isOn: $draft.isEnabled)
                Picker("Cumplir", selection: $draft.matchMode) {
                    Text("todas las condiciones").tag(Rule.MatchMode.all)
                    Text("alguna condición").tag(Rule.MatchMode.any)
                }
                Section("Condiciones") {
                    ForEach($conditions) { $c in
                        HStack {
                            Picker("", selection: $c.kind) {
                                ForEach(ConditionDraft.Kind.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 210)
                            if c.kind.needsText { TextField("valor", text: $c.text) }
                            if c.kind.needsNumber { TextField("N", value: $c.number, format: .number).frame(width: 70) }
                            Button { conditions.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Añadir condición") { conditions.append(ConditionDraft()) }
                }
                Section("Acción") {
                    Picker("Acción", selection: $actionKind) {
                        ForEach(ActionKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if actionKind == .move {
                        Picker("Cuenta", selection: $moveAccount) {
                            ForEach(manager.accounts) { Text($0.name).tag($0.name) }
                        }
                        Picker("Buzón", selection: $moveMailbox) {
                            ForEach(mailboxes, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                senderList("Siempre", entries: $draft.alwaysSenders, newValue: $newAlways)
                senderList("Nunca", entries: $draft.neverSenders, newValue: $newNever)
            }
            .formStyle(.grouped)

            previewBox

            HStack {
                Button("Cancelar") { dismiss() }
                Spacer()
                Button("Guardar") {
                    rules.save(current)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 620, height: 700)
        .task(id: previewKey) { await refreshPreview() }
    }

    private func senderList(_ title: String, entries: Binding<[SenderEntry]>, newValue: Binding<String>) -> some View {
        Section(title) {
            ForEach(entries.wrappedValue, id: \.self) { entry in
                HStack {
                    Text(entry.address)
                    Text(origin(entry.origin)).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button { entries.wrappedValue.removeAll { $0 == entry } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("dirección@ejemplo.com", text: newValue)
                Button("Añadir") {
                    let address = newValue.wrappedValue.trimmingCharacters(in: .whitespaces)
                    guard address.contains("@") else { return }
                    entries.wrappedValue.append(SenderEntry(address: address, origin: .manual))
                    newValue.wrappedValue = ""
                }
            }
        }
    }

    private func origin(_ o: SenderEntry.Origin) -> String {
        switch o {
        case .manual: "a mano"
        case .correction: "al deshacer"
        case .ai: "propuesto por IA"
        }
    }

    private var previewBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Probar").font(.headline)
                if isPreviewing {
                    ProgressView().controlSize(.small)
                } else if let preview {
                    Text(preview.count == 0 ? "Ningún correo coincide" : "\(preview.count) correos coinciden en el índice")
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(preview?.sample ?? []) { m in
                        Text("\(m.senderAddress) — \(m.subject)").font(.caption).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 90)
        }
        .padding(10)
        .background(Color.appControl, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Changes whenever the edited rule changes (restarts the debounced preview).
    private var previewKey: String {
        (try? JSONEncoder().encode(current)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private func refreshPreview() async {
        try? await Task.sleep(nanoseconds: 400_000_000)   // debounce, like "Llévame a cero"
        if Task.isCancelled { return }
        isPreviewing = true
        preview = await rules.preview(current)
        isPreviewing = false
    }
}
