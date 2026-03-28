// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import Foundation
import A2UIV09

/// Builds A2UI protocol messages (`A2uiMessage`) from mock travel data.
/// Uses v0.9 message format: `createSurface` + `updateComponents`.
enum MockServerToClientMessages {

    // MARK: - JSON Decoding Helper

    /// Decode a JSON dictionary into an `A2uiMessage`.
    /// Public so CatalogView can use the same decoding logic.
    static func decodeMessage(_ json: [String: Any]) -> A2uiMessage? {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(A2uiMessage.self, from: data)
    }

    /// Build `createSurface` + `updateComponents` messages from component JSON arrays.
    private static func buildMessages(
        surfaceId: String,
        components: [[String: Any]]
    ) -> [A2uiMessage] {
        var result: [A2uiMessage] = []
        if let create = decodeMessage(["createSurface": ["surfaceId": surfaceId, "catalogId": "travel"]]) {
            result.append(create)
        }
        if let update = decodeMessage(["updateComponents": ["surfaceId": surfaceId, "components": components]]) {
            result.append(update)
        }
        return result
    }

    // MARK: - Travel Carousel

    static func travelCarousel(surfaceId: String, data: TravelCarouselData) -> [A2uiMessage] {
        var items: [[String: Any]] = []
        for (index, item) in data.items.enumerated() {
            let imageId = "img_\(index)"

            var actionDict: [String: Any] = ["event": ["name": item.actionName]]
            if let selId = item.listingSelectionId {
                actionDict = ["event": [
                    "name": item.actionName,
                    "context": ["listingSelectionId": selId, "description": item.description]
                ]]
            } else {
                actionDict = ["event": [
                    "name": item.actionName,
                    "context": ["description": item.description]
                ]]
            }

            var itemDict: [String: Any] = [
                "description": item.description,
                "imageChildId": imageId,
                "action": actionDict
            ]
            if let selId = item.listingSelectionId {
                itemDict["listingSelectionId"] = selId
            }
            items.append(itemDict)
        }

        var rootProps: [String: Any] = ["items": items]
        if let title = data.title {
            rootProps["title"] = title
        }

        var components: [[String: Any]] = [
            ["id": "root", "component": TravelComponentNames.travelCarousel] + rootProps
        ]

        // Add image child components
        for (index, item) in data.items.enumerated() {
            let imageId = "img_\(index)"
            components.append([
                "id": imageId,
                "component": "Image",
                "url": item.imageName,
                "fit": "cover"
            ])
        }

        return buildMessages(surfaceId: surfaceId, components: components)
    }

    // MARK: - Information Card

    static func informationCard(surfaceId: String, data: InformationCardData) -> [A2uiMessage] {
        var rootProps: [String: Any] = [
            "title": data.title,
            "body": data.body
        ]
        if let subtitle = data.subtitle {
            rootProps["subtitle"] = subtitle
        }

        var components: [[String: Any]] = []

        if let imageName = data.imageName {
            let imageId = "img"
            rootProps["imageChildId"] = imageId
            components.append([
                "id": imageId,
                "component": "Image",
                "url": imageName,
                "fit": "cover"
            ])
        }

        components.insert(
            ["id": "root", "component": TravelComponentNames.informationCard] + rootProps,
            at: 0
        )

        return buildMessages(surfaceId: surfaceId, components: components)
    }

    // MARK: - Itinerary

    static func itinerary(surfaceId: String, data: ItineraryData) -> [A2uiMessage] {
        let heroImageId = "hero_img"

        var allComponents: [[String: Any]] = []
        var daysJson: [[String: Any]] = []

        for (dayIndex, day) in data.days.enumerated() {
            let dayImageId = "day\(dayIndex)_img"

            var entriesJson: [[String: Any]] = []
            for entry in day.entries {
                var entryDict: [String: Any] = [
                    "title": entry.title,
                    "bodyText": entry.bodyText,
                    "time": entry.time,
                    "type": entry.type.rawValue,
                    "status": entry.status.rawValue
                ]
                if let subtitle = entry.subtitle { entryDict["subtitle"] = subtitle }
                if let address = entry.address { entryDict["address"] = address }
                if let cost = entry.totalCost { entryDict["totalCost"] = cost }

                if entry.status == .choiceRequired {
                    entryDict["choiceRequiredAction"] = [
                        "event": [
                            "name": "chooseEntry",
                            "context": ["entryTitle": entry.title]
                        ]
                    ]
                }

                entriesJson.append(entryDict)
            }

            let dayDict: [String: Any] = [
                "title": day.title,
                "subtitle": day.subtitle,
                "description": day.description,
                "imageChildId": dayImageId,
                "entries": entriesJson
            ]
            daysJson.append(dayDict)

            allComponents.append([
                "id": dayImageId,
                "component": "Image",
                "url": day.imageName,
                "fit": "cover"
            ])
        }

        let rootProps: [String: Any] = [
            "title": data.title,
            "subheading": data.subheading,
            "imageChildId": heroImageId,
            "days": daysJson
        ]

        allComponents.insert(contentsOf: [
            ["id": "root", "component": TravelComponentNames.itinerary] + rootProps,
            ["id": heroImageId, "component": "Image", "url": data.imageName, "fit": "cover"]
        ], at: 0)

        return buildMessages(surfaceId: surfaceId, components: allComponents)
    }

