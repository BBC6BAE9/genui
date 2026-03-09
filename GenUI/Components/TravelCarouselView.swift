// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import SwiftUI
import A2UI

/// A horizontally scrolling carousel of travel option cards.
/// Equivalent to the Flutter `TravelCarousel` catalog component.
struct TravelCarouselView: View {
    let data: TravelCarouselData
    var onItemTapped: ((TravelCarouselItem) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = data.title {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .padding(.horizontal)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(data.items) { item in
                        TravelCarouselItemView(item: item)
                            .onTapGesture {
                                onItemTapped?(item)
                            }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct TravelCarouselItemView: View {
    let item: TravelCarouselItem

    var body: some View {
        VStack(spacing: 0) {
            // Image from asset catalog
            let assetName = a2uiExtractAssetName(from: item.imageName)
            Image(assetName)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 190, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(item.description)
                .font(.subheadline)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(width: 190, height: 90)
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - A2UI Wrapper

/// Renders a `TravelCarousel` from an A2UI `ComponentNode`.
struct A2UITravelCarouselView: View {
    let node: ComponentNode
    let viewModel: SurfaceViewModel
    @Environment(\.a2uiActionHandler) private var actionHandler

    private var props: [String: AnyCodable] { node.payload.properties }

    var body: some View {
        let title = A2UIHelpers.resolveString(props["title"], viewModel: viewModel, dataContextPath: node.dataContextPath)

        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .padding(.horizontal)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        carouselItemView(item: item)
                            .onTapGesture {
                                if let action = item.action {
                                    actionHandler?(action)
                                }
                            }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private struct CarouselItem {
        let description: String
        let imageNode: ComponentNode?
        let action: ResolvedAction?
    }

    private var items: [CarouselItem] {
        guard case .array(let itemsArray) = props["items"] else { return [] }
        return itemsArray.compactMap { itemVal -> CarouselItem? in
            guard case .dictionary(let dict) = itemVal else { return nil }
            let desc = dict["description"]?.stringValue ?? ""
            let imageChildId = dict["imageChildId"]?.stringValue
            let imageNode = imageChildId.flatMap {
                viewModel.buildComponentNode(for: $0, dataContextPath: node.dataContextPath)
            }

            let action = A2UIHelpers.resolveAction(dict["action"], node: node, viewModel: viewModel)

            return CarouselItem(description: desc, imageNode: imageNode, action: action)
        }
    }

    @ViewBuilder
    private func carouselItemView(item: CarouselItem) -> some View {
        VStack(spacing: 0) {
            if let imageNode = item.imageNode {
                A2UIComponentView(node: imageNode, viewModel: viewModel)
                    .frame(width: 190, height: 150)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 190, height: 150)
            }

            Text(item.description)
                .font(.subheadline)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(width: 190, height: 90)
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    TravelCarouselView(
        data: MockData.inspirationCarousel,
        onItemTapped: { item in
            print("Tapped: \(item.description)")
        }
    )
}
