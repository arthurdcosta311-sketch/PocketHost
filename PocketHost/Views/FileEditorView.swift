//
//  FileEditorView.swift
//  PocketHost
//

import SwiftUI

struct FileEditorView: View {
    let entry: FileStore.Entry

    @EnvironmentObject private var store: HostingStore
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var savedText = ""
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    private var isDirty: Bool { text != savedText }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(.secondarySystemGroupedBackground))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .navigationTitle(entry.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save(preview: false) }
                            .disabled(!isDirty)
                            .fontWeight(.semibold)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 12) {
                        Button { save(preview: true) } label: {
                            Label("Save & preview", systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Text("\(text.count) chars")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
        }
        .onAppear(perform: load)
        .alert("Could not save", isPresented: errorBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true

        if let contents = store.files.readText(at: entry.url) {
            text = contents
            savedText = contents
        } else {
            errorMessage = "This file could not be opened as text."
        }
    }

    private func save(preview: Bool) {
        do {
            try store.files.write(text: text, to: entry.url)
            savedText = text
            store.refreshStats()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        guard preview else { return }

        guard store.isRunning else {
            errorMessage = "Start the server on the Server tab to preview this page."
            return
        }

        let path = store.files.webPath(for: entry.url)
        if let url = URL(string: "http://localhost:\(store.port)" + path) {
            router.openInBrowser(url)
            dismiss()
        }
    }
}

#Preview {
    FileEditorView(entry: FileStore.Entry(
        url: URL(fileURLWithPath: "/tmp/index.html"),
        name: "index.html",
        isDirectory: false,
        size: 1200,
        modified: Date()
    ))
    .environmentObject(HostingStore())
    .environmentObject(AppRouter())
}
