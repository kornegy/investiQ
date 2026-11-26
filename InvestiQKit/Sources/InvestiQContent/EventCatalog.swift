import Foundation
import InvestiQCore

/// Bundled economic calendar: only dates verified against the institutions' own pages, each with its
/// source URL and verification date (docs/DATA_PROVIDERS.md §Calendar). Times only where the source gives them.
public enum EventCatalog {
    private struct File: Decodable {
        var version: Int
        var verifiedOn: LocalDate
        var events: [EconomicEvent]
    }

    public static func load() throws -> (events: [EconomicEvent], verifiedOn: LocalDate) {
        guard let url = Bundle.module.url(forResource: "events", withExtension: "json", subdirectory: "Resources/calendar") else {
            throw LessonCatalogError.missingResource("calendar")
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return (file.events.sorted { $0.date < $1.date }, file.verifiedOn)
    }
}
