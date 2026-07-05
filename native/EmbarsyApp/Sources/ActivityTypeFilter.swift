import Foundation

enum ActivityTypeFilter: String, CaseIterable, Identifiable, Hashable {
    case embedding
    case write
    case read

    var id: String { rawValue }

    var title: String {
        switch self {
        case .embedding: "Embedding request"
        case .write: "Write"
        case .read: "Read"
        }
    }

    var operation: ActivityOperation {
        switch self {
        case .embedding: .embedding
        case .write: .write
        case .read: .read
        }
    }
}

struct ActivityTypeFilterState {
    private(set) var selectedTypes: Set<ActivityTypeFilter>

    init(selectedTypes: Set<ActivityTypeFilter> = Set(ActivityTypeFilter.allCases)) {
        self.selectedTypes = selectedTypes.isEmpty ? Set(ActivityTypeFilter.allCases) : selectedTypes
    }

    var selectedTitle: String {
        if selectedTypes.count == ActivityTypeFilter.allCases.count {
            return "All activity types"
        }
        return ActivityTypeFilter.allCases
            .filter { selectedTypes.contains($0) }
            .map(\.title)
            .joined(separator: ", ")
    }

    func includes(_ event: ActivityEvent) -> Bool {
        selectedTypes.contains { $0.operation == event.operation }
    }

    func filteredEvents(from events: [ActivityEvent], onlyErrors: Bool = false) -> [ActivityEvent] {
        events.filter { event in
            includes(event) && (!onlyErrors || event.error)
        }
    }

    mutating func toggle(_ type: ActivityTypeFilter) {
        if selectedTypes.contains(type) {
            guard selectedTypes.count > 1 else { return }
            selectedTypes.remove(type)
        } else {
            selectedTypes.insert(type)
        }
    }
}
