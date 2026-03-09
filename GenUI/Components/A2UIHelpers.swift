// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import SwiftUI
import A2UI

/// Helper functions for reading properties from A2UI `ComponentNode`.
enum A2UIHelpers {

    /// Resolve a string from a component property (literal or data path).
    /// Bridges AnyCodable to StringValue and delegates to viewModel.resolveString()
    /// for full parity (function calls, literal seeding, path fallbacks).
    static func resolveString(_ value: AnyCodable?, viewModel: SurfaceViewModel, dataContextPath: String = "/") -> String? {
        guard let value else { return nil }
        if let sv = decodeStringValue(from: value) {
            let result = viewModel.resolveString(sv, dataContextPath: dataContextPath)
            return result.isEmpty ? nil : result
        }
        // Fallback: plain string
        if case .string(let s) = value { return s }
        return nil
    }

    /// Decode an AnyCodable into a StringValue for viewModel.resolveString().
    private static func decodeStringValue(from value: AnyCodable) -> StringValue? {
        switch value {
        case .string(let s):
            return StringValue(literalString: s)
        case .dictionary(let dict):
            // Function call: {"call": "...", "args": {...}}
            if dict["call"] != nil {
                return StringValue(functionCall: .dictionary(dict))
            }
            // Data path: {"path": "..."}
            if let path = dict["path"]?.stringValue {
                let literal = dict["literalString"]?.stringValue ?? dict["literal"]?.stringValue
                return StringValue(path: path, literalString: literal)
            }
            // Literal string: {"literalString": "..."} or {"literal": "..."}
            if let s = dict["literalString"]?.stringValue ?? dict["literal"]?.stringValue {
                return StringValue(literalString: s)
            }
            return nil
        default:
            return nil
        }
    }

    /// Resolve a list of strings from a component property.
    static func resolveStringList(_ value: AnyCodable?, viewModel: SurfaceViewModel, dataContextPath: String = "/") -> [String] {
        guard case .array(let arr) = value else { return [] }
        return arr.compactMap { item in
            resolveString(item, viewModel: viewModel, dataContextPath: dataContextPath)
        }
    }

    /// Resolve a double from a component property.
    static func resolveDouble(_ value: AnyCodable?, viewModel: SurfaceViewModel, dataContextPath: String = "/") -> Double? {
        guard let value else { return nil }
        switch value {
        case .number(let n):
            return n
        case .dictionary(let dict):
            if let path = dict["path"]?.stringValue {
                return viewModel.getDataByPath(viewModel.resolvePath(path, context: dataContextPath))?.numberValue
            }
            return dict["literalNumber"]?.numberValue ?? dict["literal"]?.numberValue
        default:
            return nil
        }
    }

    /// Resolve a boolean from a component property.
    static func resolveBool(_ value: AnyCodable?, viewModel: SurfaceViewModel, dataContextPath: String = "/") -> Bool? {
        guard let value else { return nil }
        switch value {
        case .bool(let b):
            return b
        case .dictionary(let dict):
            if let path = dict["path"]?.stringValue {
                return viewModel.getDataByPath(viewModel.resolvePath(path, context: dataContextPath))?.boolValue
            }
            return dict["literalBoolean"]?.boolValue ?? dict["literal"]?.boolValue
        default:
            return nil
        }
    }

    /// Resolve an Action from a component property dictionary.
    static func resolveAction(
        _ value: AnyCodable?,
        node: ComponentNode,
        viewModel: SurfaceViewModel
    ) -> ResolvedAction? {
        guard let value else { return nil }
        // Decode the action
        guard let data = try? JSONEncoder().encode(value),
              let action = try? JSONDecoder().decode(Action.self, from: data) else {
            return nil
        }
        return viewModel.resolveAction(action, sourceComponentId: node.id, dataContextPath: node.dataContextPath)
    }
}
