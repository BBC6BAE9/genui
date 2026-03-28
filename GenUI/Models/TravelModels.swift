// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import SwiftUI
import A2UIV09

// MARK: - Travel Icons

enum TravelIcon: String, CaseIterable {
    case location, hotel, restaurant, airport, train, car
    case date, time, calendar, people, person, family
    case wallet, receipt

    var systemImageName: String {
        switch self {
        case .location: return "mappin.and.ellipse"
        case .hotel: return "bed.double.fill"
        case .restaurant: return "fork.knife"
        case .airport: return "airplane"
        case .train: return "tram.fill"
        case .car: return "car.fill"
        case .date: return "calendar"
        case .time: return "clock"
        case .calendar: return "calendar"
        case .people: return "person.2.fill"
        case .person: return "person.fill"
        case .family: return "figure.2.and.child.holdinghands"
        case .wallet: return "creditcard.fill"
        case .receipt: return "doc.text.fill"
        }
    }
}

// MARK: - Itinerary Types

enum ItineraryEntryType: String, Codable {
    case accommodation
    case transport
    case activity

    var systemImageName: String {
        switch self {
        case .accommodation: return "bed.double.fill"
        case .transport: return "tram.fill"
        case .activity: return "figure.hiking"
        }
    }
}

enum ItineraryEntryStatus: String, Codable {
    case noBookingRequired
    case choiceRequired
    case chosen
}

// MARK: - Data Models

struct TravelCarouselData {
    let title: String?
    let items: [TravelCarouselItem]
}

struct TravelCarouselItem: Identifiable {
    let id = UUID()
    let description: String
    let imageName: String
    let listingSelectionId: String?
    let actionName: String
}

struct ItineraryData {
    let title: String
    let subheading: String
    let imageName: String
    let days: [ItineraryDayData]
    var imageNode: ComponentNode? = nil
    var surface: SurfaceModel? = nil
}

struct ItineraryDayData: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let description: String
    let imageName: String
    let entries: [ItineraryEntryData]
    var imageNode: ComponentNode? = nil
    var surface: SurfaceModel? = nil
}

struct ItineraryEntryData: Identifiable {
    let id = UUID()
    let title: String
    var subtitle: String? = nil
    let bodyText: String
    var address: String? = nil
    let time: String
    var totalCost: String? = nil
    let type: ItineraryEntryType
    let status: ItineraryEntryStatus
    var choiceRequiredAction: [String: Any]? = nil
}

struct InformationCardData {
    let title: String
    let subtitle: String?
    let body: String
    let imageName: String?
}

struct InputGroupData {
    let submitLabel: String
    var children: [InputChild]
    let actionName: String
}

enum InputChild: Identifiable {
    case optionsFilter(OptionsFilterChipData)
    case checkboxFilter(CheckboxFilterChipsData)
    case dateInput(DateInputChipData)
    case textInput(TextInputChipData)

    var id: String {
        switch self {
        case .optionsFilter(let d): return d.id
        case .checkboxFilter(let d): return d.id
        case .dateInput(let d): return d.id
        case .textInput(let d): return d.id
        }
    }
}

struct OptionsFilterChipData: Identifiable {
    let id: String
    let chipLabel: String
    let options: [String]
    let iconName: TravelIcon?
    var value: String?
}

struct CheckboxFilterChipsData: Identifiable {
    let id: String
    let chipLabel: String
    let options: [String]
    let iconName: TravelIcon?
    var selectedOptions: Set<String>
}

struct DateInputChipData: Identifiable {
    let id: String
    var value: Date?
    let label: String
}

struct TextInputChipData: Identifiable {
    let id: String
    let label: String
    var value: String?
    let obscured: Bool
}

struct TrailheadData {
    let topics: [String]
    let actionName: String
}

struct HotelListing: Identifiable {
    let id: String
    let listingSelectionId: String
    let name: String
    let location: String
    let pricePerNight: Double
    let imageName: String
    let checkIn: Date
    let checkOut: Date
    let guests: Int

    var description: String {
        "\(name) in \(location), $\(Int(pricePerNight))"
    }

    var nights: Int {
        Calendar.current.dateComponents([.day], from: checkIn, to: checkOut).day ?? 0
    }

    var totalPrice: Double {
        Double(nights) * pricePerNight
    }
}

struct ListingsBookerData {
    let itineraryName: String
    var listings: [HotelListing]
}
