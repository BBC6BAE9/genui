// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import Foundation
import A2UI

/// Abstraction over real/mock agent communication.
protocol TravelTransport {
    var supportsStreaming: Bool { get }
    func sendText(_ text: String, contextId: String?) async throws -> TransportResponse
    func sendAction(_ action: ResolvedAction, surfaceId: String, contextId: String?) async throws -> TransportResponse
    func sendTextStream(_ text: String, contextId: String?) -> AsyncThrowingStream<StreamEvent, Error>?
    func sendActionStream(_ action: ResolvedAction, surfaceId: String, contextId: String?) -> AsyncThrowingStream<StreamEvent, Error>?
}

/// Response from a non-streaming transport call.
struct TransportResponse {
    let messages: [ServerToClientMessage]
    let contextId: String?
    /// Optional plain text from the model when no A2UI messages were generated.
    var textResponse: String?
}
