// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import Foundation
import A2UI

/// Mock transport that simulates agent responses using keyword matching.
final class MockTravelTransport: TravelTransport {
    let supportsStreaming = false

    func sendText(_ text: String, contextId: String?) async throws -> TransportResponse {
        // Simulate network delay
        try await Task.sleep(for: .milliseconds(800))
        let messages = processUserText(text)
        return TransportResponse(messages: messages, contextId: contextId)
    }

    func sendAction(_ action: ResolvedAction, surfaceId: String, contextId: String?) async throws -> TransportResponse {
        try await Task.sleep(for: .milliseconds(600))
        let messages = processAction(action)
        return TransportResponse(messages: messages, contextId: contextId)
    }

    func sendTextStream(_ text: String, contextId: String?) -> AsyncThrowingStream<StreamEvent, Error>? {
        nil
    }

    func sendActionStream(_ action: ResolvedAction, surfaceId: String, contextId: String?) -> AsyncThrowingStream<StreamEvent, Error>? {
        nil
    }

    // MARK: - Private

    private func processUserText(_ text: String) -> [ServerToClientMessage] {
        let lower = text.lowercased()
        if lower.contains("greece") || lower.contains("greek") || lower.contains("santorini") {
            return MockA2UIMessages.informationCard(surfaceId: "destination_info", data: MockData.santoriniInfo)
                + MockA2UIMessages.inputGroup(surfaceId: "trip_preferences", data: MockData.tripPreferencesInputGroup)
        } else if lower.contains("book") || lower.contains("hotel") {
            return MockA2UIMessages.travelCarousel(surfaceId: "hotel_carousel", data: MockData.hotelCarousel)
        } else if lower.contains("itinerary") || lower.contains("plan") {
            return MockA2UIMessages.itinerary(surfaceId: "itinerary", data: MockData.greeceItinerary)
        } else {
            return MockA2UIMessages.travelCarousel(surfaceId: "inspiration", data: MockData.inspirationCarousel)
        }
    }

    private func processAction(_ action: ResolvedAction) -> [ServerToClientMessage] {
        let description = action.context["topic"]?.stringValue
            ?? action.context["description"]?.stringValue
            ?? ""

        switch action.name {
        case "selectExperience":
            return MockA2UIMessages.travelCarousel(surfaceId: "destinations", data: MockData.destinationCarousel)

        case "selectDestination":
            return MockA2UIMessages.informationCard(surfaceId: "destination_info", data: MockData.santoriniInfo)
                + MockA2UIMessages.inputGroup(surfaceId: "trip_preferences", data: MockData.tripPreferencesInputGroup)

        case "searchItineraries":
            return MockA2UIMessages.itinerary(surfaceId: "itinerary", data: MockData.greeceItinerary)
                + MockA2UIMessages.trailhead(surfaceId: "suggestions", data: MockData.postItinerarySuggestions)

        case "selectTopic":
            let topic = description
            if topic.lowercased().contains("hotel") || topic.lowercased().contains("book") {
                return MockA2UIMessages.travelCarousel(surfaceId: "hotel_carousel", data: MockData.hotelCarousel)
            } else {
                return MockA2UIMessages.trailhead(surfaceId: "more_suggestions", data: TrailheadData(
                    topics: ["Create itinerary for Greece", "Book hotels", "Flight options"],
                    actionName: "selectTopic"
                ))
            }

        case "selectHotel":
            return MockA2UIMessages.listingsBooker(surfaceId: "listings_booker", data: MockData.listingsBooker)

        case "chooseEntry":
            return MockA2UIMessages.travelCarousel(surfaceId: "hotel_carousel", data: MockData.hotelCarousel)

        default:
            return MockA2UIMessages.travelCarousel(surfaceId: "inspiration", data: MockData.inspirationCarousel)
        }
    }
}
