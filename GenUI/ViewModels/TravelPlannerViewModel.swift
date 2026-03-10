// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import SwiftUI
import A2UI

/// The main view model managing the travel planning conversation.
/// Uses the A2UI SDK to process server messages and render dynamic surfaces.
///
/// Mirrors the Flutter architecture: a single persistent `SurfaceManager` receives
/// all messages across the conversation, so surfaces can be updated in-place by
/// subsequent `updateComponents` messages.
@Observable
final class TravelPlannerViewModel {
    var messages: [ChatMessage] = []
    var isProcessing: Bool = false

    /// Bumped whenever surfaces are updated in-place to force SwiftUI re-renders.
    var surfaceUpdateCounter: Int = 0

    /// Persistent surface manager — shared across the entire conversation,
    /// matching Flutter's single `SurfaceController` pattern.
    let surfaceManager = SurfaceManager()

    private(set) var transport: TravelTransport
    private var contextId: String?

    init(transport: TravelTransport) {
        self.transport = transport
    }

    // MARK: - Actions

    func sendMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isProcessing else { return }

        messages.append(.user(text))
        let loadingIndex = messages.count
        messages.append(.loading())
        isProcessing = true

        Task { @MainActor in
            do {
                if let stream = transport.sendTextStream(text, contextId: contextId) {
                    await handleStream(stream, loadingIndex: loadingIndex)
                } else {
                    let response = try await transport.sendText(text, contextId: contextId)
                    contextId = response.contextId ?? contextId
                    handleTransportResponse(response, loadingIndex: loadingIndex)
                }
            } catch {
                replaceLoading(at: loadingIndex, with: .agent("Sorry, something went wrong: \(error.localizedDescription)"))
            }
            isProcessing = false
        }
    }

    /// Handle a UI action (button click, carousel tap, trailhead selection).
    /// Unlike `sendMessage`, this does NOT show a user bubble in the chat,
    /// but does show a loading indicator while waiting for the response.
    func handleAction(_ action: ResolvedAction, surfaceId: String) {
        guard !isProcessing else { return }

        let loadingIndex = messages.count
        messages.append(.loading(statusText: "Working..."))
        isProcessing = true

        // Set the client data model on the transport so Gemini has full context
        // about the current UI state — matching Flutter's A2uiTransportAdapter.
        updateClientDataModel()

        Task { @MainActor in
            do {
                if let stream = transport.sendActionStream(action, surfaceId: surfaceId, contextId: contextId) {
                    await handleStream(stream, loadingIndex: loadingIndex)
                } else {
                    let response = try await transport.sendAction(action, surfaceId: surfaceId, contextId: contextId)
                    contextId = response.contextId ?? contextId
                    handleTransportResponse(response, loadingIndex: loadingIndex)
                }
            } catch {
                replaceLoading(at: loadingIndex, with: .agent("Sorry, something went wrong: \(error.localizedDescription)"))
            }
            isProcessing = false
        }
    }

    // MARK: - Private

    /// Handle a transport response: process A2UI messages, show text, or handle in-place updates.
    private func handleTransportResponse(_ response: TransportResponse, loadingIndex: Int) {
        if let agentMessage = processServerMessages(response.messages) {
            replaceLoading(at: loadingIndex, with: agentMessage)
        } else if let textResponse = response.textResponse {
            // Gemini responded with text but no A2UI JSON — show as text bubble.
            replaceLoading(at: loadingIndex, with: .agent(textResponse))
        } else {
            // In-place update only or empty response — remove loading
            removeLoading(at: loadingIndex)
        }
    }

    /// Process server messages through the persistent SurfaceManager and build a ChatMessage.
    /// Only newly created surfaces get added to a new ChatMessage.
    /// Surfaces that are merely updated (via surfaceUpdate on an existing surfaceId)
    /// are updated in-place in the SurfaceManager and re-rendered by the ChatMessage
    /// that originally referenced them — matching Flutter's behavior.
    private func processServerMessages(_ serverMessages: [ServerToClientMessage]) -> ChatMessage? {
        if serverMessages.isEmpty {
            return nil
        }

        // Track which surfaces are newly created vs merely updated
        var newSurfaceIds: [String] = []
        var updatedSurfaceIds: [String] = []
        for msg in serverMessages {
            if let br = msg.beginRendering, !newSurfaceIds.contains(br.surfaceId) {
                newSurfaceIds.append(br.surfaceId)
            }
            if let su = msg.surfaceUpdate {
                if !newSurfaceIds.contains(su.surfaceId) && !updatedSurfaceIds.contains(su.surfaceId) {
                    updatedSurfaceIds.append(su.surfaceId)
                }
            }
        }

        do {
            try surfaceManager.processMessages(serverMessages)
        } catch {
            return .agent("Failed to render: \(error.localizedDescription)")
        }

        // Only create a new chat message for NEWLY created surfaces.
        // Updated surfaces are already displayed by their original ChatMessage
        // and will re-render automatically via the shared SurfaceManager.
        if newSurfaceIds.isEmpty {
            // All changes were in-place updates — bump counter to ensure re-render.
            surfaceUpdateCounter += 1
            return nil
        }

        return .agentSurface(ids: newSurfaceIds)
    }

    private func handleStream(_ stream: AsyncThrowingStream<StreamEvent, Error>, loadingIndex: Int) async {
        do {
            for try await event in stream {
                switch event {
                case .status(_, let text, _, let ctxId, _):
                    if let ctxId { contextId = ctxId }
                    if loadingIndex < messages.count {
                        messages[loadingIndex].statusText = text ?? "Working..."
                    }
                case .result(let result):
                    contextId = result.contextId ?? contextId
                    if let agentMessage = processServerMessages(result.messages) {
                        replaceLoading(at: loadingIndex, with: agentMessage)
                    } else {
                        removeLoading(at: loadingIndex)
                    }
                }
            }
        } catch {
            replaceLoading(at: loadingIndex, with: .agent("Stream error: \(error.localizedDescription)"))
        }
    }

    private func replaceLoading(at index: Int, with message: ChatMessage) {
        if index < messages.count && messages[index].isLoading {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    private func removeLoading(at index: Int) {
        if index < messages.count && messages[index].isLoading {
            messages.remove(at: index)
        }
    }

    /// Sync the client data model from all surfaces to the transport,
    /// matching Flutter's pattern of including data model in system instructions.
    private func updateClientDataModel() {
        guard let geminiTransport = transport as? GeminiTravelTransport else { return }
        var dataModel: [String: [String: AnyCodable]] = [:]
        for (surfaceId, vm) in surfaceManager.surfaces {
            if !vm.dataModel.isEmpty {
                dataModel[surfaceId] = vm.dataModel
            }
        }
        geminiTransport.clientDataModel = dataModel.isEmpty ? nil : dataModel
    }
}
