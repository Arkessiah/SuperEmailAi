import SwiftUI

/// In-app alerts popover: new mail from important senders, detected by the
/// background monitor.
struct AlertsView: View {
    @EnvironmentObject var manager: MailManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Alertas").font(.headline)
                Spacer()
                if !manager.alerts.isEmpty {
                    Button("Limpiar") { manager.clearAlerts() }
                        .font(.caption)
                }
            }
            .padding(10)

            Divider()

            if manager.alerts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Sin alertas")
                        .foregroundStyle(.secondary)
                    Text("Avisaré aquí cuando llegue correo de un remitente importante (⭐).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(manager.alerts) { msg in
                            Button {
                                Task { await manager.openForReading(msg) }
                                manager.dismissAlert(msg.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.yellow)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(msg.sender)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                        Text(msg.subject)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 320, height: 360)
    }
}
