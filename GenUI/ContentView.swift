// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import SwiftUI

/// The root content view with a navigation-based layout.
/// Provides navigation to the AI chat planner and widget catalog.
struct ContentView: View {
    @AppStorage("geminiAPIKey") private var geminiAPIKey = ""
    @AppStorage("useStreaming") private var useStreaming = false
    @State private var travelViewId = UUID()
    @State private var showSettings = false
    @State private var showCatalog = false

    /// Whether no API key has been provided.
    private var needsAPIKey: Bool {
        geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if needsAPIKey {
                    apiKeyPromptView
                } else {
                    TravelPlannerView(
                        geminiAPIKey: geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                        useStreaming: useStreaming
                    )
                    .id(travelViewId)
                }
            }
            .navigationTitle("Agentic Travel Inc.")
            #if !os(tvOS) && !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem() {
                    Button {
                        showCatalog = true
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                }
            }
            .navigationDestination(isPresented: $showCatalog) {
                CatalogView()
                    .navigationTitle("Widget Catalog")
                    #if !os(tvOS) && !os(macOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SettingsView(
                        geminiAPIKey: $geminiAPIKey,
                        useStreaming: $useStreaming,
                        onApply: {
                            travelViewId = UUID()
                            showSettings = false
                        }
                    )
                    .navigationTitle("Settings")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showSettings = false }
                        }
                    }
                }
            }
        }
    }

    /// Shown when no API key has been entered.
    private var apiKeyPromptView: some View {
        VStack(spacing: 20) {
            Image(systemName: "key")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Gemini API Key Required")
                .font(.title2.bold())

            Text("Enter your Gemini API key in Settings to start planning trips with AI.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                showSettings = true
            } label: {
                Label("Open Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @Binding var geminiAPIKey: String
    @Binding var useStreaming: Bool
    var onApply: () -> Void

    private var maskedKey: String {
        let trimmed = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return trimmed.isEmpty ? "Not configured" : "••••••••" }
        return String(trimmed.prefix(4)) + "••••" + String(trimmed.suffix(4))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Streaming Mode", isOn: $useStreaming)
            } footer: {
                Text("When enabled, responses appear incrementally as they are generated. When disabled (default), the complete response is received before display — matching Flutter's behavior and more reliable for complex UI responses.")
            }

            Section("Gemini API") {
                NavigationLink {
                    APIKeySettingsView(geminiAPIKey: $geminiAPIKey)
                } label: {
                    HStack {
                        Text("API Key")
                        Spacer()
                        Text(maskedKey)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button("Apply & Restart Chat") {
                    onApply()
                }
            }
        }
    }
}

// MARK: - API Key Settings

private struct APIKeySettingsView: View {
    @Binding var geminiAPIKey: String

    var body: some View {
        Form {
            Section {
                SecureField("API Key", text: $geminiAPIKey)
                    .autocorrectionDisabled()
            } footer: {
                Text("Get a key at [aistudio.google.com](https://aistudio.google.com/apikey)")
            }
        }
        .navigationTitle("API Key")
        #if !os(tvOS) && !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview {
    ContentView()
}
