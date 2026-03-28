// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import SwiftUI

/// The root content view with a navigation-based layout.
/// Provides navigation to the AI chat planner and widget catalog.
struct ContentView: View {
    @AppStorage("geminiAPIKey") private var geminiAPIKey = ""
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
                        geminiAPIKey: geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    .id(travelViewId)
                }
            }
            .navigationTitle("Agentic Travel")
            .navigationSubtitle("SwiftUI GenUI")
            #if !os(tvOS) && !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        // No action
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                }
                ToolbarItem() {
                    HStack(spacing: 12) {
                        Button {
                            showCatalog = true
                        } label: {
                            Image(systemName: "square.grid.2x2")
                        }
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "key")
                        }
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
                Label("Open Settings", systemImage: "gear")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @Binding var geminiAPIKey: String
    var onApply: () -> Void

    var body: some View {
        Form {
            Section("Gemini API") {
                SecureField("API Key", text: $geminiAPIKey)
                    .autocorrectionDisabled()
                Text("Get a key at [aistudio.google.com](https://aistudio.google.com/apikey)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Apply & Restart Chat") {
                    onApply()
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
