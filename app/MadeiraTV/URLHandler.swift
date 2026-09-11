import Foundation

/// Handles the `madeira://` deep link — the RetroArch-style way to open
/// a game from another app: `madeira://launch/<name>` matches a game in
/// the library by display name and returns the entry to launch, or nil.
final class URLHandler {

    static let shared = URLHandler()

    /// Returns the game to launch for a madeira:// URL, if any.
    /// Supported forms:
    ///   madeira://launch/<name>
    ///   madeira://open?name=<name>
    func game(for url: URL) -> GameEntry? {
        guard url.scheme?.lowercased() == "madeira" else { return nil }
        let library = GameLibrary.shared

        if url.host?.lowercased() == "launch" {
            let name = url.pathComponents.dropFirst().joined(separator: "/")
                .removingPercentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return nil }
            return match(name: name, in: library)
        }
        if url.host?.lowercased() == "open" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let name = comps?.queryItems?.first(where: { $0.name == "name" })?.value {
                return match(name: name, in: library)
            }
        }
        return nil
    }

    private func match(name: String, in library: GameLibrary) -> GameEntry? {
        // Exact name first, then case-insensitive, then suffix match.
        if let g = library.games.first(where: { $0.name == name }) { return g }
        if let g = library.games.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return g
        }
        let lower = name.lowercased()
        return library.games.first { $0.name.lowercased().contains(lower) }
    }
}