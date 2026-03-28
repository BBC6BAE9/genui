// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import Foundation
import A2UIV09

/// Transport that calls the Google Gemini REST API directly,
/// aligning with the Flutter `GoogleGenerativeAiClient` implementation.
final class GeminiTravelTransport: TravelTransport {
    let supportsStreaming = true

    private let apiKey: String
    private let model: String
    private var conversationHistory: [[String: Any]] = []

    /// Client data model set by the ViewModel before actions, matching Flutter's
    /// pattern of including the data model in the system instruction.
    var clientDataModel: A2uiClientDataModel?

    /// Stores the last plain text response from the model when no A2UI messages
    /// were generated. Read by the ViewModel to show as a text bubble.
    private(set) var lastTextResponse: String?

    init(apiKey: String, model: String = "gemini-2.5-flash") {
        self.apiKey = apiKey
        self.model = model
    }

    // MARK: - TravelTransport

    func sendText(_ text: String, contextId: String?) async throws -> TransportResponse {
        print("[GeminiTransport] sendText: \"\(text.prefix(100))\" self=\(ObjectIdentifier(self))")
        conversationHistory.append(userContent(text))

        let messages = try await generateContent()
        print("[GeminiTransport] sendText returning \(messages.count) messages")
        return TransportResponse(messages: messages, contextId: contextId, textResponse: lastTextResponse)
    }

