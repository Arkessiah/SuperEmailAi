import SwiftUI

/// "Inicio" dashboard: a Quick-Start section showcasing upcoming features as
/// cards (FlowAI-style). The features themselves are not built yet.
struct HomeView: View {
    @EnvironmentObject var manager: MailManager

    private struct Feature: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let description: String
    }

    private let features: [Feature] = [
        Feature(
            icon: "arrowshape.turn.up.left.fill",
            title: "Auto-respuesta",
            description: "Responde automáticamente cuando estás de vacaciones, en buzones concretos o a ciertas peticiones. Sencillo ahora; en el futuro, automatiza procesos con tu correo."
        ),
        Feature(
            icon: "chart.line.uptrend.xyaxis",
            title: "Scoring de remitentes",
            description: "Puntúa a tus remitentes para que sus correos se posicionen mejor. Permite una vista y orden por importancia, no solo por fecha."
        ),
        Feature(
            icon: "bell.badge.fill",
            title: "Alertas",
            description: "Recibe un aviso al instante cuando llegue un correo de alguien que te importa."
        )
    ]

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
                            FeatureCard(icon: feature.icon, title: feature.title, description: feature.description)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.appBackground)
    }
}

private struct FeatureCard: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(Color.appControl, in: RoundedRectangle(cornerRadius: 9))
                Spacer()
                Text("Próximamente")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.appControl, in: Capsule())
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .font(.headline)

            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .cardStyle()
    }
}
