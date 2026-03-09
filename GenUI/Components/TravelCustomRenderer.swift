// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import SwiftUI
import A2UI

/// Custom component renderer that maps A2UI component types to travel app views.
let travelCustomRenderer: CustomComponentRenderer = { typeName, node, children, viewModel in
    switch typeName {
    case TravelComponentNames.travelCarousel:
        return AnyView(A2UITravelCarouselView(node: node, viewModel: viewModel))

    case TravelComponentNames.informationCard:
        return AnyView(A2UIInformationCardView(node: node, viewModel: viewModel))

    case TravelComponentNames.itinerary:
        return AnyView(A2UIItineraryView(node: node, viewModel: viewModel))

    case TravelComponentNames.inputGroup:
        return AnyView(A2UIInputGroupView(node: node, children: children, viewModel: viewModel))

    case TravelComponentNames.trailhead:
        return AnyView(A2UITrailheadView(node: node, viewModel: viewModel))

    case TravelComponentNames.listingsBooker:
        return AnyView(A2UIListingsBookerView(node: node, viewModel: viewModel))

    case TravelComponentNames.tabbedSections:
        return AnyView(A2UITabbedSectionsView(node: node, children: children, viewModel: viewModel))

    case TravelComponentNames.optionsFilterChipInput:
        return AnyView(A2UIOptionsFilterChipView(node: node, viewModel: viewModel))

    case TravelComponentNames.checkboxFilterChipsInput:
        return AnyView(A2UICheckboxFilterChipsView(node: node, viewModel: viewModel))

    case TravelComponentNames.dateInputChip:
        return AnyView(A2UIDateInputChipView(node: node, viewModel: viewModel))

    case TravelComponentNames.textInputChip:
        return AnyView(A2UITextInputChipView(node: node, viewModel: viewModel))

    default:
        return nil
    }
}
