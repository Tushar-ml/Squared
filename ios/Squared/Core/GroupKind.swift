import Foundation

/// What a group is for. Drives icons, name and expense suggestions, and how we refer to the people in it.
/// DIRECT is a hidden 1:1 "friend" group made from the Friends section, never picked by hand.
enum GroupKind: String, CaseIterable, Identifiable {
    case home = "HOME", trip = "TRIP", couple = "COUPLE", friends = "FRIENDS", work = "WORK", event = "EVENT", other = "OTHER"
    case direct = "DIRECT"

    var id: String { rawValue }
    static var pickable: [GroupKind] { allCases.filter { $0 != .direct } }

    init(_ raw: String?) { self = GroupKind(rawValue: raw ?? "") ?? .other }

    var label: String {
        switch self {
        case .home: String(localized: "Home")
        case .trip: String(localized: "Trip")
        case .couple: String(localized: "Couple")
        case .friends: String(localized: "Friends")
        case .work: String(localized: "Work")
        case .event: String(localized: "Event")
        case .other: String(localized: "Other")
        case .direct: String(localized: "Friend")
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .trip: "airplane"
        case .couple: "heart.fill"
        case .friends: "person.3.fill"
        case .work: "briefcase.fill"
        case .event: "party.popper.fill"
        case .other: "square.grid.2x2.fill"
        case .direct: "person.fill"
        }
    }

    /// Plural noun for the other people in the group, used in invites and empty states.
    var people: String {
        switch self {
        case .home: String(localized: "flatmates")
        case .trip: String(localized: "travel buddies")
        case .couple, .direct: String(localized: "partner")
        case .friends: String(localized: "friends")
        case .work: String(localized: "colleagues")
        case .event, .other: String(localized: "people")
        }
    }

    var nameIdeas: [String] {
        switch self {
        case .home: ["Flat 4B", "Home", "The Den"]
        case .trip: ["Goa trip", "Manali 2026", "Weekend getaway"]
        case .couple: ["Us", "Home budget", "Date nights"]
        case .friends: ["The gang", "College friends", "Sunday cricket"]
        case .work: ["Team lunches", "Office cab", "Desk 4"]
        case .event: ["Riya's birthday", "Wedding", "Farewell party"]
        case .other, .direct: ["Shared stuff", "Club", "Society"]
        }
    }

    var namePlaceholder: String { nameIdeas.first ?? "" }

    var expenseIdeas: [(String, String)] {
        switch self {
        case .home: [("Rent", "house.fill"), ("Wifi", "wifi"), ("Electricity", "bolt.fill"),
                     ("Groceries", "cart.fill"), ("Cook / maid", "person.fill"), ("Gas cylinder", "flame.fill")]
        case .trip: [("Hotel", "bed.double.fill"), ("Flights", "airplane"), ("Cab", "car.fill"),
                     ("Dinner", "fork.knife"), ("Tickets", "ticket.fill"), ("Fuel", "fuelpump.fill")]
        case .couple: [("Groceries", "cart.fill"), ("Dinner", "fork.knife"), ("Rent", "house.fill"),
                       ("Movie", "film.fill"), ("Gift", "gift.fill"), ("Bills", "bolt.fill")]
        case .friends, .direct: [("Dinner", "fork.knife"), ("Drinks", "wineglass.fill"), ("Movie", "film.fill"),
                                 ("Cab", "car.fill"), ("Gift", "gift.fill"), ("Turf", "sportscourt.fill")]
        case .work: [("Lunch", "fork.knife"), ("Chai", "cup.and.saucer.fill"), ("Cab", "car.fill"),
                     ("Snacks", "takeoutbag.and.cup.and.straw.fill"), ("Gift", "gift.fill"), ("Team outing", "person.3.fill")]
        case .event: [("Venue", "building.2.fill"), ("Cake", "birthday.cake.fill"), ("Decor", "sparkles"),
                      ("Food", "fork.knife"), ("Gift", "gift.fill"), ("Music", "music.note")]
        case .other: [("Dinner", "fork.knife"), ("Groceries", "cart.fill"), ("Cab", "car.fill"),
                      ("Bills", "bolt.fill"), ("Gift", "gift.fill"), ("Tickets", "ticket.fill")]
        }
    }

    /// Couples and 1:1 friends are always two people, so skip the "how many" question.
    var fixedSize: Int? { self == .couple || self == .direct ? 2 : nil }
}
