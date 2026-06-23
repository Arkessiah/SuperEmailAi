import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: MailManager
    @State private var showDuplicates = false
    @State private var showMoveSheet = false
    @State private var moveTarget: MoveTarget?
    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.system.rawValue

    private var appearance: AppAppearance { AppAppearance(rawValue: appearanceRaw) ?? .system }

    enum MoveTarget {
        case selected
        case sender(SenderGroup)
    }

    var body: some View {
        NavigationSplitView {
            Group {
                switch manager.mode {
                case .lectura:
                    MailboxSidebarView()
                case .limpieza:
                    SidebarView(showDuplicates: $showDuplicates)
                }
            }
        } detail: {
            if manager.mode == .limpieza && showDuplicates {
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
        .overlay(alignment: .bottom) {
            StatusBar()
        }
        .task {
            manager.showCachedInstantly()
            await manager.loadAccounts()
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