    func sendAction(_ action: ResolvedAction, surfaceId: String, contextId: String?) async throws -> TransportResponse {
        // Build a structured interaction JSON matching Flutter's format:
        // The action is sent as a JSON interaction message in the conversation.
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
                    "context": actionContext
                ] as [String: Any]
            ] as [String: Any]
        ]
        let interactionText: String
        if let data = try? JSONSerialization.data(withJSONObject: interactionJson, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            interactionText = text
        } else {
            interactionText = "User action: \(action.name) on surface: \(surfaceId)"
        }
        print("[GeminiTransport] sendAction: \(interactionText)")
        conversationHistory.append(userContent(interactionText))

        let messages = try await generateContent()
        print("[GeminiTransport] sendAction returning \(messages.count) messages")
        return TransportResponse(messages: messages, contextId: contextId, textResponse: lastTextResponse)    }

    func sendTextStream(_ text: String, contextId: String?) -> AsyncThrowingStream<StreamEvent, Error>? {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    conversationHistory.append(userContent(text))
                    let stream = try streamContent(continuation: continuation)
                    _ = stream
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func sendActionStream(_ action: ResolvedAction, surfaceId: String, contextId: String?) -> AsyncThrowingStream<StreamEvent, Error>? {
        return AsyncThrowingStream { continuation in
            Task {
                do {
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
                                "context": actionContext
                            ] as [String: Any]
                        ] as [String: Any]
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: interactionJson, options: [.sortedKeys]),
                       let text = String(data: data, encoding: .utf8) {
                        conversationHistory.append(userContent(text))
                    }
                    updateClientDataModelForStreaming()
                    try streamContent(continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    @discardableResult
    private func streamContent(continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) throws -> Bool {
        Task {
            do {
                let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?key=\(apiKey)&alt=sse")!
                let requestBody: [String: Any] = [
                    "contents": conversationHistory,
                    "system_instruction": systemInstruction(),
                    "tools": toolDeclarations(),
                    "toolConfig": ["functionCallingConfig": ["mode": "AUTO"]],
                    "generationConfig": [
                        "temperature": 1.0,
                        "topP": 0.95,
                        "maxOutputTokens": 65536
                    ]
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

                var accumulatedText = ""
                var functionCalls: [[String: Any]] = []
                var modelParts: [[String: Any]] = []

                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let jsonStr = String(line.dropFirst(6))
                    guard jsonStr != "[DONE]",
                          let data = jsonStr.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                    let (calls, textParts, parts) = extractResponseParts(from: json)
                    functionCalls.append(contentsOf: calls)
                    if let parts { modelParts.append(contentsOf: parts) }

                    for chunk in textParts {
                        accumulatedText += chunk
                        continuation.yield(.textChunk(chunk))
                    }
                }

                // Save model turn to history
                if !modelParts.isEmpty {
                    conversationHistory.append(["role": "model", "parts": modelParts])
                }

                if !functionCalls.isEmpty {
                    // Handle tool calls: execute and make another (non-streaming) call
                    continuation.yield(.status(state: "tool_use", text: "Looking up options...", taskId: nil, contextId: nil, isFinal: false))
                    var functionResponseParts: [[String: Any]] = []
                    for call in functionCalls {
                        let name = call["name"] as? String ?? ""
                        let args = call["args"] as? [String: Any] ?? [:]
                        let result = await executeTool(name: name, args: args)
                        functionResponseParts.append(["functionResponse": ["name": name, "response": result]])
                    }
                    conversationHistory.append(["role": "user", "parts": functionResponseParts])

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

    private func updateClientDataModelForStreaming() {
        // No-op here; ViewModel calls updateClientDataModel() before action calls.
    }

    // MARK: - Gemini API

    private func generateContent() async throws -> [A2uiMessage] {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!

        let requestBody: [String: Any] = [
            "contents": conversationHistory,
            "system_instruction": systemInstruction(),
            "tools": toolDeclarations(),
            "toolConfig": ["functionCallingConfig": ["mode": "AUTO"]],
            "generationConfig": [
                "temperature": 1.0,
                "topP": 0.95,
                "maxOutputTokens": 65536
            ]
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
        let maxToolCycles = 10

        while toolCycles < maxToolCycles {
            let (functionCalls, textParts, parts) = extractResponseParts(from: currentJson)

            if functionCalls.isEmpty {
                let fullText = textParts.joined()
                print("[GeminiTransport] Model text response (\(fullText.count) chars): \(fullText.prefix(300))...")

                // Add model response to conversation history
                if let parts {
                    conversationHistory.append(["role": "model", "parts": parts])
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
            print("[GeminiTransport] Tool cycle \(toolCycles): \(functionCalls.count) function call(s)")

            // Add model response (with function calls) to history
            if let parts {
                conversationHistory.append(["role": "model", "parts": parts])
            }

            // Process function calls
            var functionResponseParts: [[String: Any]] = []
            for call in functionCalls {
                let name = call["name"] as? String ?? ""
                let args = call["args"] as? [String: Any] ?? [:]
                print("[GeminiTransport] Executing tool: \(name) args: \(args)")
                let result = await executeTool(name: name, args: args)
                functionResponseParts.append([
                    "functionResponse": [
                        "name": name,
                        "response": result
                    ]
                ])
            }

            // Add tool responses to history
            conversationHistory.append([
                "role": "user",
                "parts": functionResponseParts
            ])

            let nextRequestBody: [String: Any] = [
                "contents": conversationHistory,
                "system_instruction": systemInstruction(),
                "tools": toolDeclarations(),
                "toolConfig": ["functionCallingConfig": ["mode": "AUTO"]],
                "generationConfig": [
                    "temperature": 1.0,
                    "topP": 0.95,
                    "maxOutputTokens": 65536
                ]
            ]

            currentJson = try await callGemini(url: url, body: nextRequestBody)
        }

        print("[GeminiTransport] Exceeded max tool cycles (\(maxToolCycles))")
        return []
    }

    /// Streaming variant: returns individual parts for incremental accumulation.
    private func extractResponseParts(from json: [String: Any]) -> (
        functionCalls: [[String: Any]],
        textParts: [String],
        parts: [[String: Any]]?
    ) {
        guard let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return ([], [], nil)
        }

        var functionCalls: [[String: Any]] = []
        var textParts: [String] = []

        for part in parts {
            if let functionCall = part["functionCall"] as? [String: Any] {
                functionCalls.append(functionCall)
            }
            if let text = part["text"] as? String {
                textParts.append(text)
            }
        }

        return (functionCalls, textParts, parts)
    }

    /// Returns the `tools` array for the Gemini API request, declaring the `listHotels` function.
    /// Matches the Flutter `ListHotelsTool` schema in `list_hotels_tool.dart`.
    private func toolDeclarations() -> [[String: Any]] {
        return [[
            "functionDeclarations": [[
                "name": "listHotels",
                "description": "Lists hotels based on the provided criteria.",
                "parameters": [
                    "type": "OBJECT",
                    "properties": [
                        "query": [
                            "type": "STRING",
                            "description": "The search query, e.g., \"hotels in Paris\"."
                        ],
                        "checkIn": [
                            "type": "STRING",
                            "description": "The check-in date in ISO 8601 format (YYYY-MM-DD)."
                        ],
                        "checkOut": [
                            "type": "STRING",
                            "description": "The check-out date in ISO 8601 format (YYYY-MM-DD)."
                        ],
                        "guests": [
                            "type": "INTEGER",
                            "description": "The number of guests."
                        ]
                    ],
                    "required": ["query", "checkIn", "checkOut", "guests"]
                ]
            ]]
        ]]
    }

    /// Execute a tool call. Currently supports `listHotels`.
    /// Returns data matching the Flutter `BookingService.listHotelsSync()` format.
    private func executeTool(name: String, args: [String: Any]) async -> [String: Any] {
        if name == "listHotels" {
            let query = args["query"] as? String ?? ""
            return [
                "listings": [
                    [
                        "description": "The Dart Inn in \(query), $150",
                        "images": ["dart_inn"],
                        "listingSelectionId": "123456789"
                    ],
                    [
                        "description": "The Flutter Hotel in \(query), $250",
                        "images": ["flutter_hotel"],
                        "listingSelectionId": "987654321"
                    ]
                ]
            ]
        }
        return ["error": "Unknown tool: \(name)"]
    }

    // MARK: - System Instruction

    /// Returns the system instruction in Gemini REST API `system_instruction` format.
    /// Matches Flutter's approach: separate parts for system prompt, date/instructions,
    /// catalog rules, catalog schema, and optionally the client data model.
    private func systemInstruction() -> [String: Any] {
        let dateString = ISO8601DateFormatter().string(from: Date()).prefix(10)
        var parts: [[String: Any]] = [
            ["text": Self.systemPrompt],
            ["text": "Current Date: \(dateString)"],
            // Matches Flutter PromptBuilder.custom() injected fragments:
            ["text": "Use the provided tools to respond to user using rich UI elements."],
            ["text": "IMPORTANT: You do not have the ability to execute code. If you need to perform calculations, do them yourself."],
            ["text": "IMPORTANT: You do not have the ability to use tools for UI generation."],
            ["text": "IMPORTANT: You do not have the ability to use function calls for UI generation."],
            ["text": Self.catalogRules],
        ]
        // Include client data model when available (matches Flutter's pattern
        // of sending the data model in the system instruction).
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
        parts.append(["text": Self.catalogSchema])
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

    private func userContent(_ text: String) -> [String: Any] {
        [
            "role": "user",
            "parts": [["text": text]]
        ]
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

    /// The available asset images in the SwiftUI project.
    private static let assetImages = """
    Available asset images (use these names directly as the image url):
    - akrotiri_spring_fresco_santorini
    - bali_memorial
    - borobudur_indonesia
    - brooklyn_bridge_new_york
    - canyonlands_national_park_utah
    - dart_inn
    - edo_panorama_tokyo
    - eiffel_tower_construction_1888
    - flutter_hotel
    - kata_noi_beach_phuket_thailand
    - saffron_gatherers_fresco_santorini
    - santorini_from_space
    - santorini_panorama
    """

    /// System prompt aligned with Flutter `travel_planner_page.dart`.
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
        Column with the existing inputGroup, an Itinerary component. When creating
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
        the original `Itinerary` to reflect the booking by updating the
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

    ## Controlling the UI

    You can control the UI by outputting valid A2UI JSON messages wrapped in markdown code blocks.
    Supported messages are: `createSurface` and `updateComponents`.

    To show a new UI:
    1. Output a `createSurface` message to define the surface ID and catalog.
    2. Output an `updateComponents` message to populate the surface with components.

    To update an existing UI (e.g. adding items to an itinerary):
    1. Output an `updateComponents` message with the existing `surfaceId` and the new component definitions.

    Properties:
    - `createSurface`: requires `surfaceId`, `catalogId` (use the catalog ID provided in system instructions), and `sendDataModel: true`.
    - `updateComponents`: requires `surfaceId` and a list of `components`. One component MUST have `id: "root"`.

    IMPORTANT:
    - Do not use tools or function calls for UI generation. Use JSON text blocks.
    - Ensure all JSON is valid and fenced with ```json ... ```.

    ## Images

    If you need to use any images, find the most relevant ones from the following
    list of asset images:

    \(assetImages)

    - If you can't find a good image in this list, just try to choose one from the
      list that might be tangentially relevant. DO NOT USE ANY IMAGES NOT IN THE
      LIST. It is fine if the image is unrelated, as long as it is from the list.

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
            "component": "Itinerary",
            "title": "Mexico City Adventure",
            "subheading": "3-day Itinerary",
            "imageChildId": "mexico_city_image",
            "days": [
              {
                "title": "Day 1",
                "subtitle": "Arrival and Exploration",
                "description": "Your first day in Mexico City...",
                "imageChildId": "day1_image",
                "entries": [
                  {
                    "type": "transport",
                    "title": "Arrival at MEX Airport",
                    "time": "2:00 PM",
                    "bodyText": "Arrive at Mexico City International Airport.",
                    "status": "noBookingRequired"
                  },
                  {
                    "type": "accommodation",
                    "title": "Hotel Check-in",
                    "time": "4:00 PM",
                    "bodyText": "Check in to your hotel in the historic center.",
                    "status": "choiceRequired",
                    "choiceRequiredAction": {
                      "event": {
                        "name": "chooseHotel",
                        "context": {"entryTitle": "Hotel Check-in"}
                      }
                    }
                  }
                ]
              }
            ]
          },
          {
            "id": "mexico_city_image",
            "component": "Image",
            "url": "santorini_panorama",
            "fit": "cover"
          },
          {
            "id": "day1_image",
            "component": "Image",
            "url": "santorini_panorama",
            "fit": "cover"
          }
        ]
      }
    }
    ```

    When updating or showing UIs, **ALWAYS** use the JSON messages as described above. Prefer to collect and show information by creating a UI for it.
    """

    /// Catalog rules from Flutter's `BasicCatalogEmbed.basicCatalogRules`.
    static let catalogRules = """
    **REQUIRED PROPERTIES:** You MUST include ALL required properties for every component, even if they are inside a template or will be bound to data.
    - For 'Text', you MUST provide 'text'. If dynamic, use { "path": "..." }.
    - For 'Image', you MUST provide 'url'. If dynamic, use { "path": "..." }.
    - For 'Button', you MUST provide 'action'.
    - For 'TextField', 'CheckBox', etc., you MUST provide 'label'.

    **OUTPUT FORMAT:**
    You must output a VALID JSON object representing one of the A2UI message types (`createSurface`, `updateComponents`, `updateDataModel`, `deleteSurface`).
    - Do NOT use function blocks or tool calls for these messages.
    - You can treat the A2UI schema as a specification for the JSON you typically output.
    - You may include a brief conversational explanation before or after the JSON block if it helps the user, but the JSON block must be valid and complete.
    - Ensure your JSON is fenced with ```json and ```.

    **EXAMPLES:**

    1. Create a surface:
    ```json
    {
      "version": "v0.9",
      "createSurface": {
        "surfaceId": "main",
        "catalogId": "https://a2ui.org/specification/v0_9/standard_catalog.json",
        "sendDataModel": true
      }
    }
    ```

    2. Update components:
    ```json
    {
      "version": "v0.9",
      "updateComponents": {
        "surfaceId": "main",
        "components": [
          {
            "id": "root",
            "component": "Column",
            "justify": "start",
            "children": [
              "headerText",
              "content"
            ]
          }
        ]
      }
    }
    ```

    **IMPORTANT:**
    - One of the components sent in one of the `updateComponents` MUST have id "root", or nothing will be displayed.
    - Do NOT nest `components` inside `createSurface`. Use `updateComponents` to add components to a surface.
    - `createSurface` ONLY sets up the surface (ID and catalog). It does NOT take content.
    - To show a UI, you typically send a `createSurface` message (if the surface doesn't exist), followed by an `updateComponents` message.
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
