// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import Foundation
import GenAIPrimitives

// MARK: - GeminiContentConverter

/// Adapts `GenAIPrimitives` types to the Gemini REST API JSON format.
///
/// Mirrors Flutter's `google_content_converter.dart` + `google_schema_adapter.dart`
/// pattern: a separate adapter layer isolates all Gemini-specific serialization
/// from the transport and model layers.
///
/// Gemini REST API reference:
/// https://ai.google.dev/api/generate-content
enum GeminiContentConverter {

    // MARK: - ChatMessage → Gemini contents

    /// Converts an array of `ChatMessage` to the Gemini `contents` array.
    ///
    /// - Note: System messages are not included here; they belong in
    ///   `system_instruction`. Gemini only accepts `user` and `model` roles
    ///   in `contents`.
    static func toGeminiContents(_ messages: [GenAIPrimitives.ChatMessage]) -> [[String: Any]] {
        messages.compactMap { toGeminiContent($0) }
    }

    /// Converts a single `ChatMessage` to a Gemini content dictionary.
    ///
    /// Returns `nil` for system messages (they go in `system_instruction`).
    static func toGeminiContent(_ message: GenAIPrimitives.ChatMessage) -> [String: Any]? {
        let role: String
        switch message.role {
        case .user:
            role = "user"
        case .model:
            role = "model"
        case .system:
            // System messages are handled via system_instruction, not contents.
            return nil
        }

        let parts = message.parts.compactMap { toGeminiPart($0) }
        guard !parts.isEmpty else { return nil }

        return [
            "role": role,
            "parts": parts,
        ]
    }

    /// Converts a `StandardPart` to a Gemini part dictionary.
    ///
    /// Supported mappings:
    /// - `.text` → `{"text": "..."}`
    /// - `.tool(.call)` → `{"functionCall": {"name": ..., "args": {...}}}`
    /// - `.tool(.result)` → `{"functionResponse": {"name": ..., "response": {...}}}`
    /// - `.data` → `{"inlineData": {"mimeType": ..., "data": "<base64>"}}`
    /// - `.link` → `{"fileData": {"mimeType": ..., "fileUri": ...}}`
    /// - `.thinking` → `{"thought": true, "text": "..."}`
    static func toGeminiPart(_ part: StandardPart) -> [String: Any]? {
        switch part {
        case .text(let text):
            return ["text": text]

        case .tool(let content):
            return toGeminiToolPart(content)

        case .data(let content):
            let base64 = content.bytes.base64EncodedString()
            return [
                "inlineData": [
                    "mimeType": content.mimeType,
                    "data": base64,
                ] as [String: Any],
            ]

        case .link(let content):
            var fileData: [String: Any] = ["fileUri": content.url.absoluteString]
            if let mimeType = content.mimeType {
                fileData["mimeType"] = mimeType
            }
            return ["fileData": fileData]

        case .thinking(let text):
            return ["thought": true, "text": text]
        }
    }

    /// Converts a `ToolPartContent` to the appropriate Gemini part dictionary.
    private static func toGeminiToolPart(_ content: ToolPartContent) -> [String: Any]? {
        switch content.kind {
        case .call:
            var args: [String: Any] = [:]
            if let arguments = content.arguments {
                for (key, value) in arguments {
                    if let anyVal = value.anyValue {
                        args[key] = anyVal
                    }
                }
            }
            return [
                "functionCall": [
                    "name": content.toolName,
                    "args": args,
                ] as [String: Any],
            ]

        case .result:
            let response: Any
            if let result = content.result, let anyVal = result.anyValue {
                response = anyVal
            } else {
                response = [String: Any]()
            }
            return [
                "functionResponse": [
                    "name": content.toolName,
                    "response": response,
                ] as [String: Any],
            ]
        }
    }

    // MARK: - ToolDefinition → Gemini functionDeclarations

    /// Converts an array of `ToolDefinition` to the Gemini `tools` array format.
    ///
    /// Gemini expects: `[{"functionDeclarations": [...]}]`
    static func toGeminiTools(_ tools: [ToolDefinition]) -> [[String: Any]] {
        guard !tools.isEmpty else { return [] }
        let declarations = tools.map { toGeminiFunctionDeclaration($0) }
        return [["functionDeclarations": declarations]]
    }

