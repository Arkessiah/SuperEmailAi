import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: MailManager
    @State private var showDuplicates = false
    @State private var showMoveSheet = false
    @State private var showCleanup = false
    @State private var showCommandPalette = false
    @State private var showAskAI = false
    @State private var showAlerts = false
    @State private var moveTarget: MoveTarget?
    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.dark.rawValue

    private var appearance: AppAppearance { AppAppearance(rawValue: appearanceRaw) ?? .system }

    private var paletteCommands: [PaletteCommand] {
        [
            PaletteCommand(title: "Modo Lectura", icon: "envelope.open") { manager.mode = .lectura },
            PaletteCommand(title: "Modo Limpieza", icon: "sparkles") { manager.mode = .limpieza },
            PaletteCommand(title: "Refrescar correos", icon: "arrow.clockwise") {
                Task { await manager.loadMessages() }
            },
            PaletteCommand(title: "Llévame a cero…", icon: "trash.slash") { showCleanup = true },
            PaletteCommand(title: "Ask AI…", icon: "sparkles") { showAskAI = true },
            PaletteCommand(title: "Ver duplicados", icon: "doc.on.doc") {
                manager.mode = .limpieza
                manager.findDuplicates()
                showDuplicates = true
            },
            PaletteCommand(title: "Marcar leído / no leído", icon: "envelope.badge") {
                Task { await manager.toggleReadForSelection() }
            },
            PaletteCommand(title: "Archivar selección", icon: "archivebox") {
                Task { await manager.archiveSelection() }
            }
        ]
    }

    enum MoveTarget {
        case selected
        case sender(SenderGroup)
    }

    var body: some View {
        NavigationSplitView {
            Group {
                switch manager.mode {
                case .inicio, .lectura:
                    MailboxSidebarView()
                case .limpieza:
                    SidebarView(showDuplicates: $showDuplicates)
                }
            }
        } detail: {
            if manager.mode == .inicio {
                HomeView()
            } else if manager.mode == .limpieza && showDuplicates {
                DuplicatesView()
            } else {
                MessageListView(
                    showMoveSheet: $showMoveSheet,
                    moveTarget: $moveTarget
                )
            }
        }
        .navigationTitle("Super Email Organizer")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Modo", selection: $manager.mode) {
                    ForEach(MailManager.AppMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            ToolbarItem(placement: .automatic) {
                if manager.mode == .limpieza {
                    Button {
                        showCleanup = true
                    } label: {
                        Label("Llévame a cero", systemImage: "trash.slash")
                    }
                    .help("Vaciar el buzón por criterios (con conteo previo)")
                }
            }
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Buscar…", text: $manager.searchText)
                        .textFieldStyle(.plain)
                        .frame(width: 150)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.appControl, in: Capsule())
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showAskAI = true
                } label: {
                    Label("Ask AI", systemImage: "sparkles")
                }
                .help("Limpieza por instrucción en lenguaje natural (local)")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showAlerts.toggle()
                } label: {
                    Image(systemName: manager.alerts.isEmpty ? "bell" : "bell.badge.fill")
                        .symbolRenderingMode(manager.alerts.isEmpty ? .monochrome : .multicolor)
                }
                .help("Alertas de remitentes importantes")
                .popover(isPresented: $showAlerts, arrowEdge: .bottom) {
                    AlertsView()
                }
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker("Apariencia", selection: $appearanceRaw) {
                        ForEach(AppAppearance.allCases) { a in
                            Label(a.label, systemImage: a.icon).tag(a.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: appearance.icon)
                }
                .help("Apariencia: claro / oscuro / sistema")
            }
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 12) {
                    // Account picker
                    Picker("Cuenta", selection: Binding(
                        get: { manager.currentAccount },
                        set: { newValue in Task { await manager.selectAccount(newValue) } }
                    )) {
                        Text("Todas las cuentas").tag(String?.none)
                        ForEach(manager.accounts) { acc in
                            Text(acc.name).tag(String?.some(acc.name))
                        }
                    }
                    .frame(width: 170)

                    // Mailbox picker
                    Picker("Buzon", selection: Binding(
                        get: { manager.currentMailbox },
                        set: { newValue in Task { await manager.selectMailbox(newValue) } }
                    )) {
                        ForEach(manager.mailboxes, id: \.self) { mb in
                            Text(mb).tag(mb)
                        }
                    }
                    .frame(width: 150)

                    Button {
                        Task { await manager.loadMessages() }
                    } label: {
                        Label("Cargar", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)

                    if manager.isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
            }
        }
        .sheet(isPresented: $showMoveSheet) {
            FolderPickerSheet(moveTarget: $moveTarget)
        }
        .sheet(isPresented: $showCleanup) {
            CleanupSheet()
        }
        .sheet(isPresented: $showCommandPalette) {
            CommandPaletteView(commands: paletteCommands)
        }
        .sheet(isPresented: $showAskAI) {
            AskAIView()
        }
        .background(
            Button("") { showCommandPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
        )
        .overlay(alignment: .bottom) {
            StatusBar()
        }
        .task {
            manager.showCachedInstantly()
            await manager.loadAccounts()
            manager.startAlertsMonitor()
            await manager.loadMessages()
            await manager.prefetchAllMailboxes()
        }
        .onChange(of: manager.mode) {
            showDuplicates = false
        }
        .preferredColorScheme(appearance.colorScheme)
    }
}

// MARK: - Status Bar

struct StatusBar: View {
    @EnvironmentObject var manager: MailManager

    var body: some View {
        HStack {
            if let error = manager.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(error)
                    .foregroundStyle(.red)
            } else {
                Image(systemName: "info.circle")
                Text(manager.statusMessage)
            }
            Spacer()
            Text("\(manager.allMessages.count) correos | \(manager.senderGroups.count) remitentes")
                .foregroundStyle(.secondary)
            if !manager.selectedMessages.isEmpty {
                Text("| \(manager.selectedMessages.count) seleccionados")
                    .foregroundStyle(.blue)
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