    // MARK: - Input Group

    static func inputGroup(surfaceId: String, data: InputGroupData) -> [A2uiMessage] {
        var childIds: [String] = []
        var allComponents: [[String: Any]] = []

        for child in data.children {
            switch child {
            case .optionsFilter(let chip):
                let childId = chip.id
                childIds.append(childId)
                var props: [String: Any] = [
                    "chipLabel": chip.chipLabel,
                    "options": chip.options
                ]
                if let icon = chip.iconName { props["iconName"] = icon.rawValue }
                if let value = chip.value { props["value"] = value }
                allComponents.append(
                    ["id": childId, "component": TravelComponentNames.optionsFilterChipInput] + props
                )

            case .checkboxFilter(let chip):
                let childId = chip.id
                childIds.append(childId)
                var props: [String: Any] = [
                    "chipLabel": chip.chipLabel,
                    "options": chip.options,
                    "selectedOptions": Array(chip.selectedOptions)
                ]
                if let icon = chip.iconName { props["iconName"] = icon.rawValue }
                allComponents.append(
                    ["id": childId, "component": TravelComponentNames.checkboxFilterChipsInput] + props
                )

            case .dateInput(let chip):
                let childId = chip.id
                childIds.append(childId)
                var props: [String: Any] = ["label": chip.label]
                if let date = chip.value {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    props["value"] = formatter.string(from: date)
                }
                allComponents.append(
                    ["id": childId, "component": TravelComponentNames.dateInputChip] + props
                )

            case .textInput(let chip):
                let childId = chip.id
                childIds.append(childId)
                var props: [String: Any] = ["label": chip.label]
                if let value = chip.value { props["value"] = value }
                if chip.obscured { props["obscured"] = true }
                allComponents.append(
                    ["id": childId, "component": TravelComponentNames.textInputChip] + props
                )
            }
        }

        let rootProps: [String: Any] = [
            "submitLabel": data.submitLabel,
            "children": childIds,
            "action": ["event": ["name": data.actionName]]
        ]

        allComponents.insert(
            ["id": "root", "component": TravelComponentNames.inputGroup] + rootProps,
            at: 0
        )

        return buildMessages(surfaceId: surfaceId, components: allComponents)
    }

    // MARK: - Trailhead

    static func trailhead(surfaceId: String, data: TrailheadData) -> [A2uiMessage] {
        let rootProps: [String: Any] = [
            "topics": data.topics,
            "action": ["event": ["name": data.actionName]]
        ]

        let components: [[String: Any]] = [
            ["id": "root", "component": TravelComponentNames.trailhead] + rootProps
        ]

        return buildMessages(surfaceId: surfaceId, components: components)
    }

    // MARK: - Listings Booker

    static func listingsBooker(surfaceId: String, data: ListingsBookerData) -> [A2uiMessage] {
        let selectionIds = data.listings.map(\.listingSelectionId)

        let rootProps: [String: Any] = [
            "listingSelectionIds": selectionIds,
            "itineraryName": data.itineraryName
        ]

        let components: [[String: Any]] = [
            ["id": "root", "component": TravelComponentNames.listingsBooker] + rootProps
        ]

        return buildMessages(surfaceId: surfaceId, components: components)
    }

}

// Helper to merge dictionaries for component construction.
private func + (lhs: [String: Any], rhs: [String: Any]) -> [String: Any] {
    var result = lhs
    for (key, value) in rhs { result[key] = value }
    return result
}
