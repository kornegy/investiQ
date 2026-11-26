import SwiftUI

extension L10n {
    /// A localisation key assembled at run time, e.g. `L10n.key("news.type", type.rawValue)` →
    /// `news.type.officialRelease`.
    ///
    /// Never write `LocalizedStringKey("news.type.\(type.rawValue)")`: inside an interpolated literal the
    /// value becomes a format argument, so SwiftUI looks up the key `news.type.%@`, finds nothing and puts
    /// the raw key on screen. `scripts/check_l10n.py` rejects that pattern.
    nonisolated static func key(_ parts: String...) -> LocalizedStringKey {
        LocalizedStringKey(parts.joined(separator: "."))
    }
}
