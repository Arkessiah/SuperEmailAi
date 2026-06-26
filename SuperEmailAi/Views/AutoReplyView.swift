import SwiftUI

/// Auto-reply (out-of-office) configuration. Safe by design: master switch off
/// by default, replies once per sender, only to real people.
struct AutoReplyView: View {
    @EnvironmentObject var manager: MailManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Auto-respuesta", systemImage: "arrowshape.turn.up.left.fill")
                .font(.title2.bold())

            Toggle(isOn: $manager.autoReplyEnabled) {
                Text(manager.autoReplyEnabled ? "Activada" : "Desactivada")
                    .font(.headline)
            }
            .toggleStyle(.switch)

            if manager.autoReplyEnabled {
                Label("Está ACTIVA: responderá sola a los correos nuevos que cumplan los criterios.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Mensaje de respuesta").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $manager.autoReplyMessage)
                    .frame(height: 110)
                    .font(.body)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.appBorder))
            }

            Picker("Responder a", selection: $manager.autoReplyScopeRaw) {
                ForEach(MailManager.AutoReplyScope.allCases, id: \.self) { scope in
                    Text(scope.rawValue).tag(scope.rawValue)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 4) {
                Label("Solo a personas reales — nunca a notificaciones, boletines o no-reply.",
                      systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Label("Una sola respuesta por remitente. Ya respondidos: \(manager.autoReplyCount).",
                      systemImage: "person.crop.circle.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Reiniciar respondidos") { manager.resetRepliedSenders() }
                    .font(.caption)
                Spacer()
                Button("Hecho") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
