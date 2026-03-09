// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import SwiftUI

/// Connection mode for the travel planner.
enum TravelConnectionMode: String, CaseIterable {
    case mock = "Demo (Mock)"
    case geminiAPI = "Gemini API"
    case realAgent = "Real Agent"
}

/// The root content view with a tab-based layout.
/// Provides tabs for the AI chat planner and widget catalog.
struct ContentView: View {
    @State private var connectionMode: TravelConnectionMode = .geminiAPI
    @State private var agentURLString = ""
    @AppStorage("geminiAPIKey") private var geminiAPIKey = ""
    @State private var travelViewId = UUID()
    @State private var showSettings = false

    /// Whether the Gemini API mode is selected but no API key has been provided.
    private var needsAPIKey: Bool {
        connectionMode == .geminiAPI && geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        TabView {
            Tab("Travel", systemImage: "airplane") {
                NavigationStack {
                    Group {
                        if needsAPIKey {
                            apiKeyPromptView
                        } else {
                            TravelPlannerView(
                                connectionMode: connectionMode,
                                agentURL: connectionMode == .realAgent ? URL(string: agentURLString) : nil,
                                geminiAPIKey: geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                            .id(travelViewId)
                        }
                    }
                    .navigationTitle("Agentic Travel")
                    .toolbar {
                        ToolbarItem() {
                            Image(systemName: "line.3.horizontal")
                        }
                        ToolbarItem() {
                            HStack(spacing: 12) {
                                Button {
                                    showSettings = true
                                } label: {
                                    Image(systemName: "gear")
                                }
                                Image(systemName: "person.circle")
                            }
                        }
                    }
                    .sheet(isPresented: $showSettings) {
                        NavigationStack {
                            SettingsView(
                                connectionMode: $connectionMode,
                                agentURLString: $agentURLString,
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

            Tab("Widget Catalog", systemImage: "square.grid.2x2") {
                NavigationStack {
                    CatalogView()
                        .navigationTitle("Widget Catalog")
                }
            }
        }
    }

    /// Shown when Gemini API mode is active but no API key has been entered.
    private var apiKeyPromptView: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.fill")
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
    @Binding var connectionMode: TravelConnectionMode
    @Binding var agentURLString: String
    @Binding var geminiAPIKey: String
    var onApply: () -> Void

    var body: some View {
        Form {
            Section("Connection Mode") {
                Picker("Mode", selection: $connectionMode) {
                    ForEach(TravelConnectionMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            if connectionMode == .geminiAPI {
                Section("Gemini API") {
                    SecureField("API Key", text: $geminiAPIKey)
                        .autocorrectionDisabled()
                    Text("Get a key at [aistudio.google.com](https://aistudio.google.com/apikey)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if connectionMode == .realAgent {
                Section("Agent Connection") {
                    TextField("Agent URL", text: $agentURLString)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                }
            }

            Section {
                Button("Apply & Restart Chat") {
                    onApply()
                }
            }

            Section("About") {
                LabeledContent("Mode", value: connectionMode.rawValue)
            }
        }
    }
}

#Preview {
    ContentView()
}
