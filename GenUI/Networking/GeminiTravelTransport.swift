// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import Foundation
import A2UIV09
import GenAIPrimitives

/// Transport that calls the Google Gemini REST API directly,
/// aligning with the Flutter `GoogleGenerativeAiClient` implementation.
///
/// By default uses non-streaming `generateContent` to match Flutter's approach.
/// Streaming can be enabled via `useStreaming` for a more interactive UX,
/// but may be less reliable for large JSON responses.
final class GeminiTravelTransport: TravelTransport {
    let supportsStreaming: Bool

    private let apiKey: String
    private let model: String

    /// Typed conversation history using `GenAIPrimitives.ChatMessage`.
    ///
    /// Replaces the previous `[[String: Any]]` representation. Serialization to
    /// Gemini REST JSON format is handled by `GeminiContentConverter`.
    private var conversationHistory: [GenAIPrimitives.ChatMessage] = []

    /// Client data model set by the ViewModel before actions, matching Flutter's
    /// pattern of including the data model in the system instruction.
    var clientDataModel: A2uiClientDataModel?

    /// Stores the last plain text response from the model when no A2UI messages
    /// were generated. Read by the ViewModel to show as a text bubble.
    private(set) var lastTextResponse: String?

    /// Generation config shared by streaming and non-streaming requests.
    /// An explicit `maxOutputTokens` prevents the model from truncating large
    /// JSON responses (e.g. TravelCarousel with multiple Image components).
    /// Flutter uses non-streaming `generateContent` which is less susceptible
    /// to truncation; streaming needs this safeguard.
    private static let generationConfig: [String: Any] = [
        "maxOutputTokens": 65536,
    ]

    init(apiKey: String, model: String = "gemini-3-flash-preview", useStreaming: Bool = false) {
        self.apiKey = apiKey
        self.model = model
        self.supportsStreaming = useStreaming
    }

    // MARK: - TravelTransport

    func sendText(_ text: String, contextId: String?) async throws -> TransportResponse {
        print("[GeminiTransport] sendText: \"\(text.prefix(100))\" self=\(ObjectIdentifier(self))")
        conversationHistory.append(GenAIPrimitives.ChatMessage.user(text))

        let messages = try await generateContent()
        print("[GeminiTransport] sendText returning \(messages.count) messages")
        return TransportResponse(messages: messages, contextId: contextId, textResponse: lastTextResponse)
    }

    func sendAction(_ action: ResolvedAction, surfaceId: String, contextId: String?) async throws -> TransportResponse {
        let interactionText = buildInteractionText(action: action, surfaceId: surfaceId)
        print("[GeminiTransport] sendAction: \(interactionText)")
        conversationHistory.append(GenAIPrimitives.ChatMessage.user(interactionText))

        let messages = try await generateContent()
        print("[GeminiTransport] sendAction returning \(messages.count) messages")
        return TransportResponse(messages: messages, contextId: contextId, textResponse: lastTextResponse)
    }

