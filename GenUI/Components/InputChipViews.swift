// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import SwiftUI
import A2UIV09

/// A chip for selecting a single option from a list of mutually exclusive options.
/// Equivalent to the Flutter `OptionsFilterChipInput` catalog component.
struct OptionsFilterChipView: View {
    let data: OptionsFilterChipData
    var onChanged: ((String?) -> Void)?

    @State private var isShowingOptions = false

    private var displayLabel: String {
        data.value ?? data.chipLabel
    }

    var body: some View {
        Button {
            isShowingOptions = true
        } label: {
            HStack(spacing: 4) {
                if let iconName = data.iconName {
                    Image(systemName: iconName.systemImageName)
                        .font(.caption)
                }
                Text(displayLabel)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.05)))
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isShowingOptions) {
            NavigationStack {
                List(data.options, id: \.self) { option in
                    Button {
                        onChanged?(option)
                        isShowingOptions = false
                    } label: {
                        HStack {
                            Text(option)
                            Spacer()
                            if data.value == option {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
                .navigationTitle(data.chipLabel)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { isShowingOptions = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

/// A chip for selecting multiple options from a list.
/// Equivalent to the Flutter `CheckboxFilterChipsInput` catalog component.
struct CheckboxFilterChipsView: View {
    let data: CheckboxFilterChipsData
    var onChanged: ((Set<String>) -> Void)?

    @State private var isShowingOptions = false

    private var displayLabel: String {
        data.selectedOptions.isEmpty ? data.chipLabel : data.selectedOptions.sorted().joined(separator: ", ")
    }

    var body: some View {
        Button {
            isShowingOptions = true
        } label: {
            HStack(spacing: 4) {
                if let iconName = data.iconName {
                    Image(systemName: iconName.systemImageName)
                        .font(.caption)
                }
                Text(displayLabel)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.05)))
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isShowingOptions) {
            NavigationStack {
                List(data.options, id: \.self) { option in
                    Button {
                        var newSelection = data.selectedOptions
                        if newSelection.contains(option) {
                            newSelection.remove(option)
                        } else {
                            newSelection.insert(option)
                        }
                        onChanged?(newSelection)
                    } label: {
                        HStack {
                            Text(option)
                            Spacer()
                            if data.selectedOptions.contains(option) {
                                Image(systemName: "checkmark.square.fill")
                                    .foregroundStyle(.blue)
                            } else {
                                Image(systemName: "square")
                                    .foregroundStyle(.gray)
                            }
                        }
                    }
                }
                .navigationTitle(data.chipLabel)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { isShowingOptions = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

/// A chip for date input with a date picker sheet.
/// Equivalent to the Flutter `DateInputChip` catalog component.
struct DateInputChipView: View {
    let data: DateInputChipData
    var onChanged: ((Date) -> Void)?

    @State private var isShowingPicker = false
    @State private var selectedDate: Date = Date()

    private var displayLabel: String {
        if let date = data.value {
            return "\(data.label): \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        return data.label
    }

    var body: some View {
        Button {
            selectedDate = data.value ?? Date()
            isShowingPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.caption)
                Text(displayLabel)
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.05)))
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isShowingPicker) {
            NavigationStack {
                DatePicker(
                    data.label,
                    selection: $selectedDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle(data.label)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            onChanged?(selectedDate)
                            isShowingPicker = false
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isShowingPicker = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

/// A chip for free text input.
/// Equivalent to the Flutter `TextInputChip` catalog component.
struct TextInputChipView: View {
    let data: TextInputChipData
    var onChanged: ((String) -> Void)?

    @State private var isShowingInput = false
    @State private var textValue: String = ""

    private var displayLabel: String {
        if let value = data.value, !value.isEmpty {
            return data.obscured ? "********" : value
        }
        return data.label
    }

    var body: some View {
        Button {
            textValue = data.value ?? ""
            isShowingInput = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "pencil")
                    .font(.caption)
                Text(displayLabel)
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.05)))
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isShowingInput) {
            NavigationStack {
                VStack(spacing: 16) {
                    if data.obscured {
                        SecureField(data.label, text: $textValue)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        TextField(data.label, text: $textValue)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button("Done") {
                        if !textValue.isEmpty {
                            onChanged?(textValue)
                        }
                        isShowingInput = false
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()
                }
                .padding()
                .navigationTitle(data.label)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isShowingInput = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

#Preview("Options Filter") {
    OptionsFilterChipView(
        data: OptionsFilterChipData(
            id: "budget",
            chipLabel: "Budget",
            options: ["Low", "Medium", "High"],
            iconName: .wallet,
            value: "Medium"
        )
    )
}

#Preview("Checkbox Filter") {
    CheckboxFilterChipsView(
        data: CheckboxFilterChipsData(
            id: "amenities",
            chipLabel: "Amenities",
            options: ["Wifi", "Gym", "Pool", "Parking"],
            iconName: nil,
            selectedOptions: ["Wifi", "Gym"]
        )
    )
}

// MARK: - A2UI Wrappers

/// Renders an `OptionsFilterChipInput` from an A2UI `ComponentNode`.
struct A2UIOptionsFilterChipView: View {
    let node: ComponentNode
    let surface: SurfaceModel

    private var props: [String: AnyCodable] { node.instance.properties }

    var body: some View {
        let chipLabel = A2UIHelpers.resolveString(props["chipLabel"], surface: surface, dataContextPath: node.dataContextPath) ?? ""
        let options = A2UIHelpers.resolveStringList(props["options"], surface: surface, dataContextPath: node.dataContextPath)
        let iconNameStr = props["iconName"]?.stringValue
        let icon = iconNameStr.flatMap { TravelIcon(rawValue: $0) }
        let currentValue = A2UIHelpers.resolveString(props["value"], surface: surface, dataContextPath: node.dataContextPath)

        OptionsFilterChipView(
            data: OptionsFilterChipData(
                id: node.id,
                chipLabel: chipLabel,
                options: options,
                iconName: icon,
                value: currentValue
            )
        ) { newValue in
            node.instance.properties["value"] = newValue.map { .string($0) } ?? .null
        }
    }
}

/// Renders a `CheckboxFilterChipsInput` from an A2UI `ComponentNode`.
struct A2UICheckboxFilterChipsView: View {
    let node: ComponentNode
    let surface: SurfaceModel

    private var props: [String: AnyCodable] { node.instance.properties }

    var body: some View {
        let chipLabel = A2UIHelpers.resolveString(props["chipLabel"], surface: surface, dataContextPath: node.dataContextPath) ?? ""
        let options = A2UIHelpers.resolveStringList(props["options"], surface: surface, dataContextPath: node.dataContextPath)
        let iconNameStr = props["iconName"]?.stringValue
        let icon = iconNameStr.flatMap { TravelIcon(rawValue: $0) }
        let selected = Set(A2UIHelpers.resolveStringList(props["selectedOptions"], surface: surface, dataContextPath: node.dataContextPath))

        CheckboxFilterChipsView(
            data: CheckboxFilterChipsData(
                id: node.id,
                chipLabel: chipLabel,
                options: options,
                iconName: icon,
                selectedOptions: selected
            )
        ) { newSelected in
            node.instance.properties["selectedOptions"] = .array(newSelected.sorted().map { .string($0) })
        }
    }
}

/// Renders a `DateInputChip` from an A2UI `ComponentNode`.
struct A2UIDateInputChipView: View {
    let node: ComponentNode
    let surface: SurfaceModel

    private var props: [String: AnyCodable] { node.instance.properties }

    var body: some View {
        let label = A2UIHelpers.resolveString(props["label"], surface: surface, dataContextPath: node.dataContextPath) ?? "Date"
        let dateStr = A2UIHelpers.resolveString(props["value"], surface: surface, dataContextPath: node.dataContextPath)
        let date = dateStr.flatMap { parseDateString($0) }

        DateInputChipView(
            data: DateInputChipData(id: node.id, value: date, label: label)
        ) { newDate in
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            node.instance.properties["value"] = .string(formatter.string(from: newDate))
        }
    }

    private func parseDateString(_ str: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: str)
    }
}

/// Renders a `TextInputChip` from an A2UI `ComponentNode`.
struct A2UITextInputChipView: View {
    let node: ComponentNode
    let surface: SurfaceModel

    private var props: [String: AnyCodable] { node.instance.properties }

    var body: some View {
        let label = A2UIHelpers.resolveString(props["label"], surface: surface, dataContextPath: node.dataContextPath) ?? "Text"
        let value = A2UIHelpers.resolveString(props["value"], surface: surface, dataContextPath: node.dataContextPath)
        let obscured = A2UIHelpers.resolveBool(props["obscured"], surface: surface, dataContextPath: node.dataContextPath) ?? false

        TextInputChipView(
            data: TextInputChipData(id: node.id, label: label, value: value, obscured: obscured)
        ) { newValue in
            node.instance.properties["value"] = .string(newValue)
        }
    }
}
