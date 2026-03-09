// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import Foundation
import A2UI

/// Connects to a real A2A agent endpoint.
final class RealTravelTransport: TravelTransport {
    private let client: A2AClient
    private let streaming: Bool

    var supportsStreaming: Bool { streaming }

    init(client: A2AClient) {
        self.client = client
        self.streaming = client.agentCard?.streaming ?? false
    }

    static func connect(url: URL) async throws -> RealTravelTransport {
        let client = try await A2AClient.fromBaseURL(url)
        return RealTravelTransport(client: client)
    }

    func sendText(_ text: String, contextId: String?) async throws -> TransportResponse {
        let result = try await client.sendText(text, contextId: contextId)
        return TransportResponse(messages: result.messages, contextId: result.contextId)
    }

    func sendAction(_ action: ResolvedAction, surfaceId: String, contextId: String?) async throws -> TransportResponse {
        let result = try await client.sendAction(action, surfaceId: surfaceId, contextId: contextId)
        return TransportResponse(messages: result.messages, contextId: result.contextId)
    }

    func sendTextStream(_ text: String, contextId: String?) -> AsyncThrowingStream<StreamEvent, Error>? {
        guard supportsStreaming else { return nil }
        return client.sendTextStream(text, contextId: contextId)
    }

    func sendActionStream(_ action: ResolvedAction, surfaceId: String, contextId: String?) -> AsyncThrowingStream<StreamEvent, Error>? {
        guard supportsStreaming else { return nil }
        return client.sendActionStream(action, surfaceId: surfaceId, contextId: contextId)
    }
}
