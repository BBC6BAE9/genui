// Copyright 2025 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import XCTest
@testable import GenUI

/// Tests for `BookingService` and `HotelListing`.
///
/// Mirrors Flutter's `tools/hotels/list_hotels_tool_test.dart`.
final class BookingServiceTests: XCTestCase {

    func testListHotelsReturnsResults() {
        let results = BookingService.instance.listHotels(
            query: "Sunnyvale hotels",
            checkIn: "2025-08-01",
            checkOut: "2025-08-08",
            guests: 2
        )
        XCTAssertEqual(results.count, 2)
    }

    func testListHotelsResultsHaveRequiredFields() {
        let results = BookingService.instance.listHotels(
            query: "test",
            checkIn: "2025-07-01",
            checkOut: "2025-07-05",
            guests: 1
        )

        for result in results {
            XCTAssertNotNil(result["description"] as? String)
            XCTAssertNotNil(result["images"] as? [String])
            XCTAssertNotNil(result["listingSelectionId"] as? String)

            let selectionId = result["listingSelectionId"] as! String
            XCTAssertFalse(selectionId.isEmpty)
        }
    }

    func testListingsAreRemembered() {
        let results = BookingService.instance.listHotels(
            query: "test",
            checkIn: "2025-06-01",
            checkOut: "2025-06-10",
            guests: 2
        )

        for result in results {
            let selectionId = result["listingSelectionId"] as! String
            let listing = BookingService.instance.listing(for: selectionId)
            XCTAssertNotNil(listing, "Listing should be retrievable by selectionId")
            XCTAssertEqual(listing?.listingSelectionId, selectionId)
        }
    }

    func testHotelListingDescription() {
        let listing = HotelListing(
            id: "1",
            listingSelectionId: "sel-1",
            name: "The Dart Inn",
            location: "Sunnyvale, CA",
            pricePerNight: 150,
            imageName: "dart_inn.png",
            checkIn: Date(),
            checkOut: Calendar.current.date(byAdding: .day, value: 3, to: Date())!,
            guests: 2
        )
        XCTAssertEqual(listing.description, "The Dart Inn in Sunnyvale, CA, $150")
    }

    func testHotelListingNightsCalculation() {
        let checkIn = Calendar.current.date(from: DateComponents(year: 2025, month: 8, day: 1))!
        let checkOut = Calendar.current.date(from: DateComponents(year: 2025, month: 8, day: 5))!

        let listing = HotelListing(
            id: "1",
            listingSelectionId: "sel-1",
            name: "Test Hotel",
            location: "Test",
            pricePerNight: 100,
            imageName: "test.png",
            checkIn: checkIn,
            checkOut: checkOut,
            guests: 1
        )
        XCTAssertEqual(listing.nights, 4)
        XCTAssertEqual(listing.totalPrice, 400)
    }

    func testListingSelectionIdsAreUnique() {
        let results = BookingService.instance.listHotels(
            query: "test",
            checkIn: "2025-09-01",
            checkOut: "2025-09-05",
            guests: 1
        )
        let ids = results.compactMap { $0["listingSelectionId"] as? String }
        XCTAssertEqual(ids.count, Set(ids).count, "Selection IDs should be unique")
    }
}
