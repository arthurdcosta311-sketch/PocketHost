//
//  PackageSearchView.swift
//  PocketHost
//
//  Searches the npm registry from the phone and adds a package to the hosted
//  project's package.json, then installs it.
//

import SwiftUI

struct PackageSearchView: View {
    @EnvironmentObject private var store: HostingStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        TextField("Search npm", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .onSubmit(search)

                        Button(action: search) {
                            Image(systemName: "magnifyingglass")
                        }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || store.nodeRuntime.isSearching)
                    }
                } footer: {
                    Text("Search the public npm registry, then tap a result to add it to package.json and install it on this phone.")
                }

                if store.nodeRuntime.isSearching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = store.nodeRuntime.searchError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                if !store.nodeRuntime.searchResults.isEmpty {
                    Section {
                        ForEach(store.nodeRuntime.searchResults) { result in
                            Button {
                                store.nodeRuntime.addPackage(result.name, projectRoot: store.files.root)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(result.name)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)

                                        Spacer(minLength: 6)

                                        Text(result.version)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }

                                    if !result.summary.isEmpty {
                                        Text(result.summary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        Text("Adding a package writes it into package.json and reinstalls the project's dependencies.")
                    }
                }
            }
            .navigationTitle("Add a package")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                store.nodeRuntime.clearSearch()
                focused = true
            }
        }
    }

    private func search() {
        focused = false
        store.nodeRuntime.searchPackages(query, projectRoot: store.files.root)
    }
}

#Preview {
    PackageSearchView()
        .environmentObject(HostingStore())
}
