// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import SwiftUI
import A2UI

/// A message in the travel planner conversation.
/// Agent surface messages carry surfaceIds that reference the shared SurfaceManager.
struct ChatMessage: Identifiable {
    let id = UUID()
    let role: ChatMessageRole
    var text: String?
    /// Surface IDs to render from the shared SurfaceManager (matches Flutter's UiPart pattern).
    var surfaceIds: [String]?
    var isLoading: Bool
    var statusText: String?

    enum ChatMessageRole {
        case user
        case agent
    }

    static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, text: text, isLoading: false)
    }

    static func agent(_ text: String) -> ChatMessage {
        ChatMessage(role: .agent, text: text, isLoading: false)
    }

    /// Create a message that renders surfaces by ID from the shared SurfaceManager.
    static func agentSurface(ids: [String]) -> ChatMessage {
        ChatMessage(role: .agent, surfaceIds: ids, isLoading: false)
    }

    static func loading(statusText: String? = "Thinking...") -> ChatMessage {
        ChatMessage(role: .agent, isLoading: true, statusText: statusText)
    }
}
