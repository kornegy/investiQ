import Foundation
import InvestiQCore

/// Bundled broker directory: alphabetical (no ranking, no referral or affiliate links).
public enum BrokerCatalog {
    private struct File: Decodable {
        var version: Int
        var verifiedOn: LocalDate
        var brokers: [BrokerEntry]
    }

    public static func load() throws -> (brokers: [BrokerEntry], verifiedOn: LocalDate) {
        guard let url = Bundle.module.url(forResource: "brokers", withExtension: "json", subdirectory: "Resources/brokers") else {
            throw LessonCatalogError.missingResource("brokers")
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return (file.brokers.sorted { $0.brand.localizedCaseInsensitiveCompare($1.brand) == .orderedAscending }, file.verifiedOn)
    }
}