    func sendTextStream(_ text: String, contextId: String?) -> AsyncThrowingStream<StreamEvent, Error>? {
        guard supportsStreaming else { return nil }
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    conversationHistory.append(GenAIPrimitives.ChatMessage.user(text))
                    try streamContent(continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func sendActionStream(_ action: ResolvedAction, surfaceId: String, contextId: String?) -> AsyncThrowingStream<StreamEvent, Error>? {
        guard supportsStreaming else { return nil }
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let interactionText = buildInteractionText(action: action, surfaceId: surfaceId)
                    conversationHistory.append(GenAIPrimitives.ChatMessage.user(interactionText))
                    try streamContent(continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Serialises a `ResolvedAction` to the A2UI interaction JSON string that is
    /// sent as the user turn, matching Flutter's format.
    ///
    /// Both the non-streaming (`sendAction`) and streaming (`sendActionStream`)
    /// paths use this shared helper to avoid duplicating the encoding logic.
    private func buildInteractionText(action: ResolvedAction, surfaceId: String) -> String {
        var actionContext: [String: Any] = [:]
        for (key, value) in action.context {
            switch value {
            case .string(let s): actionContext[key] = s
            case .number(let n): actionContext[key] = n
            case .bool(let b): actionContext[key] = b
            default: actionContext[key] = "\(value)"
            }
        }
        let interactionJson: [String: Any] = [
            "interaction": [
                "version": "v0.9",
                "action": [
                    "surfaceId": surfaceId,
                    "name": action.name,
                    "sourceComponentId": action.sourceComponentId,
                    "context": actionContext,
                ] as [String: Any],
            ] as [String: Any],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: interactionJson, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "User action: \(action.name) on surface: \(surfaceId)"
    }

    @discardableResult
    private func streamContent(continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) throws -> Bool {
        Task {
            do {
                let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?key=\(apiKey)&alt=sse")!
                let requestBody: [String: Any] = [
                    "contents": GeminiContentConverter.toGeminiContents(conversationHistory),
                    "system_instruction": systemInstruction(),
                    "tools": GeminiContentConverter.toGeminiTools(toolDefinitions),
                    "toolConfig": ["functionCallingConfig": ["mode": "AUTO"]],
                    "generationConfig": Self.generationConfig
                ]

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 300
                request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw GeminiError.invalidResponse
                }

                var textChunks: [String] = []
                var accumulatedToolCalls: [ToolPartContent] = []
                var streamedModelParts: [StandardPart] = []

                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let jsonStr = String(line.dropFirst(6))
                    guard jsonStr != "[DONE]",
                          let data = jsonStr.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                    let (_, calls, textParts, finishReason) = GeminiContentConverter.extractResponseParts(from: json)
                    accumulatedToolCalls.append(contentsOf: calls)

                    if finishReason == "MAX_TOKENS" {
                        print("[GeminiTransport] ⚠️ Response truncated (MAX_TOKENS) — output may be incomplete")
                    }

                    for chunk in textParts {
                        textChunks.append(chunk)
                        streamedModelParts.append(.text(chunk))
                        continuation.yield(.textChunk(chunk))
                    }
                    for call in calls {
                        streamedModelParts.append(.tool(call))
                    }
                }

                let accumulatedText = textChunks.joined()

                // Save model turn to history as a typed ChatMessage
                if !streamedModelParts.isEmpty {
                    conversationHistory.append(GenAIPrimitives.ChatMessage(role: .model, parts: streamedModelParts))
                }

                if !accumulatedToolCalls.isEmpty {
                    // Handle tool calls: execute and make another (non-streaming) call
                    continuation.yield(.status(state: "tool_use", text: "Looking up options...", taskId: nil, contextId: nil, isFinal: false))
                    var toolResultParts: [StandardPart] = []
                    for call in accumulatedToolCalls {
                        let args: [String: Any] = (call.arguments ?? [:]).compactMapValues { $0.anyValue }
                        let result = await executeTool(name: call.toolName, args: args)
                        let resultValue = JSONValue(result as Any) ?? .object([:])
                        toolResultParts.append(
                            ToolPart.result(
                                callId: call.callId,
                                toolName: call.toolName,
                                result: resultValue
                            )
                        )
                    }
                    conversationHistory.append(GenAIPrimitives.ChatMessage(role: .user, parts: toolResultParts))

                    // Non-streaming follow-up after tool use
                    let finalMessages = try await generateContent()
                    let cleanText = stripJSONBlocks(from: lastTextResponse ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.yield(.result(TransportResponse(messages: finalMessages, contextId: nil, textResponse: cleanText.isEmpty ? nil : cleanText)))
                } else {
                    // Don't re-parse A2UI messages here — they were already processed
                    // inline by the collectStream's A2UIStreamParser during streaming.
                    // Only pass along any remaining plain text.
                    let cleanText = stripJSONBlocks(from: accumulatedText).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.yield(.result(TransportResponse(messages: [], contextId: nil, textResponse: cleanText.isEmpty ? nil : cleanText)))
                }

                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return true
    }

    // MARK: - Gemini API

    private func generateContent() async throws -> [A2uiMessage] {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!

        let requestBody: [String: Any] = [
            "contents": GeminiContentConverter.toGeminiContents(conversationHistory),
            "system_instruction": systemInstruction(),
            "tools": GeminiContentConverter.toGeminiTools(toolDefinitions),
            "toolConfig": ["functionCallingConfig": ["mode": "AUTO"]],
            "generationConfig": Self.generationConfig
        ]

        let currentJson = try await callGemini(url: url, body: requestBody)
        return try await handleResponse(currentJson, url: url)
    }

    /// Send a request to the Gemini API and return the parsed JSON response.
    private func callGemini(url: URL, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180 // Gemini thinking models can take a while
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[GeminiTransport] Calling Gemini API...")
        let (data, response) = try await URLSession.shared.data(for: request)
        print("[GeminiTransport] Gemini API responded, \(data.count) bytes")

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "unknown error"
            print("[GeminiTransport] API error \(httpResponse.statusCode): \(responseBody.prefix(500))")
            throw GeminiError.apiError(statusCode: httpResponse.statusCode, message: responseBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiError.invalidResponse
        }

        return json
    }

    /// Process a Gemini response, handling tool call loops.
    private func handleResponse(_ initialJson: [String: Any], url: URL) async throws -> [A2uiMessage] {
        lastTextResponse = nil
        var currentJson = initialJson
        var toolCycles = 0
        let maxToolCycles = 40

        while toolCycles < maxToolCycles {
            let (modelMessage, toolCalls, textParts, finishReason) = GeminiContentConverter.extractResponseParts(from: currentJson)

            if finishReason == "MAX_TOKENS" {
                print("[GeminiTransport] ⚠️ Response truncated (MAX_TOKENS) — output may be incomplete")
            }

            if toolCalls.isEmpty {
                let fullText = textParts.joined()
                print("[GeminiTransport] Model text response (\(fullText.count) chars): \(fullText.prefix(300))...")

                // Add model response to conversation history as a typed ChatMessage
                if let modelMessage {
                    conversationHistory.append(modelMessage)
                }

                let messages = await parseA2uiMessages(from: fullText)
                print("[GeminiTransport] Parsed \(messages.count) A2UI messages")

                // If no A2UI messages were parsed but there's text, save it
                // so the ViewModel can show it as a text bubble.
                if messages.isEmpty {
                    let cleanText = stripJSONBlocks(from: fullText).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleanText.isEmpty {
                        lastTextResponse = cleanText
                    }
                }

                return messages
            }

            toolCycles += 1
            print("[GeminiTransport] Tool cycle \(toolCycles): \(toolCalls.count) function call(s)")

            // Add model response (with function calls) to history as a typed ChatMessage
            if let modelMessage {
                conversationHistory.append(modelMessage)
            }

            // Process function calls and build typed tool-result ChatMessage
            var toolResultParts: [StandardPart] = []
            for call in toolCalls {
                let args: [String: Any] = (call.arguments ?? [:]).compactMapValues { $0.anyValue }
                print("[GeminiTransport] Executing tool: \(call.toolName) args: \(args)")
                let result = await executeTool(name: call.toolName, args: args)
                let resultValue = JSONValue(result as Any) ?? .object([:])
                toolResultParts.append(
                    ToolPart.result(
                        callId: call.callId,
                        toolName: call.toolName,
                        result: resultValue
                    )
                )
            }

            // Add tool responses to history as a typed ChatMessage
            conversationHistory.append(GenAIPrimitives.ChatMessage(role: .user, parts: toolResultParts))

            let nextRequestBody: [String: Any] = [
                "contents": GeminiContentConverter.toGeminiContents(conversationHistory),
                "system_instruction": systemInstruction(),
                "tools": GeminiContentConverter.toGeminiTools(toolDefinitions),
                "toolConfig": ["functionCallingConfig": ["mode": "AUTO"]],
                "generationConfig": Self.generationConfig
            ]

            currentJson = try await callGemini(url: url, body: nextRequestBody)
        }

        print("[GeminiTransport] Exceeded max tool cycles (\(maxToolCycles))")
        return []
    }

    /// Tool declarations as typed `ToolDefinition` instances.
    ///
    /// Stored as a `let` constant — the set of tools never changes during the
    /// lifetime of the transport. Serialization to Gemini `functionDeclarations`
    /// format is done by `GeminiContentConverter.toGeminiTools(_:)`.
    ///
    /// Matches the Flutter `ListHotelsTool` schema in `list_hotels_tool.dart`.
    private let toolDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "listHotels",
            description: "Lists hotels based on the provided criteria.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "The search query, e.g., \"hotels in Paris\".",
                    ] as [String: Any],
                    "checkIn": [
                        "type": "string",
                        "description": "The check-in date in ISO 8601 format (YYYY-MM-DD).",
                        "format": "date",
                    ] as [String: Any],
                    "checkOut": [
                        "type": "string",
                        "description": "The check-out date in ISO 8601 format (YYYY-MM-DD).",
                        "format": "date",
                    ] as [String: Any],
                    "guests": [
                        "type": "integer",
                        "description": "The number of guests.",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["query", "checkIn", "checkOut", "guests"],
            ]
        ),
    ]

    /// Execute a tool call. Currently supports `listHotels`.
    /// Delegates to `BookingService` matching Flutter's pattern.
    private func executeTool(name: String, args: [String: Any]) async -> [String: Any] {
        if name == "listHotels" {
            let query = args["query"] as? String ?? ""
            let checkIn = args["checkIn"] as? String ?? ""
            let checkOut = args["checkOut"] as? String ?? ""
            let guests = (args["guests"] as? Int) ?? (args["guests"] as? Double).map { Int($0) } ?? 2
            let results = BookingService.instance.listHotels(
                query: query, checkIn: checkIn, checkOut: checkOut, guests: guests
            )
            return ["listings": results]
        }
        return ["error": "Unknown tool: \(name)"]
    }

    // MARK: - System Instruction

    /// Returns the system instruction in Gemini REST API `system_instruction` format.
    ///
    /// Matches Flutter's `_BasicPromptBuilder.systemPrompt()` assembly order:
    /// 1. systemPromptFragments (= prompt list: currentDate, systemPrompt, uiGenerationRestriction)
    /// 2. "Use the provided tools..."
    /// 3. technicalPossibilities (3 IMPORTANT statements)
    /// 4. catalog.systemPromptFragments (empty for travelAppCatalog)
    /// 5. allowedOperations.systemPromptFragments (controllingTheUI, outputFormat)
    /// 6. A2UI JSON Schema
    /// 7. Client Data Model (if available)
    private func systemInstruction() -> [String: Any] {
        let dateString = ISO8601DateFormatter().string(from: Date()).prefix(10)
        var parts: [[String: Any]] = [
            // --- systemPromptFragments (= Flutter's `prompt` list) ---
            ["text": "Current Date: \(dateString)"],
            ["text": Self.systemPrompt],
            ["text": Self.uiGenerationRestriction],
            // --- PromptBuilder.custom() injected fragments ---
            ["text": "Use the provided tools to respond to user using rich UI elements."],
            // --- TechnicalPossibilities (all false → 3 IMPORTANT statements) ---
            ["text": "IMPORTANT: You do not have the ability to execute code. If you need to perform calculations, do them yourself."],
            ["text": "IMPORTANT: You do not have the ability to use tools for UI generation."],
            ["text": "IMPORTANT: You do not have the ability to use function calls for UI generation."],
            // --- catalog.systemPromptFragments (empty for travelAppCatalog) ---
            // --- allowedOperations.systemPromptFragments ---
            ["text": Self.controllingTheUI],
            ["text": Self.outputFormat],
        ]
        // A2UI JSON Schema
        parts.append(["text": Self.catalogSchema])
        // Client Data Model (matches Flutter's pattern)
        if let clientDataModel {
            var dataDict: [String: Any] = [:]
            for (surfaceId, surfaceData) in clientDataModel.surfaces {
                dataDict[surfaceId] = anyCodableToAny(surfaceData)
            }
            if let data = try? JSONSerialization.data(withJSONObject: dataDict, options: [.prettyPrinted, .sortedKeys]),
               let dataString = String(data: data, encoding: .utf8) {
                parts.append(["text": "Client Data Model:\n\(dataString)"])
            }
        }
        return ["parts": parts]
    }

    /// Convert AnyCodable to Any for JSONSerialization.
    private func anyCodableToAny(_ value: AnyCodable) -> Any {
        switch value {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let arr): return arr.map { anyCodableToAny($0) }
        case .dictionary(let dict):
            var result: [String: Any] = [:]
            for (k, v) in dict { result[k] = anyCodableToAny(v) }
            return result
        }
    }

    // MARK: - JSON Block Parsing

    /// Parse A2UI messages from the response text.
    /// Mirrors Flutter's `GoogleGenerativeAiClient` which uses `JsonBlockParser.parseJsonBlocks`.
    private func parseA2uiMessages(from text: String) async -> [A2uiMessage] {
        // Use A2UIStreamParser (from SPM) — feed full text then collect via events stream.
        let parser = A2UIStreamParser()
        var messages: [A2uiMessage] = []

        await parser.add(text)
        await parser.finish()

        for await event in parser.events {
            switch event {
            case .message(let msg):
                messages.append(msg)
            case .text, .error:
                break
            }
        }

        // Fallback: use JsonBlockParser (from SPM) for blocks that A2UIStreamParser
        // couldn't decode (e.g. missing "version" field).
        // Mirrors Flutter's GoogleGenerativeAiClient fallback path.
        if messages.isEmpty {
            let blocks = JsonBlockParser.parseJsonBlocks(text)
            for block in blocks {
                guard var json = block as? [String: Any] else { continue }
                // Inject version if missing — matches Flutter SurfaceController behaviour.
                if json["version"] == nil { json["version"] = "v0.9" }
                if let message = MockServerToClientMessages.decodeMessage(json) {
                    messages.append(message)
                }
            }
        }

        print("[GeminiTransport] parseA2uiMessages: \(messages.count) messages from \(text.count) chars")
        return messages
    }

    /// Strip JSON code blocks from text, leaving only the conversational text.
    /// Delegates to `JsonBlockParser.stripJsonBlock` from SPM.
    private func stripJSONBlocks(from text: String) -> String {
        JsonBlockParser.stripJsonBlock(text)
    }

    // MARK: - Prompts (aligned with Flutter travel_planner_page.dart)

    /// The available asset images, aligned with Flutter's `_images.json`.
    /// Each entry has `image_file_name` (asset path) and `description` so the
    /// LLM can pick contextually relevant images.
    private static let assetImages = """
    [
        {"image_file_name": "assets/travel_images/snorkeling_hanauma_bay_hawaii.jpg", "description": "Snorkelers at Hanauma Bay, Oahu, Hawaii."},
        {"image_file_name": "assets/travel_images/snorkeling_gear.jpg", "description": "Typical snorkeling equipment: snorkel, diving mask and swimfins."},
        {"image_file_name": "assets/travel_images/sailing_contender_dinghy.jpg", "description": "A person sailing a Contender dinghy."},
        {"image_file_name": "assets/travel_images/alimini_lake_otranto_italy.jpg", "description": "The Alimini Lakes in Otranto, Italy."},
        {"image_file_name": "assets/travel_images/brighton_beach_england.jpg", "description": "Brighton beach and the chain pier in the distance."},
        {"image_file_name": "assets/travel_images/carters_beach_sand.jpg", "description": "Sand at Carters Beach, Canada."},
        {"image_file_name": "assets/travel_images/castelldefels_spain_september.jpg", "description": "A beach in Castelldefels, Spain in September."},
        {"image_file_name": "assets/travel_images/green_sand_mahana_beach_hawaii.jpg", "description": "A closeup of green sand from Mahana Beach in Hawaii."},
        {"image_file_name": "assets/travel_images/llandudno_wales.jpg", "description": "A photograph of Llandudno, Wales."},
        {"image_file_name": "assets/travel_images/man_o_war_cove_dorset_england.jpg", "description": "Man O\u{2019}War Cove in St Oswalds Bay, Dorset, England."},
        {"image_file_name": "assets/travel_images/monte_carlo_casino_monaco.jpg", "description": "The seaside facade of the Monte Carlo Casino."},
        {"image_file_name": "assets/travel_images/ramla_bay_gozo_malta.jpg", "description": "Ramla Bay on the island of Gozo, Malta."},
        {"image_file_name": "assets/travel_images/blackpool_promenade_england.jpg", "description": "The promenade in Blackpool, Lancashire, England."},
        {"image_file_name": "assets/travel_images/checkerboard_forest_idaho.jpg", "description": "An aerial view of a checkerboard forest pattern in Idaho."},
        {"image_file_name": "assets/travel_images/mount_garibaldi_british_columbia.jpg", "description": "A forest on Mount Garibaldi, in Garibaldi Provincial Park, British Columbia, Canada."},
        {"image_file_name": "assets/travel_images/jedediah_smith_redwoods_california.jpg", "description": "The Simpson Reed Discovery Trail in Jedediah Smith Redwoods State Park, California."},
        {"image_file_name": "assets/travel_images/earth_from_apollo_17.jpg", "description": "A photograph of the Earth taken from Apollo 17, known as 'The Blue Marble'."},
        {"image_file_name": "assets/travel_images/white_sands_national_park_new_mexico.jpg", "description": "An aerial view of the dunefield at White Sands National Park, New Mexico."},
        {"image_file_name": "assets/travel_images/desert_iguana_mojave_desert_california.jpg", "description": "A Desert Iguana near Amboy Crater in the Mojave Desert, California."},
        {"image_file_name": "assets/travel_images/desert_pavement_mojave.jpg", "description": "Desert pavement in the Cima Volcanic Field of the Mojave Desert."},
        {"image_file_name": "assets/travel_images/gusev_crater_mars.jpg", "description": "A panoramic image of Gusev Crater on Mars, taken by the Spirit rover."},
        {"image_file_name": "assets/travel_images/marco_polo_traveling.jpg", "description": "A miniature from 'The Travels of Marco Polo' depicting Marco Polo travelling."},
        {"image_file_name": "assets/travel_images/sandstorm_al_asad_iraq.jpg", "description": "A large dust storm (haboob) over Al Asad, Iraq."},
        {"image_file_name": "assets/travel_images/ulaan_tsutgalan_waterfall_mongolia.jpg", "description": "The Ulaan Tsutgalan waterfall in Mongolia."},
        {"image_file_name": "assets/travel_images/niagara_falls_american_side.jpg", "description": "A painting of Niagara Falls from the American side by Frederic Edwin Church."},
        {"image_file_name": "assets/travel_images/ancient_coral_reefs.jpg", "description": "A photograph of ancient coral reefs."},
        {"image_file_name": "assets/travel_images/brain_coral_spawning.jpg", "description": "An image of brain coral spawning."},
        {"image_file_name": "assets/travel_images/caribbean_reef_squid.jpg", "description": "A Caribbean reef squid."},
        {"image_file_name": "assets/travel_images/coral_polyp_anatomy.jpg", "description": "A diagram showing the anatomy of a coral polyp."},
        {"image_file_name": "assets/travel_images/deep_sea_corals_wagner_seamount.jpg", "description": "A high-density deep sea coral community at Wagner Seamount."},
        {"image_file_name": "assets/travel_images/fringing_coral_reef_eilat_israel.jpg", "description": "A fringing coral reef near Eilat, Israel."},
        {"image_file_name": "assets/travel_images/table_coral_hawaii.jpg", "description": "Table coral of the genus Acropora at French Frigate Shoals, Northwestern Hawaiian Islands."},
        {"image_file_name": "assets/travel_images/fluorescent_coral_monterey_bay_aquarium.jpg", "description": "An exhibit of fluorescent coral at the Monterey Bay Aquarium in California."},
        {"image_file_name": "assets/travel_images/kurumba_island_maldives.jpg", "description": "An aerial view of Kurumba Island in the Maldives."},
        {"image_file_name": "assets/travel_images/maldives_islands.jpg", "description": "A view of the Maldives islands from an air-taxi."},
        {"image_file_name": "assets/travel_images/noaa_coral_nurseries.jpg", "description": "A NOAA coral nursery, a method of coral restoration."},
        {"image_file_name": "assets/travel_images/brain_coral.jpg", "description": "A photograph of brain coral."},
        {"image_file_name": "assets/travel_images/pillar_coral.jpg", "description": "A photograph of pillar coral."},
        {"image_file_name": "assets/travel_images/banded_cleaner_shrimp.jpg", "description": "A high-resolution image of a banded cleaner shrimp."},
        {"image_file_name": "assets/travel_images/whitetip_reef_shark_hawaii.jpg", "description": "A whitetip reef shark off the coast of the Hawaiian Islands."},
        {"image_file_name": "assets/travel_images/augustine_volcano_alaska.jpg", "description": "A gas plume rising from Augustine Volcano in Alaska."},
        {"image_file_name": "assets/travel_images/capulin_volcano_new_mexico.jpg", "description": "Capulin Volcano National Monument in New Mexico."},
        {"image_file_name": "assets/travel_images/mount_st_helens_east_dome.jpg", "description": "The east dome of Mount St. Helens in Washington."},
        {"image_file_name": "assets/travel_images/koryaksky_volcano_kamchatka_russia.jpg", "description": "Koryaksky Volcano in Petropavlovsk-Kamchatsky, Russia."},
        {"image_file_name": "assets/travel_images/litli_hrutur_eruption_iceland.jpg", "description": "The 2023 eruption of Litli-Hr\u{00fa}tur volcano in Iceland, viewed from an airplane."},
        {"image_file_name": "assets/travel_images/mount_vesuvius_italy.jpg", "description": "Mount Vesuvius in the evening, with an Araucaria heterophylla tree in the foreground."},
        {"image_file_name": "assets/travel_images/olympus_mons_mars.jpg", "description": "A composite Viking orbiter image of Olympus Mons on Mars, the tallest known volcano in the solar system."},
        {"image_file_name": "assets/travel_images/puu_oo_volcanic_cone_hawaii.jpg", "description": "Pu'u 'O'o, a volcanic cone on the Kilauea volcano in Hawaii."},
        {"image_file_name": "assets/travel_images/geikie_plateau_glacier_greenland.jpg", "description": "The Geikie Plateau glacier and mountain peaks in eastern Greenland."},
        {"image_file_name": "assets/travel_images/south_cascade_glacier_retreat.jpg", "description": "A photo showing the retreat of the South Cascade Glacier."},
        {"image_file_name": "assets/travel_images/lake_vostok_antarctica.jpg", "description": "An artist's cross-section of Lake Vostok, the largest known subglacial lake in Antarctica."},
        {"image_file_name": "assets/travel_images/glacial_moraines_lake_louise_canada.jpg", "description": "Glacial moraines above Lake Louise in Banff National Park, Alberta, Canada."},
        {"image_file_name": "assets/travel_images/glacially_plucked_granite_aland_finland.jpg", "description": "Glacially-plucked granitic bedrock near Mariehamn, \u{00c5}land, Finland."},
        {"image_file_name": "assets/travel_images/vatnajokull_glacier_iceland.jpg", "description": "A photograph of the Vatnaj\u{00f6}kull glacier in Iceland."},
        {"image_file_name": "assets/travel_images/canyonlands_national_park_utah.jpg", "description": "A view of Canyonlands National Park from the Green River Overlook in Utah."},
        {"image_file_name": "assets/travel_images/calle_loiza_san_juan_puerto_rico_hurricane_maria.jpg", "description": "Calle Lo\u{00ed}za in San Juan, Puerto Rico, after Hurricane Maria."},
        {"image_file_name": "assets/travel_images/hawaii_archipelago_satellite_view.jpg", "description": "A satellite view of the Hawaiian archipelago."},
        {"image_file_name": "assets/travel_images/temple_of_heaven_beijing_china.jpg", "description": "The Hall of Prayer for Good Harvest at the Temple of Heaven in Beijing, China."},
        {"image_file_name": "assets/travel_images/holyland_model_of_jerusalem.jpg", "description": "A close-up of the temple in the Holyland Model of Jerusalem."},
        {"image_file_name": "assets/travel_images/borobudur_indonesia.jpg", "description": "Panoramic views of the Borobudur temple in Indonesia."},
        {"image_file_name": "assets/travel_images/cathedral_of_christ_the_saviour_moscow_russia.jpg", "description": "The Cathedral of Christ the Saviour in Moscow, Russia."},
        {"image_file_name": "assets/travel_images/vellore_golden_temple_india.jpg", "description": "A full view of the Vellore Golden Temple in India."},
        {"image_file_name": "assets/travel_images/zoroastrian_temple_yazd_iran.jpg", "description": "A Zoroastrian temple in Yazd, Iran."},
        {"image_file_name": "assets/travel_images/ziggurat_of_ur_iraq.jpg", "description": "The Ziggurat of Ur in Iraq."},
        {"image_file_name": "assets/travel_images/baker_street_station_london_1906.jpg", "description": "A platform on the Baker Street and Waterloo Railway in London, during its first week of opening in 1906."},
        {"image_file_name": "assets/travel_images/first_electric_tram_berlin_1881.jpg", "description": "The world's first electric tram in Lichterfelde, near Berlin, in 1881."},
        {"image_file_name": "assets/travel_images/ganz_electric_locomotive_italy_1901.jpg", "description": "A prototype of a Ganz AC electric locomotive in Valtellina, Italy, in 1901."},
        {"image_file_name": "assets/travel_images/lucerne_train_station_switzerland.jpg", "description": "A goods station and marshalling yard in Lucerne, Switzerland."},
        {"image_file_name": "assets/travel_images/cruise_ship_bridge.jpg", "description": "The bridge of a modern cruise ship."},
        {"image_file_name": "assets/travel_images/po_liner_strathaird_fremantle.jpg", "description": "The P&O liner Strathaird at Fremantle Harbour."},
        {"image_file_name": "assets/travel_images/cruise_ship_casino.jpg", "description": "The casino on the cruise ship Norwegian Bliss."},
        {"image_file_name": "assets/travel_images/cruise_ship_luggage.jpg", "description": "Luggage being loaded onto a cruise ship."},
        {"image_file_name": "assets/travel_images/cruise_ship_medical_area.jpg", "description": "The medical intake area on a cruise ship."},
        {"image_file_name": "assets/travel_images/hapag_steamship_prinzessin_victoria_luise.jpg", "description": "The HAPAG steamship Prinzessin Victoria Luise."},
        {"image_file_name": "assets/travel_images/island_princess_cruise_ship.jpg", "description": "The Island Princess cruise ship."},
        {"image_file_name": "assets/travel_images/lumiere_brothers_cinematographe_poster.jpg", "description": "A poster for the Lumi\u{00e8}re brothers' cinematographe."},
        {"image_file_name": "assets/travel_images/conseil_detat_paris.jpg", "description": "The French Conseil d'\u{00c9}tat (Council of State) in Paris."},
        {"image_file_name": "assets/travel_images/les_deux_magots_cafe_paris.jpg", "description": "The Caf\u{00e9} 'Les Deux Magots' in Paris."},
        {"image_file_name": "assets/travel_images/eiffel_tower_construction_1888.jpg", "description": "The Eiffel Tower under construction in 1888."},
        {"image_file_name": "assets/travel_images/palais_de_la_cite_paris.jpg", "description": "A detail from the Tr\u{00e8}s Riches Heures du Duc de Berry, showing the Palais de la Cit\u{00e9} in Paris."},
        {"image_file_name": "assets/travel_images/paris_19th_arrondissement.jpg", "description": "A residential area in the 19th arrondissement of Paris."},
        {"image_file_name": "assets/travel_images/le_moulin_de_la_galette_renoir.jpg", "description": "The painting 'Bal du moulin de la Galette' by Pierre-Auguste Renoir."},
        {"image_file_name": "assets/travel_images/map_of_paris_1657.jpg", "description": "A map of Paris from 1657."},
        {"image_file_name": "assets/travel_images/fontana_della_barcaccia_rome.jpg", "description": "The Fontana della Barcaccia at the foot of the Spanish Steps in Rome."},
        {"image_file_name": "assets/travel_images/st_peters_basilica_rome.jpg", "description": "St. Peter's Basilica in Rome, seen from Castel Sant'Angelo."},
        {"image_file_name": "assets/travel_images/trajans_market_rome.jpg", "description": "A view of Trajan's Market in Rome."},
        {"image_file_name": "assets/travel_images/piazza_navona_rome.jpg", "description": "A view of the Piazza Navona in Rome."},
        {"image_file_name": "assets/travel_images/abbey_road_studios_london.jpg", "description": "Abbey Road Studios in London."},
        {"image_file_name": "assets/travel_images/comptons_of_soho_london.jpg", "description": "Comptons of Soho on Old Compton Street in London."},
        {"image_file_name": "assets/travel_images/st_pauls_cathedral_london.jpg", "description": "St. Paul's Cathedral in London in the evening."},
        {"image_file_name": "assets/travel_images/kensington_museums_london_aerial.jpg", "description": "An aerial photograph of the Kensington Museums area in London."},
        {"image_file_name": "assets/travel_images/bank_of_england_london.jpg", "description": "The Bank of England in Threadneedle Street, London."},
        {"image_file_name": "assets/travel_images/paternoster_square_london.jpg", "description": "A view of Paternoster Square in London from St. Paul's Cathedral."},
        {"image_file_name": "assets/travel_images/westminster_abbey_canaletto_1749.jpg", "description": "A painting of Westminster Abbey by Canaletto from 1749."},
        {"image_file_name": "assets/travel_images/edo_panorama_tokyo.jpg", "description": "A color photochrom print of a panorama of Edo (now Tokyo), Japan."},
        {"image_file_name": "assets/travel_images/suruga_street_edo_hiroshige.jpg", "description": "The 'Suruga Street' print from the series 'One Hundred Famous Views of Edo' by Utagawa Hiroshige."},
        {"image_file_name": "assets/travel_images/fushimi_yagura_imperial_palace_tokyo.jpg", "description": "The Fushimi Yagura, a watchtower at the Imperial Palace in Tokyo."},
        {"image_file_name": "assets/travel_images/map_of_izu_islands_japan.jpg", "description": "A map of the Izu Islands in Japan."},
        {"image_file_name": "assets/travel_images/shofuku_ji_temple_tokyo.jpg", "description": "The Jiz\u{014d}-d\u{014d} hall of Sh\u{014d}fuku-ji, a Buddhist temple in Higashimurayama, Tokyo."},
        {"image_file_name": "assets/travel_images/crowded_tram_tokyo.jpg", "description": "A colorized postcard showing a crowded tram in Tokyo."},
        {"image_file_name": "assets/travel_images/kinkaku_ji_golden_pavilion_kyoto.jpg", "description": "The Kinkaku (Golden Pavilion) at Rokuon-ji temple in Kyoto, Japan."},
        {"image_file_name": "assets/travel_images/kyoto_view_from_kiyomizu_dera_1870s.jpg", "description": "A view of Kyoto from Kiyomizu-dera temple in the 1870s."},
        {"image_file_name": "assets/travel_images/kyoto_subway.jpg", "description": "A Kyoto subway 20 series train at Takeda station."},
        {"image_file_name": "assets/travel_images/kyoto_railway_map.jpg", "description": "A railway map of the area around Kyoto City."},
        {"image_file_name": "assets/travel_images/sanjusangendo_temple_kyoto.jpg", "description": "The Sanjusangend\u{014d} temple in Kyoto, during the Toshiya festival."},
        {"image_file_name": "assets/travel_images/shijo_kawaramachi_kyoto.jpg", "description": "A street scene in the Shij\u{014d} Kawaramachi area of Kyoto."},
        {"image_file_name": "assets/travel_images/view_of_fort_george_new_york.jpg", "description": "A view of Fort George (Fort Amsterdam) with the city of New York from the Southwest."},
        {"image_file_name": "assets/travel_images/temple_emanu_el_new_york.jpg", "description": "Temple Emanu-El in New York City."},
        {"image_file_name": "assets/travel_images/statue_of_liberty_new_york.jpg", "description": "The Statue of Liberty in New York City."},
        {"image_file_name": "assets/travel_images/view_of_new_amsterdam_1664.jpg", "description": "An early picture of New Amsterdam (now New York) made in 1664 by Johannes Vingboons."},
        {"image_file_name": "assets/travel_images/broadway_new_york_1840.jpg", "description": "A painting of Broadway in New York City in 1840."},
        {"image_file_name": "assets/travel_images/islamic_cultural_center_new_york.jpg", "description": "The Islamic Cultural Center on East 96th Street in Manhattan, New York City."},
        {"image_file_name": "assets/travel_images/lincoln_tunnel_manhattan.jpg", "description": "The Lincoln Tunnel portal in Manhattan, New York City."},
        {"image_file_name": "assets/travel_images/brooklyn_bridge_new_york.jpg", "description": "The Brooklyn Bridge in New York City."},
        {"image_file_name": "assets/travel_images/map_of_new_amsterdam_1660.jpg", "description": "The Castello Plan, a map of New Amsterdam (Manhattan) in 1660."},
        {"image_file_name": "assets/travel_images/unisphere_corona_park_new_york.jpg", "description": "The Unisphere in Flushing Meadows\u{2013}Corona Park, Queens, New York City."},
        {"image_file_name": "assets/travel_images/mulberry_street_new_york_1900.jpg", "description": "Mulberry Street in New York City, circa 1900."},
        {"image_file_name": "assets/travel_images/worker_empire_state_building_new_york.jpg", "description": "A structural worker on the framework of the Empire State Building in New York City."},
        {"image_file_name": "assets/travel_images/bali_memorial.jpg", "description": "The Bali memorial."},
        {"image_file_name": "assets/travel_images/nyepi_festival_bali.jpg", "description": "The Nyepi festival, the Balinese New Year."},
        {"image_file_name": "assets/travel_images/kata_noi_beach_phuket_thailand.jpg", "description": "Kata Noi Beach in Phuket, Thailand."},
        {"image_file_name": "assets/travel_images/phuket_thailand.jpg", "description": "A photograph of Phuket, Thailand."},
        {"image_file_name": "assets/travel_images/promthep_cape_phuket_thailand.jpg", "description": "Promthep Cape in Phuket, Thailand."},
        {"image_file_name": "assets/travel_images/crab_on_beach_phuket_thailand.jpg", "description": "A small crab on a sand beach in Phuket, Thailand."},
        {"image_file_name": "assets/travel_images/george_street_sydney.jpg", "description": "A view looking north along George Street in Sydney, with a tram, a T-model Ford, and a hansom cab."},
        {"image_file_name": "assets/travel_images/state_theatre_sydney.jpg", "description": "The main atrium of the State Theatre in Sydney."},
        {"image_file_name": "assets/travel_images/sydney_at_night_satellite.jpg", "description": "A satellite image of the Greater Sydney Area at night."},
        {"image_file_name": "assets/travel_images/circular_quay_sydney_1938.jpg", "description": "A night view of Circular Quay in Sydney in 1938."},
        {"image_file_name": "assets/travel_images/sydney_cove_1888.jpg", "description": "A bird's-eye view of Sydney Cove and its surrounds in 1888."},
        {"image_file_name": "assets/travel_images/sydney_harbour_bridge_1932.jpg", "description": "Sydney and the Sydney Harbour Bridge, taken from the North Shore in 1932."},
        {"image_file_name": "assets/travel_images/sydney_olympic_park.jpg", "description": "A panorama of Sydney Olympic Park."},
        {"image_file_name": "assets/travel_images/sydney_cove_watling_1794.jpg", "description": "A watercolour painting of Sydney Cove by Thomas Watling, from 1794-1796."},
        {"image_file_name": "assets/travel_images/queenstown_new_zealand.jpg", "description": "A photograph of Queenstown, New Zealand."},
        {"image_file_name": "assets/travel_images/queenstown_new_zealand_2.jpg", "description": "A photograph of Queenstown, New Zealand."},
        {"image_file_name": "assets/travel_images/akrotiri_spring_fresco_santorini.jpg", "description": "The spring fresco room in Akrotiri, Santorini, Greece."},
        {"image_file_name": "assets/travel_images/santorini_from_space.jpg", "description": "A photograph of the island of Santorini, Greece, taken from the International Space Station."},
        {"image_file_name": "assets/travel_images/saffron_gatherers_fresco_santorini.jpg", "description": "A fresco of saffron gatherers from the Bronze Age excavations in Akrotiri, on the island of Santorini."},
        {"image_file_name": "assets/travel_images/fira_santorini_1919.jpg", "description": "A photograph of the ladder-like path in Fira, Santorini, from 1919."},
        {"image_file_name": "assets/travel_images/santorini_panorama.jpg", "description": "A partial panorama of Santorini and the Thera caldera."},
        {"image_file_name": "assets/travel_images/santorini_satellite_image.jpg", "description": "An ASTER satellite image of the island of Santorini, Greece."},
        {"image_file_name": "assets/travel_images/lahaina_maui_wildfire_damage.jpg", "description": "Damage in Lahaina, Maui, after the 2023 wildfires."},
        {"image_file_name": "assets/travel_images/machu_picchu_sacred_plaza.jpg", "description": "A general view of the Sacred Plaza at Machu Picchu."},
        {"image_file_name": "assets/travel_images/hiram_bingham_machu_picchu_1912.jpg", "description": "A photograph of Hiram Bingham III at his tent near Machu Picchu in 1912."},
        {"image_file_name": "assets/travel_images/machu_picchu_urubamba_canyon.jpg", "description": "A view of Machu Picchu and the Urubamba Canyon."},
        {"image_file_name": "assets/travel_images/intihuatana_stone_machu_picchu.jpg", "description": "The Intihuatana stone at Machu Picchu."},
        {"image_file_name": "assets/travel_images/room_of_the_three_windows_machu_picchu.jpg", "description": "The Room of the Three Windows at Machu Picchu."},
        {"image_file_name": "assets/travel_images/barcelona_sants_station.jpg", "description": "The Sants railway station and Barcel\u{00f3} Sants Hotel in Barcelona."},
        {"image_file_name": "assets/travel_images/macba_barcelona.jpg", "description": "The Barcelona Museum of Contemporary Art (MACBA)."},
        {"image_file_name": "assets/travel_images/circuit_de_catalunya_f1.jpg", "description": "The grandstand at the Circuit de Barcelona-Catalunya."},
        {"image_file_name": "assets/travel_images/torre_glories_barcelona.jpg", "description": "The Torre Gl\u{00f2}ries in Barcelona."},
        {"image_file_name": "assets/travel_images/barcelona_drawing_1563.jpg", "description": "A drawing of Barcelona from 1563 by Antony van den Wyngaerde."},
        {"image_file_name": "assets/travel_images/amsterdam_gay_pride_2013.jpg", "description": "A boat at the Amsterdam Gay Pride parade in 2013."},
        {"image_file_name": "assets/travel_images/magere_brug_amsterdam.jpg", "description": "The Magere Brug (Skinny Bridge) in Amsterdam."},
        {"image_file_name": "assets/travel_images/dam_square_amsterdam.jpg", "description": "A photochrom print of Dam Square in Amsterdam."},
        {"image_file_name": "assets/travel_images/san_marco_basin_venice.jpg", "description": "A view of the San Marco Basin in Venice by Gaspar van Wittel."},
        {"image_file_name": "assets/travel_images/venice_panorama_1870s.jpg", "description": "A panorama of Venice from the 1870s."},
        {"image_file_name": "assets/travel_images/venice_from_space.jpg", "description": "A photograph of Venice taken from the International Space Station."},
        {"image_file_name": "assets/travel_images/piazzetta_san_marco_venice.jpg", "description": "The Piazzetta San Marco in Venice at dawn."},
        {"image_file_name": "assets/travel_images/venice_shop_window.jpg", "description": "A shop window in Venice."},
        {"image_file_name": "assets/travel_images/carioca_aqueduct_rio_de_janeiro.jpg", "description": "The Carioca Aqueduct in Rio de Janeiro."},
        {"image_file_name": "assets/travel_images/anchieta_neighborhood_rio_de_janeiro.jpg", "description": "The Anchieta neighborhood in the north zone of Rio de Janeiro."},
        {"image_file_name": "assets/travel_images/downtown_rio_de_janeiro.jpg", "description": "Downtown Rio de Janeiro."},
        {"image_file_name": "assets/travel_images/rio_de_janeiro_from_space.jpg", "description": "The city lights of Rio de Janeiro, Brazil, seen from the International Space Station."},
        {"image_file_name": "assets/travel_images/linha_vermelha_rio_de_janeiro.jpg", "description": "The Linha Vermelha (Red Line) expressway in Rio de Janeiro."},
        {"image_file_name": "assets/travel_images/morro_do_borel_rio_de_janeiro.jpg", "description": "The Morro do Borel favela in Tijuca, Rio de Janeiro."},
        {"image_file_name": "assets/travel_images/botafogo_bay_rio_de_janeiro.jpg", "description": "A painting of Botafogo Bay in Rio de Janeiro by Nicola Antonio Facchinetti."},
        {"image_file_name": "assets/travel_images/rio_de_janeiro.jpg", "description": "A photograph of Rio de Janeiro."},
        {"image_file_name": "assets/travel_images/rio_de_janeiro_avenue_1910s.jpg", "description": "The leading avenue of Rio de Janeiro in the 1910s."},
        {"image_file_name": "assets/travel_images/rio_de_janeiro_1889.jpg", "description": "A photograph of the city of Rio de Janeiro in 1889."},
        {"image_file_name": "assets/travel_images/al_fahidi_fort_dubai.jpg", "description": "Al Fahidi Fort in Dubai in the late 1950s."},
        {"image_file_name": "assets/travel_images/dubai_artificial_archipelagos_from_space.jpg", "description": "The artificial archipelagos of Dubai, United Arab Emirates, seen from the International Space Station."},
        {"image_file_name": "assets/travel_images/dubai_uae.jpg", "description": "A photograph of Dubai, United Arab Emirates."},
        {"image_file_name": "assets/travel_images/dubai_creek_1964.jpg", "description": "Dubai Creek in 1964."},
        {"image_file_name": "assets/travel_images/dubai_future_forum_2024.jpg", "description": "The interior of the Dubai Future Forum 2024."},
        {"image_file_name": "assets/travel_images/dubai_fountain.jpg", "description": "The Dubai Fountain during a show."},
        {"image_file_name": "assets/travel_images/museum_of_the_future_dubai.jpg", "description": "The Museum of the Future in Dubai."},
        {"image_file_name": "assets/travel_images/banff_from_sulphur_mountain.jpg", "description": "The town of Banff, Alberta, Canada, photographed from the top of Sulphur Mountain."},
        {"image_file_name": "assets/travel_images/banff_springs_hotel_1902.jpg", "description": "The Banff Springs Hotel in 1902."},
        {"image_file_name": "assets/travel_images/canadian_pacific_railway_banff_ad.jpg", "description": "A Canadian Pacific Railway brochure advertisement for Banff, featuring Mount Assiniboine."},
        {"image_file_name": "assets/travel_images/gray_wolf.jpg", "description": "A gray wolf."},
        {"image_file_name": "assets/travel_images/fairmont_chateau_lake_louise.jpg", "description": "The Fairmont Chateau Hotel at Lake Louise in Banff National Park."},
        {"image_file_name": "assets/travel_images/moraine_lake_banff.jpg", "description": "The Valley of the Ten Peaks and Moraine Lake in Banff National Park."}
    ]
    """

    /// System prompt aligned with Flutter `travel_planner_page.dart`.
    /// This is an exact copy of the `prompt` list from Flutter's
    /// `_TravelPlannerPageState`, minus the `PromptFragments` calls
    /// which are added separately in `systemInstruction()`.
    static let systemPrompt = """
# Instructions

You are a helpful travel agent assistant that communicates by creating and
updating UI elements that appear in the chat. Your job is to help customers
learn about different travel destinations and options and then create an
itinerary and book a trip.

## Conversation flow

Conversations with travel agents should follow a rough flow. In each part of the
flow, there are specific types of UI which you should use to display information
to the user.

1.  Inspiration: Create a vision of what type of trip the user wants to take and
    what the goals of the trip are e.g. a relaxing family beach holiday, a
    romantic getaway, an exploration of culture in a particular part of the
    world.

    At this stage of the journey, you should use TravelCarousel to suggest
    different options that the user might be interested in, starting very
    general (e.g. "Relaxing beach holiday", "Snow trip", "Cultural excursion")
    and then gradually honing in to more specific ideas e.g. "A journey through
    the best art galleries of Europe").

2.  Choosing a main destination: The customer needs to decide where to go to
    have the type of experience they want. This might be general to start off,
    e.g. "South East Asia" or more specific e.g. "Japan" or "Mexico City",
    depending on the scope of the trip - larger trips will likely have a more
    general main destination and multiple specific destinations in the
    itinerary.

    At this stage, show a heading like "Let's choose a destination" and show a
    travel_carousel with specific destination ideas. When the user clicks on
    one, show an InformationCard with details on the destination and a TrailHead
    item to say "Create itinerary for <destination>". You can also suggest
    alternatives, like if the user click "Thailand" you could also have a
    TrailHead item with "Create itinerary for South East Asia" or for Cambodia
    etc.

3.  Create an initial itinerary, which will be iterated over in subsequent
    steps. This involves planning out each day of the trip, including the
    specific locations and draft activities. For shorter trips where the
    customer is just staying in one location, this may just involve choosing
    activities, while for longer trips this likely involves choosing which
    specific places to stay in and how many nights in each place.

    At this step, you should first show an inputGroup which contains several
    input chips like the number of people, the destination, the length of time,
    the budget, preferred activity types etc.

    Then, when the user clicks search, you should update the surface to have a
    Column with the existing inputGroup, an itineraryWithDetails. When creating
    the itinerary, include all necessary `itineraryEntry` items for hotels and
    transport with generic details and a status of `choiceRequired`.

    During this step, the user may change their search parameters and resubmit,
    in which case you should regenerate the itinerary to match their desires,
    updating the existing surface.

4.  Booking: Booking each part of the itinerary one step at a time. This
    involves booking every accommodation, transport and activity in the
    itinerary one step at a time.

    Here, you should just focus on one item at a time, using an `inputGroup`
    with chips to ask the user for preferences, and the `travelCarousel` to show
    the user different options. When the user chooses an option, you can confirm
    it has been chosen and immediately prompt the user to book the next detail,
    e.g. an activity, hotels, transport etc. When a booking is confirmed, update
    the original `itineraryWithDetails` to reflect the booking by updating the
    relevant `itineraryEntry` to have the status `chosen` and including the
    booking details in the `bodyText`.

    When booking a hotel, use inputGroup, providing initial values for check-in
    and check-out dates (nearest weekend). Then use the `listHotels` tool to
    search for hotels and pass the values with their `listingSelectionId` to a
    `travelCarousel` to show the user different options. When user selects a
    hotel, pass the `listingSelectionId` of the selected hotel the parameter
    `listingSelectionIds` of `listingsBooker`.

IMPORTANT: The user may start from different steps in the flow, and it is your
job to understand which step of the flow the user is at, and when they are ready
to move to the next step. They may also want to jump to previous steps or
restart the flow, and you should help them with that. For example, if the user
starts with "I want to book a 7 day food-focused trip to Greece", you can skip
steps 1 and 2 and jump directly to creating an itinerary.

### Side journeys

Within the flow, users may also take side journeys. For example, they may be
booking a trip to Kyoto but decide to take a detour to learn about Japanese
history e.g. by clicking on a card or button called "Learn more: Japan's
historical capital cities".

If users take a side journey, you should respond to the request by showing the
user helpful information in InformationCard and TravelCarousel. Always add new
surfaces when doing this and do not update or delete existing ones. That way,
the user can return to the main booking flow once they have done some research.

## Updating UI

Update surfaces to modify existing UI, for example to add items to an itinerary.

## Images

If you need to use any images, find the most relevant ones from the following
list of asset images:

\(assetImages)

- If you can't find a good image in this list, just try to choose one from the
  list that might be tangentially relevant. DO NOT USE ANY IMAGES NOT IN THE
  LIST. It is fine if the image is unrelated, as long as it is from the list.

- Image location always should be an asset path (e.g. assets/...).

## Example

Here is an example of creating a trip planner UI.

```json
{
  "createSurface": {
    "surfaceId": "mexico_trip_planner",
    "catalogId": "https://a2ui.org/specification/v0_9/standard_catalog.json",
    "sendDataModel": true
  }
}
```

```json
{
  "updateComponents": {
    "surfaceId": "mexico_trip_planner",
    "components": [
      {
        "id": "root",
        "component": "Column",
        "children": ["trip_title", "itinerary"]
      },
      {
        "id": "trip_title",
        "component": "Text",
        "text": "Trip to Mexico City",
        "variant": "h2"
      },
      {
        "id": "itinerary",
        "component": "ItineraryWithDetails",
        "title": "Mexico City Adventure",
        "subheading": "3-day Itinerary",
        "imageChildId": "mexico_city_image",
        "child": "itinerary_details"
      },
      {
        "id": "mexico_city_image",
        "component": "Image",
        "url": "assets/travel_images/mexico_city.jpg",
        "variant": "mediumFeature"
      },
      {
        "id": "itinerary_details",
        "component": "Column",
        "children": ["day1"]
      },
      {
        "id": "day1",
        "component": "ItineraryDay",
        "title": "Day 1",
        "subtitle": "Arrival and Exploration",
        "description": "Your first day in Mexico City...",
        "imageChildId": "day1_image",
        "children": ["day1_entry1"]
      },
      {
        "id": "day1_image",
        "component": "Image",
        "url": "assets/travel_images/mexico_city.jpg",
        "variant": "mediumFeature"
      },
      {
        "id": "day1_entry1",
        "component": "ItineraryEntry",
        "type": "transport",
        "title": "Arrival at MEX Airport",
        "time": "2:00 PM",
        "bodyText": "Arrive at Mexico City...",
        "status": "noBookingRequired"
      }
    ]
  }
}
```

When updating or showing UIs, **ALWAYS** use the JSON messages as described above. Prefer to collect and show information by creating a UI for it.
"""

    /// Matches Flutter's `PromptFragments.uiGenerationRestriction(prefix: 'IMPORTANT: ')`.
    private static let uiGenerationRestriction =
        "IMPORTANT: Do not use tools or function calls for UI generation. " +
        "Use JSON text blocks.\n" +
        "Ensure all JSON is valid and fenced with ```json ... ```."

    /// Matches Flutter's `SurfaceOperations.createAndUpdate(dataModel: true).systemPromptFragments`.
    /// Generated by `SurfaceOperations._controllingUI` in `prompt_builder.dart`.
    private static let controllingTheUI = """
-----CONTROLLING_THE_UI_START-----
You can control the UI by outputting valid A2UI JSON messages wrapped in markdown code blocks.

Supported messages are: `createSurface`, `updateComponents`, `updateDataModel`.

- `createSurface`: Creates a new surface.
- `updateComponents`: Updates components in a surface.
- `updateDataModel`: Updates the data model.

Properties:

- `createSurface`: Requires `surfaceId` (you must always use a unique ID for each created surface), `catalogId` (use the catalog ID provided in system instructions), and `sendDataModel: true`.
- `updateComponents`: Requires `surfaceId` and a list of `components`. One component MUST have `id: "root"`.
- `updateDataModel`: Requires `surfaceId`, `path` and `value`.

To create a new UI:
1. Output a `createSurface` message with a unique `surfaceId` and `catalogId` (use the catalog ID provided in system instructions).
2. Output an `updateComponents` message with the `surfaceId` and the component definitions.

To update an existing UI:
1. Output an `updateComponents` message with the existing `surfaceId` and the new component definitions.
-----CONTROLLING_THE_UI_END-----
"""

    /// Matches Flutter's `SurfaceOperations.systemPromptFragments` output format section.
    private static let outputFormat = """
-----OUTPUT_FORMAT_START-----
When constructing UI, you must output a VALID A2UI JSON object representing one of the A2UI message types (`createSurface`, `updateComponents`, `updateDataModel`).
- You can treat the A2UI schema as a specification for the JSON you typically output.
- You may include a brief conversational explanation before or after the JSON block if it helps the user, but the JSON block must be valid and complete.
- Ensure your JSON is fenced with ```json and ```.
-----OUTPUT_FORMAT_END-----
"""

    // MARK: - A2UI Message Schema (matching Flutter's ServerToClientMessage.ServerToClientMessageSchema output)

    /// Generates the full A2UI Message Schema JSON string matching Flutter's
    /// `ServerToClientMessage.ServerToClientMessageSchema(catalog).toJson(indent: '  ')` output.
    /// This is the proper JSON Schema format that Gemini needs to understand
    /// the available components and their properties.
    static var catalogSchema: String {
        // Helper: action schema (event-based)
        let actionSchema: [String: Any] = [
            "oneOf": [
                [
                    "type": "object",
                    "properties": [
                        "event": [
                            "type": "object",
                            "properties": [
                                "name": [
                                    "type": "string",
                                    "description": "The name of the action to be dispatched to the server."
                                ],
                                "context": [
                                    "type": "object",
                                    "description": "Arbitrary context data to send with the action.",
                                    "additionalProperties": true
                                ]
                            ],
                            "required": ["name"]
                        ]
                    ],
                    "required": ["event"]
                ]
            ]
        ]

        // Helper: string reference (literal or data-binding)
        func stringRef(_ desc: String, enumValues: [String]? = nil) -> [String: Any] {
            var literal: [String: Any] = ["type": "string", "description": "A literal string value."]
            if let enumValues { literal["enum"] = enumValues }
            return [
                "description": desc,
                "oneOf": [
                    literal,
                    [
                        "type": "object",
                        "description": "A path to a string.",
                        "properties": ["path": ["type": "string", "description": "A relative or absolute path in the data model."]],
                        "required": ["path"]
                    ]
                ]
            ]
        }

        // Helper: component reference (just a string ID)
        func compRef(_ desc: String) -> [String: Any] {
            return ["type": "string", "description": desc]
        }

        // Helper: component array reference (list of IDs or template)
        func compArrayRef(_ desc: String) -> [String: Any] {
            return [
                "description": desc,
                "oneOf": [
                    ["type": "array", "items": ["type": "string", "description": "Component ID"]],
                    [
                        "type": "object",
                        "properties": [
                            "componentId": ["type": "string", "description": "The ID of a component."],
                            "path": ["type": "string", "description": "A relative or absolute path in the data model."]
                        ],
                        "required": ["componentId", "path"]
                    ]
                ]
            ]
        }

        // --- Component schemas (each with "component" discriminator) ---

        let buttonSchema: [String: Any] = [
            "type": "object",
            "description": "An interactive button that triggers an action when pressed.",
            "properties": [
                "component": ["type": "string", "enum": ["Button"]],
                "child": compRef("ID of child widget (e.g., Text)."),
                "action": actionSchema,
                "variant": ["type": "string", "description": "Button style hint.", "enum": ["primary", "borderless"]]
            ],
            "required": ["component", "child", "action"]
        ]

        let columnSchema: [String: Any] = [
            "type": "object",
            "description": "A layout widget that arranges its children vertically.",
            "properties": [
                "component": ["type": "string", "enum": ["Column"]],
                "justify": ["type": "string", "description": "Main axis alignment.", "enum": ["start", "center", "end", "spaceBetween", "spaceAround", "spaceEvenly", "stretch"]],
                "align": ["type": "string", "description": "Cross axis alignment.", "enum": ["start", "center", "end", "stretch"]],
                "children": compArrayRef("List of widget IDs or template with data binding.")
            ],
            "required": ["component", "children"]
        ]

        let textSchema: [String: Any] = [
            "type": "object",
            "description": "A block of styled text.",
            "properties": [
                "component": ["type": "string", "enum": ["Text"]],
                "text": stringRef("Text content (markdown supported, but prefer UI components)."),
                "variant": ["type": "string", "description": "Base text style hint.", "enum": ["h1", "h2", "h3", "h4", "h5", "caption", "body"]]
            ],
            "required": ["component", "text"]
        ]

        let imageSchema: [String: Any] = [
            "type": "object",
            "description": "A UI element for displaying image data from URL or asset.",
            "properties": [
                "component": ["type": "string", "enum": ["Image"]],
                "url": stringRef("Asset path (assets/...) or network URL (https://...)."),
                "fit": ["type": "string", "description": "How image inscribed into box.", "enum": ["contain", "cover", "fill", "fitWidth", "fitHeight", "none", "scaleDown"]],
                "variant": ["type": "string", "description": "Size/style hint.", "enum": ["icon", "avatar", "smallFeature", "mediumFeature", "largeFeature", "header"]]
            ],
            "required": ["component"]
        ]

        let travelCarouselSchema: [String: Any] = [
            "type": "object",
            "description": "A horizontal carousel of travel items with images and actions.",
            "properties": [
                "component": ["type": "string", "enum": ["TravelCarousel"]],
                "title": stringRef("Optional title above carousel."),
                "items": [
                    "type": "array",
                    "description": "List of carousel items.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "description": stringRef("Short description (e.g., \"The Dart Inn in Sunnyvale, CA for $150\")."),
                            "imageChildId": compRef("ID of Image widget for this item."),
                            "listingSelectionId": ["type": "string", "description": "Optional ID of listing."],
                            "action": actionSchema
                        ],
                        "required": ["description", "imageChildId", "action"]
                    ]
                ]
            ],
            "required": ["component", "items"]
        ]

        let informationCardSchema: [String: Any] = [
            "type": "object",
            "description": "A card displaying information about a destination or topic.",
            "properties": [
                "component": ["type": "string", "enum": ["InformationCard"]],
                "imageChildId": ["type": "string", "description": "ID of Image widget at top of card."],
                "title": stringRef("The title of the card."),
                "subtitle": stringRef("The subtitle."),
                "body": stringRef("Body text (supports markdown).")
            ],
            "required": ["component", "title", "body"]
        ]

        let itinerarySchema: [String: Any] = [
            "type": "object",
            "description": "Widget to show an itinerary or a plan for travel.",
            "properties": [
                "component": ["type": "string", "enum": ["Itinerary"]],
                "title": stringRef("The title of the itinerary."),
                "subheading": stringRef("The subheading."),
                "imageChildId": compRef("ID of Image widget for the itinerary header."),
                "days": [
                    "type": "array",
                    "description": "A list of days in the itinerary.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": stringRef("e.g., \"Day 1\"."),
                            "subtitle": stringRef("e.g., \"Arrival in Tokyo\"."),
                            "description": stringRef("Short description (markdown)."),
                            "imageChildId": compRef("ID of Image widget."),
                            "entries": [
                                "type": "array",
                                "description": "A list of itinerary entries for this day.",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "title": stringRef("The title."),
                                        "subtitle": stringRef("The subtitle."),
                                        "bodyText": stringRef("Body text (markdown)."),
                                        "address": stringRef("The address."),
                                        "time": stringRef("Time (formatted string)."),
                                        "totalCost": stringRef("Total cost."),
                                        "type": ["type": "string", "description": "Type of entry.", "enum": ["accommodation", "transport", "activity"]],
                                        "status": ["type": "string", "description": "Booking status.", "enum": ["noBookingRequired", "choiceRequired", "chosen"]],
                                        "choiceRequiredAction": actionSchema
                                    ],
                                    "required": ["title", "bodyText", "time", "type", "status"]
                                ]
                            ]
                        ],
                        "required": ["title", "subtitle", "description", "imageChildId", "entries"]
                    ]
                ]
            ],
            "required": ["component", "title", "subheading", "imageChildId", "days"]
        ]

        let inputGroupSchema: [String: Any] = [
            "type": "object",
            "description": "A group of input chips with a submit button.",
            "properties": [
                "component": ["type": "string", "enum": ["InputGroup"]],
                "submitLabel": stringRef("Label for submit button."),
                "children": ["type": "array", "description": "Widget IDs for input children (e.g., OptionsFilterChipInput).", "items": ["type": "string"]],
                "action": actionSchema
            ],
            "required": ["component", "submitLabel", "children", "action"]
        ]

        let optionsFilterChipSchema: [String: Any] = [
            "type": "object",
            "description": "Chip for mutually exclusive options. Must be inside InputGroup.",
            "properties": [
                "component": ["type": "string", "enum": ["OptionsFilterChipInput"]],
                "chipLabel": ["type": "string", "description": "Title (e.g., \"budget\", \"activity type\")."],
                "options": ["type": "array", "description": "List of options (at least three).", "items": ["type": "string"]],
                "iconName": ["type": "string", "description": "Icon to display.", "enum": ["location", "hotel", "restaurant", "airport", "train", "car", "date", "time", "calendar", "people", "person", "family", "wallet", "receipt"]],
                "value": stringRef("Initially selected option name.")
            ],
            "required": ["component", "chipLabel", "options"]
        ]

        let checkboxFilterChipSchema: [String: Any] = [
            "type": "object",
            "description": "Chip where more than one option can be chosen. Must be inside InputGroup.",
            "properties": [
                "component": ["type": "string", "enum": ["CheckboxFilterChipsInput"]],
                "chipLabel": ["type": "string", "description": "Title (e.g., \"amenities\", \"dietary restrictions\")."],
                "options": ["type": "array", "description": "List of options.", "items": ["type": "string"]],
                "iconName": ["type": "string", "description": "Icon to display.", "enum": ["location", "hotel", "restaurant", "airport", "train", "car", "date", "time", "calendar", "people", "person", "family", "wallet", "receipt"]],
                "selectedOptions": ["type": "array", "description": "Initially selected option names.", "items": ["type": "string"]]
            ],
            "required": ["component", "chipLabel", "options", "selectedOptions"]
        ]

        let dateInputChipSchema: [String: Any] = [
            "type": "object",
            "description": "A date picker chip. Must be inside InputGroup.",
            "properties": [
                "component": ["type": "string", "enum": ["DateInputChip"]],
                "value": stringRef("Initial date in yyyy-mm-dd format."),
                "label": ["type": "string", "description": "Label for date picker."]
            ],
            "required": ["component"]
        ]

        let textInputChipSchema: [String: Any] = [
            "type": "object",
            "description": "Input chip for free text, e.g., to select destination. Inside InputGroup only.",
            "properties": [
                "component": ["type": "string", "enum": ["TextInputChip"]],
                "label": ["type": "string", "description": "Label for text input chip."],
                "value": stringRef("Initial value."),
                "obscured": ["type": "boolean", "description": "Whether text obscured (passwords)."]
            ],
            "required": ["component", "label"]
        ]

        let trailheadSchema: [String: Any] = [
            "type": "object",
            "description": "A set of topic chips the user can tap to explore. Use for suggestions.",
            "properties": [
                "component": ["type": "string", "enum": ["Trailhead"]],
                "topics": [
                    "type": "array",
                    "description": "List of topics to display as chips.",
                    "items": stringRef("A topic to explore.")
                ],
                "action": actionSchema
            ],
            "required": ["component", "topics", "action"]
        ]

        let listingsBookerSchema: [String: Any] = [
            "type": "object",
            "description": "A widget to select among a set of listings.",
            "properties": [
                "component": ["type": "string", "enum": ["ListingsBooker"]],
                "listingSelectionIds": ["type": "array", "description": "Listings to select among.", "items": ["type": "string"]],
                "itineraryName": stringRef("The name of the itinerary."),
                "modifyAction": actionSchema
            ],
            "required": ["component", "listingSelectionIds"]
        ]

        let tabbedSectionsSchema: [String: Any] = [
            "type": "object",
            "description": "A tabbed sections widget.",
            "properties": [
                "component": ["type": "string", "enum": ["TabbedSections"]],
                "sections": [
                    "type": "array",
                    "description": "List of sections to display as tabs.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": stringRef("Title of the tab."),
                            "child": compRef("ID of child widget for content.")
                        ],
                        "required": ["child", "title"]
                    ]
                ]
            ],
            "required": ["component", "sections"]
        ]

        // Assemble the full A2UI Message Schema
        let allComponentSchemas: [Any] = [
            buttonSchema,
            columnSchema,
            textSchema,
            imageSchema,
            travelCarouselSchema,
            informationCardSchema,
            itinerarySchema,
            inputGroupSchema,
            optionsFilterChipSchema,
            checkboxFilterChipSchema,
            dateInputChipSchema,
            textInputChipSchema,
            trailheadSchema,
            listingsBookerSchema,
            tabbedSectionsSchema
        ]

        let fullSchema: [String: Any] = [
            "allOf": [
                [
                    "type": "object",
                    "title": "A2UI Message Schema",
                    "description": "Describes a JSON payload for an A2UI (Agent to UI) message. A message MUST contain exactly ONE of the action properties.",
                    "properties": [
                        "version": ["type": "string", "const": "v0.9"],
                        "createSurface": [
                            "type": "object",
                            "properties": [
                                "surfaceId": ["type": "string", "description": "The unique identifier for the surface."],
                                "catalogId": ["type": "string", "description": "The URI of the component catalog."],
                                "sendDataModel": ["type": "boolean", "description": "Whether to send the data model to every client request."]
                            ],
                            "required": ["surfaceId", "catalogId"]
                        ],
                        "updateComponents": [
                            "type": "object",
                            "properties": [
                                "surfaceId": ["type": "string", "description": "The unique identifier for the UI surface."],
                                "components": [
                                    "type": "array",
                                    "description": "A flat list of component definitions. Each must have an \"id\" field and match one of the component schemas.",
                                    "minItems": 1,
                                    "items": [
                                        "oneOf": allComponentSchemas,
                                        "description": "Must match one of the component definitions in the catalog."
                                    ]
                                ]
                            ],
                            "required": ["surfaceId", "components"]
                        ],
                        "deleteSurface": [
                            "type": "object",
                            "properties": [
                                "surfaceId": ["type": "string"]
                            ],
                            "required": ["surfaceId"]
                        ]
                    ],
                    "required": ["version"]
                ]
            ],
            "anyOf": [
                ["required": ["createSurface"]],
                ["required": ["updateComponents"]],
                ["required": ["deleteSurface"]]
            ]
        ]

        // Serialize to JSON string
        if let data = try? JSONSerialization.data(withJSONObject: fullSchema, options: [.prettyPrinted, .sortedKeys]),
           let jsonString = String(data: data, encoding: .utf8) {
            return "A2UI Message Schema:\n" + jsonString
        }
        return "Error: could not generate catalog schema"
    }
}

// MARK: - Errors

enum GeminiError: LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Gemini API"
        case .apiError(let statusCode, let message):
            return "Gemini API error (\(statusCode)): \(message)"
        }
    }
}
