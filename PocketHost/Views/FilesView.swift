//
//  FilesView.swift
//  PocketHost
//
//  Browsing, importing and editing the files the server hands out.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FilesView: View {
    @EnvironmentObject private var store: HostingStore

    var body: some View {
        NavigationStack {
            DirectoryListView(directory: store.files.root, isRoot: true)
                .navigationDestination(for: URL.self) { url in
                    DirectoryListView(directory: url, isRoot: false)
                }
        }
    }
}

struct DirectoryListView: View {
    let directory: URL
    var isRoot: Bool = false

    @EnvironmentObject private var store: HostingStore
    @EnvironmentObject private var router: AppRouter

    @State private var entries: [FileStore.Entry] = []
    @State private var showingImporter = false
    @State private var prompt: NamePrompt?
    @State private var promptText = ""
    @State private var editTarget: FileStore.Entry?
    @State private var pendingDelete: FileStore.Entry?
    @State private var banner: String?

    enum NamePrompt: Identifiable {
        case newFile
        case newFolder
        case rename(FileStore.Entry)

        var id: String {
            switch self {
            case .newFile: return "newFile"
            case .newFolder: return "newFolder"
            case .rename(let entry): return "rename-\(entry.id)"
            }
        }

        var title: String {
            switch self {
            case .newFile: return "New HTML file"
            case .newFolder: return "New folder"
            case .rename: return "Rename"
            }
        }

        var message: String {
            switch self {
            case .newFile: return "A starter page is created in this folder."
            case .newFolder: return "Folders become part of the URL path."
            case .rename: return "Give the item a new name."
            }
        }
    }

    var body: some View {
        List {
            if entries.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Nothing here yet", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Import a site folder, or create an HTML file to start hosting.")
                    } actions: {
                        Button("Import from Files") { showingImporter = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(entries) { entry in
                        row(for: entry)
                    }
                } header: {
                    Text(relativeLabel)
                        .font(.caption.monospaced())
                }
            }

