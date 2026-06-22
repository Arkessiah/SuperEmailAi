# SuperEmailAi

A native macOS app that helps you clean up and organize your inbox by driving **Apple Mail.app** through AppleScript. It groups your mail by sender, finds duplicates, and lets you delete or move messages in bulk — with a confirmation step before anything is removed.

> SuperEmailAi is a standalone `.app`, **not** a MailKit/Mail extension. It controls Mail.app via Apple Events, which gives it full access to list, search, move and delete messages.

---

## Features

- **Group by sender** — see who fills your inbox, sorted by message count, name or date.
- **Search & sort** senders in the sidebar.
- **Bulk actions** — select multiple messages (⌘/⇧-click) and delete or move them to any mailbox.
- **Duplicate detection** — find messages with the same sender and subject, and delete the extras keeping one copy.
- **Folder picker** — move messages to any Mail.app mailbox.
- **Safe by default** — every destructive action goes through a confirmation dialog showing what will be removed.

---

## Requirements

- **macOS 14 (Sonoma)** or later
- **Mail.app** configured with your accounts and **open** while using the app
- **Swift 5.9+** toolchain to build

---

## Build & run

```bash
swift build
.build/debug/SuperEmailAi
```

On first launch, macOS will ask for permission to **control Mail.app** (Apple Events / Automation). This is required for the app to read and manage your messages. Grant it under *System Settings → Privacy & Security → Automation*.

---

## Architecture

```
Views (SwiftUI, NavigationSplitView)
        │  @EnvironmentObject
        ▼
MailManager (@MainActor ObservableObject)   ← single source of truth
        │  async/await
        ▼
MailBridge (AppleScript ↔ Mail.app)
        ▼
Mail.app
```

- **SwiftUI** UI with `NavigationSplitView` (sidebar + detail).
- **`MailManager`** is a `@MainActor` view model injected as an environment object — views never call the bridge directly.
- **`MailBridge`** runs AppleScript on a background queue and parses results structurally via `NSAppleEventDescriptor`.
- Built with **Swift Package Manager** (`Package.swift`) — no Xcode project required.

---

## Status

Early MVP — functional and compilable. Known limitations and the roadmap (multi-account support, local cache, a rules engine, progressive loading, IMAP-direct mode, unsubscribe detection, statistics) are tracked internally.

Because the app needs Apple Events access to Mail.app, it runs **without the App Sandbox**, so it is distributed directly rather than through the Mac App Store.

---

## Contributing

1. Fork and clone
2. `swift build` to verify the baseline compiles
3. Keep changes focused and open a small PR

UI strings are in **Spanish** (the primary audience); all code, identifiers and comments are in **English**.

---

## Author

Built by Antonio ([Ascendwave](https://github.com/Arkessiah)).
