import SwiftUI

/// "Inicio" dashboard: a Quick-Start section showcasing features as cards
/// (FlowAI-style). Auto-respuesta is live (opens its config); the others are
/// teasers for now.
struct HomeView: View {
    @EnvironmentObject var manager: MailManager
    @State private var showAutoReply = false

    private struct Feature: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let description: String
        let badge: String
        var action: (() -> Void)?
    }

    private var features: [Feature] {
        [
            Feature(
                icon: "arrowshape.turn.up.left.fill",
                title: "Auto-respuesta",
                description: "Responde automáticamente cuando estás de vacaciones, en buzones concretos o a ciertas peticiones. Sencillo ahora; en el futuro, automatiza procesos con tu correo.",
                badge: manager.autoReplyEnabled ? "Activada" : "Configurar",
                action: { showAutoReply = true }
            ),
            Feature(
                icon: "chart.line.uptrend.xyaxis",
                title: "Scoring de remitentes",
                description: "Puntúa a tus remitentes para que sus correos se posicionen mejor. Marca importantes (⭐) y ordena por importancia, no solo por fecha.",
                badge: "Disponible",
                action: nil
            ),
            Feature(
                icon: "bell.badge.fill",
                title: "Alertas",
                description: "Recibe un aviso al instante (campana 🔔) cuando llegue un correo de alguien importante.",
                badge: "Disponible",
                action: nil
            )
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bienvenido a SuperEmailAi")
                        .font(.largeTitle.bold())
                    Text("Tu correo, más limpio y más inteligente.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Inicio rápido")
                        .font(.headline)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 260), spacing: 16)],
                        alignment: .leading,
                        spacing: 16
                    ) {
                        ForEach(features) { feature in
                            FeatureCard(
                                icon: feature.icon,
                                title: feature.title,
                                description: feature.description,
                                badge: feature.badge,
                                action: feature.action
                            )
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.appBackground)
        .sheet(isPresented: $showAutoReply) {
            AutoReplyView()
        }
    }
}

private struct FeatureCard: View {
    let icon: String
    let title: String
    let description: String
    let badge: String
    var action: (() -> Void)?

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(Color.appControl, in: RoundedRectangle(cornerRadius: 9))
                Spacer()
                Text(badge)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.appControl, in: Capsule())
                    .foregroundStyle(.secondary)
            }

            Text(title).font(.headline)

            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .cardStyle()

        if let action {
            Button(action: action) { card }
                .buttonStyle(.plain)
        } else {
            card
        }
    }
}
