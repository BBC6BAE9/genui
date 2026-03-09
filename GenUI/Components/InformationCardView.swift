// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import SwiftUI
import A2UI

/// A card displaying detailed information about a travel destination.
/// Equivalent to the Flutter `InformationCard` catalog component.
struct InformationCardView: View {
    let data: InformationCardData
    var imageView: AnyView?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header image
            if let imageView {
                imageView
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .clipped()
            } else if let imageName = data.imageName {
                let assetName = a2uiExtractAssetName(from: imageName)
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(data.title)
                    .font(.title2)
                    .fontWeight(.bold)

                if let subtitle = data.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(data.body)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
            .padding()
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
        .frame(maxWidth: 400)
    }
}

// MARK: - A2UI Wrapper

/// Renders an `InformationCard` from an A2UI `ComponentNode`.
struct A2UIInformationCardView: View {
    let node: ComponentNode
    let viewModel: SurfaceViewModel

    private var props: [String: AnyCodable] { node.payload.properties }

    var body: some View {
        let title = A2UIHelpers.resolveString(props["title"], viewModel: viewModel, dataContextPath: node.dataContextPath) ?? ""
        let subtitle = A2UIHelpers.resolveString(props["subtitle"], viewModel: viewModel, dataContextPath: node.dataContextPath)
        let body = A2UIHelpers.resolveString(props["body"], viewModel: viewModel, dataContextPath: node.dataContextPath) ?? ""
        let imageNode = buildImageNode()

        let imageView: AnyView? = imageNode.map { n in
            AnyView(
                A2UIComponentView(node: n, viewModel: viewModel)
                    .frame(height: 200)
            )
        }

        InformationCardView(
            data: InformationCardData(
                title: title,
                subtitle: subtitle,
                body: body,
                imageName: nil
            ),
            imageView: imageView
        )
        .padding(.horizontal)
    }

    private func buildImageNode() -> ComponentNode? {
        guard let childId = props["imageChildId"]?.stringValue else { return nil }
        return viewModel.buildComponentNode(for: childId, dataContextPath: node.dataContextPath)
    }
}

#Preview {
    InformationCardView(data: MockData.santoriniInfo)
        .padding()
}
