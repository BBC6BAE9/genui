// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import Foundation

/// A fake booking service to simulate hotel listings and bookings.
/// Matches Flutter's `BookingService` in `tools/booking/booking_service.dart`.
final class BookingService {
    static let instance = BookingService()

    private init() {}

    private(set) var listings: [String: HotelListing] = [:]

    private func generateListingSelectionId() -> String {
        String(Int.random(in: 0..<1_000_000_000))
    }

    @discardableResult
    private func rememberListing(_ listing: HotelListing) -> HotelListing {
        listings[listing.listingSelectionId] = listing
        return listing
    }

    func listHotels(query: String, checkIn: String, checkOut: String, guests: Int) -> [[String: Any]] {
        let checkInDate = ISO8601DateFormatter().date(from: checkIn + "T00:00:00Z") ?? Date()
        let checkOutDate = ISO8601DateFormatter().date(from: checkOut + "T00:00:00Z")
            ?? Calendar.current.date(byAdding: .day, value: 7, to: checkInDate)!

        let hotel1 = rememberListing(HotelListing(
            id: UUID().uuidString,
            listingSelectionId: generateListingSelectionId(),
            name: "The Dart Inn",
            location: "Sunnyvale, CA",
            pricePerNight: 150,
            imageName: "assets/booking_service/dart_inn.png",
            checkIn: checkInDate,
            checkOut: checkOutDate,
            guests: guests
        ))

        let hotel2 = rememberListing(HotelListing(
            id: UUID().uuidString,
            listingSelectionId: generateListingSelectionId(),
            name: "The Flutter Hotel",
            location: "Mountain View, CA",
            pricePerNight: 250,
            imageName: "assets/booking_service/flutter_hotel.png",
            checkIn: checkInDate,
            checkOut: checkOutDate,
            guests: guests
        ))

        return [hotel1, hotel2].map { hotel in
            [
                "description": hotel.description,
                "images": [hotel.imageName],
                "listingSelectionId": hotel.listingSelectionId,
            ] as [String: Any]
        }
    }

    func bookSelections(listingSelectionIds: [String], paymentMethodId: String) async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    func listing(for selectionId: String) -> HotelListing? {
        listings[selectionId]
    }
}