            Section {
                Text("Everything in this folder is served over HTTP at \(store.localURLString). Folders become part of the path, and index.html is used as the entry point.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(isRoot ? "Files" : directory.lastPathComponent)
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { startPrompt(.newFile) } label: {
                        Label("New HTML file", systemImage: "doc.badge.plus")
                    }
                    Button { startPrompt(.newFolder) } label: {
                        Label("New folder", systemImage: "folder.badge.plus")
                    }
                    Button { showingImporter = true } label: {
                        Label("Import from Files", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .accessibilityLabel("Add files")
            }
        }
        .onAppear(perform: reload)
        .onChange(of: store.files.version) { _, _ in reload() }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .alert(prompt?.title ?? "", isPresented: promptBinding) {
            TextField("Name", text: $promptText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(confirmTitle) { applyPrompt() }
            Button("Cancel", role: .cancel) {
                prompt = nil
                promptText = ""
            }
        } message: {
            Text(prompt?.message ?? "")
        }
        .confirmationDialog(
            "Delete this item?",
            isPresented: deleteBinding,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { entry in
            Button("Delete \(entry.name)", role: .destructive) {
                delete(entry)
            }
            Button("Keep", role: .cancel) { pendingDelete = nil }
        } message: { entry in
            Text(entry.isDirectory
                 ? "The folder and everything inside it are removed from the hosted site."
                 : "The file is removed from the hosted folder.")
        }
        .sheet(item: $editTarget) { entry in
            FileEditorView(entry: entry)
        }
        .overlay(alignment: .bottom) {
            if let banner {
                Text(banner)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(.thinMaterial))
                    .overlay(Capsule().strokeBorder(Color(.separator).opacity(0.4)))
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: banner) {
            guard banner != nil else { return }
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation { banner = nil }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for entry: FileStore.Entry) -> some View {
        if entry.isDirectory {
            NavigationLink(value: entry.url) {
                rowLabel(entry)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                deleteButton(entry)
            }
            .contextMenu { contextMenu(entry) }
        } else {
            Button {
                open(entry)
            } label: {
                rowLabel(entry)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                deleteButton(entry)
            }
            .contextMenu { contextMenu(entry) }
        }
    }

    private func rowLabel(_ entry: FileStore.Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: entry))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor(for: entry))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(iconColor(for: entry).opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(entry.sizeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if entry.isHTML {
                Text("HTML")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            }
        }
        .contentShape(Rectangle())
    }

    private func deleteButton(_ entry: FileStore.Entry) -> some View {
        Button(role: .destructive) {
            pendingDelete = entry
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func contextMenu(_ entry: FileStore.Entry) -> some View {
        Button { openInBrowser(entry) } label: {
            Label("Open in browser", systemImage: "safari")
        }
        Button { copyLink(entry) } label: {
            Label("Copy link", systemImage: "link")
        }
        Button { startPrompt(.rename(entry)) } label: {
            Label("Rename", systemImage: "pencil")
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = entry
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Bindings

    private var promptBinding: Binding<Bool> {
        Binding(
            get: { prompt != nil },
            set: { if !$0 { prompt = nil } }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var relativeLabel: String {
        let path = store.files.webPath(for: directory)
        return path == "/" ? "/" : path
    }

    private var confirmTitle: String {
        if case .rename = prompt { return "Rename" }
        return "Create"
    }

    // MARK: - Actions

    private func reload() {
        entries = store.files.contents(of: directory)
    }

    private func startPrompt(_ kind: NamePrompt) {
        promptText = ""
        switch kind {
        case .newFile: promptText = "page.html"
        case .newFolder: promptText = "site"
        case .rename(let entry): promptText = entry.name
        }
        prompt = kind
    }

    private func applyPrompt() {
        guard let prompt else { return }
        let name = promptText

        do {
            switch prompt {
            case .newFile:
                let url = try store.files.createFile(named: name, in: directory)
                if let entry = store.files.entry(for: url) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        editTarget = entry
                    }
                }
            case .newFolder:
                try store.files.createFolder(named: name, in: directory)
            case .rename(let entry):
                try store.files.rename(entry, to: name)
            }
            store.refreshStats()
        } catch {
            banner = error.localizedDescription
        }

        self.prompt = nil
        promptText = ""
    }

    private func delete(_ entry: FileStore.Entry) {
        do {
            try store.files.delete(entry)
            store.refreshStats()
            banner = "\(entry.name) deleted"
        } catch {
            banner = error.localizedDescription
        }
        pendingDelete = nil
    }

    private func open(_ entry: FileStore.Entry) {
        if entry.isEditable {
            editTarget = entry
        } else {
            openInBrowser(entry)
        }
    }

    private func openInBrowser(_ entry: FileStore.Entry) {
        guard store.isRunning else {
            banner = "Start the server to preview files in the browser."
            return
        }
        let path = store.files.webPath(for: entry.url)
        if let url = URL(string: "http://localhost:\(store.port)" + path) {
            router.openInBrowser(url)
        }
    }

    private func copyLink(_ entry: FileStore.Entry) {
        let path = store.files.webPath(for: entry.url)
        UIPasteboard.general.string = "http://localhost:\(store.port)" + path
        banner = "Link copied"
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            banner = error.localizedDescription

        case .success(let urls):
            var imported = 0
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                do {
                    imported += try store.files.importItem(at: url, into: directory)
                } catch {
                    banner = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
                }
                if scoped { url.stopAccessingSecurityScopedResource() }
            }

            if imported > 0 {
                store.refreshStats()
                reload()
                banner = imported == 1 ? "Imported 1 file" : "Imported \(imported) files"
            }
        }
    }

    // MARK: - Icons

    private func iconName(for entry: FileStore.Entry) -> String {
        if entry.isDirectory { return "folder.fill" }

        switch entry.fileExtension {
        case "html", "htm", "xhtml": return "chevron.left.forwardslash.chevron.right"
        case "css": return "paintbrush.fill"
        case "js", "mjs", "ts", "jsx", "tsx": return "curlybraces"
        case "json", "yml", "yaml", "toml": return "list.bullet.rectangle"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "avif": return "photo.fill"
        case "svg": return "scribble.variable"
        case "mp4", "mov", "m4v", "webm": return "film.fill"
        case "mp3", "wav", "m4a", "ogg": return "waveform"
        case "pdf": return "doc.richtext.fill"
        case "md", "txt": return "text.alignleft"
        default: return "doc.fill"
        }
    }

    private func iconColor(for entry: FileStore.Entry) -> Color {
        if entry.isDirectory { return .blue }

        switch entry.fileExtension {
        case "html", "htm", "xhtml": return .orange
        case "css": return .indigo
        case "js", "mjs", "ts": return .yellow
        case "json", "yml", "yaml", "toml": return .purple
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "avif", "svg": return .pink
        case "mp4", "mov", "m4v", "webm": return .teal
        default: return .gray
        }
    }
}

#Preview {
    FilesView()
        .environmentObject(HostingStore())
        .environmentObject(AppRouter())
}
