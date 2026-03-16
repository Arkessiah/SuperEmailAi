import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: MailManager
    @State private var showDuplicates = false
    @State private var showMoveSheet = false
    @State private var moveTarget: MoveTarget?

    enum MoveTarget {
        case selected
        case sender(SenderGroup)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(showDuplicates: $showDuplicates)
        } detail: {
            if showDuplicates {
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
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 12) {
                    // Mailbox picker
                    Picker("Buzon", selection: $manager.currentMailbox) {
                        Text("INBOX").tag("INBOX")
                        ForEach(manager.mailboxes.filter { $0 != "INBOX" }, id: \.self) { mb in
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
            await manager.loadMailboxes()
        }
        .onChange(of: manager.currentMailbox) {
            Task { await manager.loadMessages() }
        }
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
