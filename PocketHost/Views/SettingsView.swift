//
//  SettingsView.swift
//  PocketHost
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: HostingStore
    @Environment(\.dismiss) private var dismiss

    @State private var portText = ""
    @State private var showingRestore = false
    @State private var restoreNote: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("8080", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .onSubmit { applyPort() }
                    }

                    Toggle("Folder listings", isOn: $store.directoryListing)
                    Toggle("Allow cross-origin requests", isOn: $store.corsEnabled)
                    Toggle("Advertise on Bonjour", isOn: $store.advertiseBonjour)
                    Toggle("Start automatically", isOn: $store.autoStart)
                } header: {
                    Text("Server")
                } footer: {
                    Text("Changing the port restarts a running server. Use a value between 1024 and 65535.")
                }

                Section {
                    LabeledContent("Hosted folder", value: "www")
                    LabeledContent("Files", value: "\(store.fileCount)")
                    Button("Restore sample sites") { showingRestore = true }
                } header: {
                    Text("Content")
                } footer: {
                    Text("Restoring writes index.html, the WebGL demo and the capability lab back into the folder. Your own files are left alone.")
                }

                Section {
                    LabeledContent("Rendering", value: "WKWebView")
                    LabeledContent("JavaScript", value: "JIT compiled")
                    LabeledContent("Graphics", value: "WebGL 2 · GPU")
                    LabeledContent("Delivery", value: "HTTP/1.1 · Bonjour")
                } header: {
                    Text("Engine")
                } footer: {
                    Text("Pages run in WebKit's multi-process engine, with byte-range support for video and audio.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        applyPort()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { portText = String(store.port) }
            .alert("Restore sample sites?", isPresented: $showingRestore) {
                Button("Restore", role: .destructive) {
                    store.files.restoreSamples()
                    store.refreshStats()
                    restoreNote = "Sample sites restored."
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This overwrites index.html, the WebGL demo and the capability lab with fresh copies.")
            }
            .overlay(alignment: .bottom) {
                if let restoreNote {
                    Text(restoreNote)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(.thinMaterial))
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .task(id: restoreNote) {
                guard restoreNote != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                withAnimation { restoreNote = nil }
            }
        }
    }

    private func applyPort() {
        if let value = Int(portText), (1024...65535).contains(value) {
            store.port = value
        } else {
            portText = String(store.port)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(HostingStore())
}
