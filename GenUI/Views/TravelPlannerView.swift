// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import SwiftUI
import A2UI

/// The main travel planner page with chat conversation and input.
/// Supports mock (demo), Gemini API, and real agent connection modes.
struct TravelPlannerView: View {
    var connectionMode: TravelConnectionMode = .geminiAPI
    var agentURL: URL?
    var geminiAPIKey: String = ""

    @State private var viewModel: TravelPlannerViewModel
    @State private var inputText = ""
    @State private var connectionError: String?
    @State private var isConnecting = false

    init(connectionMode: TravelConnectionMode = .geminiAPI, agentURL: URL? = nil, geminiAPIKey: String = "") {
        self.connectionMode = connectionMode
        self.agentURL = agentURL
        self.geminiAPIKey = geminiAPIKey

        // Create viewModel with the correct transport immediately.
        // For .realAgent the transport is swapped async in .task.
        let transport: TravelTransport
        switch connectionMode {
        case .mock:
            transport = MockTravelTransport()
        case .geminiAPI:
            transport = GeminiTravelTransport(apiKey: geminiAPIKey)
        case .realAgent:
            // Placeholder until async connection completes
            transport = MockTravelTransport()
        }
        _viewModel = State(initialValue: TravelPlannerViewModel(transport: transport))
    }

    var body: some View {
        Group {
            if isConnecting {
                ProgressView("Connecting to agent...")
            } else if let connectionError {
                ContentUnavailableView(
                    "Connection Failed",
                    systemImage: "wifi.exclamationmark",
                    description: Text(connectionError)
                )
            } else {
                chatView
            }
        }
        .task {
            // Only need async setup for realAgent
            if connectionMode == .realAgent, let agentURL {
                isConnecting = true
                do {
                    let transport = try await RealTravelTransport.connect(url: agentURL)
                    viewModel = TravelPlannerViewModel(transport: transport)
                } catch {
                    connectionError = error.localizedDescription
                }
                isConnecting = false
            }
        }
    }

    @ViewBuilder
    private var chatView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ConversationView(
                            messages: viewModel.messages,
                            viewModel: viewModel
                        )

                        // Scroll anchor
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                }
                .onChange(of: viewModel.messages.count) {
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            Divider()

            ChatInputView(
                text: $inputText,
                isProcessing: viewModel.isProcessing
            ) { text in
                viewModel.sendMessage(text)
                inputText = ""
            }
        }
    }
}

// MARK: - Chat Input

struct ChatInputView: View {
    @Binding var text: String
    let isProcessing: Bool
    var onSend: ((String) -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            TextField("Enter your prompt...", text: $text)
                .textFieldStyle(.plain)
                .disabled(isProcessing)
                .onSubmit {
                    if !isProcessing && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onSend?(text)
                    }
                }

            if isProcessing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    onSend?(text)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .accentColor)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 25)
                .fill(.background)
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: -1)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

#Preview {
    TravelPlannerView()
}
