// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import SwiftUI

/// The main travel planner page with chat conversation and input.
struct TravelPlannerView: View {
    var geminiAPIKey: String = ""
    var useStreaming: Bool = false

    @State private var viewModel: TravelPlannerViewModel
    @State private var inputText = ""

    init(geminiAPIKey: String = "", useStreaming: Bool = false) {
        self.geminiAPIKey = geminiAPIKey
        self.useStreaming = useStreaming
        _viewModel = State(initialValue: TravelPlannerViewModel(
            transport: GeminiTravelTransport(apiKey: geminiAPIKey, useStreaming: useStreaming)
        ))
    }

    var body: some View {
        chatView
    }

    @ViewBuilder
    private var chatView: some View {
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ChatInputView(
                    text: $inputText,
                    isProcessing: viewModel.isProcessing
                ) { text in
                    viewModel.sendMessage(text)
                    inputText = ""
                }
                .background(Color(.systemBackground).blur(radius: 5).ignoresSafeArea())
            }
            .onChange(of: viewModel.scrollTrigger) {
                withAnimation {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
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
                .shadow(color: .black.opacity(0.1), radius: 4)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

#Preview {
    TravelPlannerView()
}