    /// Converts a `ToolDefinition` to a Gemini function declaration dictionary.
    ///
    /// The `inputSchema` (JSON Schema format) is adapted to Gemini's `parameters`
    /// field, which uses uppercase type names (e.g. `"OBJECT"` instead of
    /// `"object"`).
    static func toGeminiFunctionDeclaration(_ tool: ToolDefinition) -> [String: Any] {
        var declaration: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
        ]
        let parameters = adaptSchemaToGemini(tool.inputSchema)
        if !parameters.isEmpty {
            declaration["parameters"] = parameters
        }
        return declaration
    }

    // MARK: - JSON Schema → Gemini Schema adaptation

    /// Adapts a JSON Schema dictionary to Gemini's schema format.
    ///
    /// Key difference: Gemini uses uppercase type names (`"OBJECT"`, `"STRING"`,
    /// `"INTEGER"`, etc.) while JSON Schema uses lowercase.
    ///
    /// Mirrors Flutter's `google_schema_adapter.dart`.
    static func adaptSchemaToGemini(_ schema: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]

        // Convert type to uppercase
        if let type_ = schema["type"] as? String {
            result["type"] = type_.uppercased()
        }

        // Pass through description
        if let description = schema["description"] as? String {
            result["description"] = description
        }

        // Pass through enum values
        if let enumValues = schema["enum"] {
            result["enum"] = enumValues
        }

        // Pass through format (e.g. "date")
        if let format = schema["format"] as? String {
            result["format"] = format
        }

        // Recursively adapt properties
        if let properties = schema["properties"] as? [String: Any] {
            var adaptedProps: [String: Any] = [:]
            for (key, value) in properties {
                if let propSchema = value as? [String: Any] {
                    adaptedProps[key] = adaptSchemaToGemini(propSchema)
                }
            }
            result["properties"] = adaptedProps
        }

        // Pass through required fields
        if let required = schema["required"] {
            result["required"] = required
        }

        // Recursively adapt array items
        if let items = schema["items"] as? [String: Any] {
            result["items"] = adaptSchemaToGemini(items)
        }

        return result
    }

    // MARK: - Gemini response → ChatMessage

    /// Extracts the model's `ChatMessage` from a Gemini response JSON.
    ///
    /// Returns `nil` if the response contains no valid candidate content.
    static func extractModelMessage(from responseJson: [String: Any]) -> GenAIPrimitives.ChatMessage? {
        guard
            let candidates = responseJson["candidates"] as? [[String: Any]],
            let firstCandidate = candidates.first,
            let content = firstCandidate["content"] as? [String: Any],
            let partsJson = content["parts"] as? [[String: Any]]
        else {
            return nil
        }

        let parts: [StandardPart] = partsJson.compactMap { partJson in
            fromGeminiPart(partJson)
        }
        guard !parts.isEmpty else { return nil }

        return GenAIPrimitives.ChatMessage(role: .model, parts: parts)
    }

    /// Converts a Gemini part dictionary back to a `StandardPart`.
    ///
    /// Used when reading model responses to build `ChatMessage` history entries.
    static func fromGeminiPart(_ partJson: [String: Any]) -> StandardPart? {
        if let text = partJson["text"] as? String {
            let isThought = partJson["thought"] as? Bool ?? false
            if isThought {
                return .thinking(text)
            }
            return .text(text)
        }

        if let functionCall = partJson["functionCall"] as? [String: Any] {
            let name = functionCall["name"] as? String ?? ""
            let argsAny = functionCall["args"] as? [String: Any?] ?? [:]
            var args: [String: JSONValue] = [:]
            for (k, v) in argsAny {
                if let jv = JSONValue(v) {
                    args[k] = jv
                }
            }
            // Use function name as callId since Gemini REST doesn't provide one
            return ToolPart.call(callId: name, toolName: name, arguments: args)
        }

        if let functionResponse = partJson["functionResponse"] as? [String: Any] {
            let name = functionResponse["name"] as? String ?? ""
            let resultValue: JSONValue?
            if let response = functionResponse["response"] {
                resultValue = JSONValue(response)
            } else {
                resultValue = nil
            }
            return ToolPart.result(callId: name, toolName: name, result: resultValue)
        }

        if let inlineData = partJson["inlineData"] as? [String: Any],
           let mimeType = inlineData["mimeType"] as? String,
           let base64 = inlineData["data"] as? String,
           let bytes = Data(base64Encoded: base64) {
            return DataPart.create(bytes, mimeType: mimeType)
        }

        if let fileData = partJson["fileData"] as? [String: Any],
           let fileUri = fileData["fileUri"] as? String,
           let url = URL(string: fileUri) {
            let mimeType = fileData["mimeType"] as? String
            return LinkPart.create(url, mimeType: mimeType)
        }

        return nil
    }

    // MARK: - Response part extraction

    /// Extracts function calls and text parts from a Gemini response JSON.
    ///
    /// Returns a tuple of `(functionCalls, textParts)` where each function call
    /// is represented as a `ToolPartContent` and text parts are plain strings.
    static func extractResponseParts(
        from responseJson: [String: Any]
    ) -> (toolCalls: [ToolPartContent], textParts: [String]) {
        guard
            let candidates = responseJson["candidates"] as? [[String: Any]],
            let firstCandidate = candidates.first,
            let content = firstCandidate["content"] as? [String: Any],
            let partsJson = content["parts"] as? [[String: Any]]
        else {
            return ([], [])
        }

        var toolCalls: [ToolPartContent] = []
        var textParts: [String] = []

        for partJson in partsJson {
            if let functionCall = partJson["functionCall"] as? [String: Any] {
                let name = functionCall["name"] as? String ?? ""
                let argsAny = functionCall["args"] as? [String: Any?] ?? [:]
                var args: [String: JSONValue] = [:]
                for (k, v) in argsAny {
                    if let jv = JSONValue(v) {
                        args[k] = jv
                    }
                }
                toolCalls.append(.call(callId: name, toolName: name, arguments: args))
            }
            if let text = partJson["text"] as? String {
                textParts.append(text)
            }
        }

        return (toolCalls, textParts)
    }
}
