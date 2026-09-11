import Foundation
import SwiftUI

// MARK: - Game entry

struct GameEntry: Identifiable, Hashable {
    let id: String          // stable: relative unix path under Documents/Games/
    let name: String        // display name (exe stem)
    let exeRelPath: String  // relative path to the .exe within Games/
    let coverPath: String?  // relative path to cover image, if any
    let sizeBytes: Int64
    let modified: Date

    /// Windows path Wine understands, e.g. C:\Games\Thumper\THUMPER_win10.exe
    var windowsPath: String {
        "C:\\Games\\" + exeRelPath.replacingOccurrences(of: "/", with: "\\")
    }
}

// MARK: - Game library

/// Scans Documents/Games for *.exe (recursively) and pairs each with a cover.
final class GameLibrary: ObservableObject {
    static let shared = GameLibrary()

    static var gamesDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Games", isDirectory: true)
    }

    @Published private(set) var games: [GameEntry] = []
    @Published private(set) var lastScanError: String?

    private let fm = FileManager.default

    private init() {
        try? fm.createDirectory(at: Self.gamesDir, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        let root = Self.gamesDir
        do {
            let exes = try fm.subpathsOfDirectory(atPath: root.path)
                .filter { $0.lowercased().hasSuffix(".exe") }
            var entries: [GameEntry] = []
            for rel in exes {
                let full = root.appendingPathComponent(rel)
                guard let attrs = try? fm.attributesOfItem(atPath: full.path) else { continue }
                let cover = Self.coverFor(exeRelative: rel, in: root)
                entries.append(GameEntry(
                    id: rel,
                    name: (rel as NSString).lastPathComponent
                        .replacingOccurrences(of: ".exe", with: "", options: .caseInsensitive),
                    exeRelPath: rel,
                    coverPath: cover,
                    sizeBytes: (attrs[.size] as? Int64) ?? 0,
                    modified: (attrs[.modificationDate] as? Date) ?? .distantPast
                ))
            }
            entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            games = entries
            lastScanError = nil
        } catch {
            games = []
            lastScanError = error.localizedDescription
        }
    }

    /// Finds a cover next to the exe or in the same folder.
    private static func coverFor(exeRelative: String, in root: URL) -> String? {
        let base = (exeRelative as NSString).deletingLastPathComponent
        let fm = FileManager.default
        let candidates = ["cover.png", "cover.jpg", "cover.jpeg", "icon.png", "icon.jpg"]
        for c in candidates {
            let p = base.isEmpty ? c : "\(base)/\(c)"
            if fm.fileExists(atPath: root.appendingPathComponent(p).path) { return p }
        }
        return nil
    }

    func coverURL(for game: GameEntry) -> URL? {
        guard let p = game.coverPath else { return nil }
        return Self.gamesDir.appendingPathComponent(p)
    }

    func entry(forRelativePath rel: String) -> GameEntry? {
        games.first { $0.exeRelPath == rel }
    }
}

// MARK: - JIT state

enum JITState: Equatable {
    case unknown
    case debuggerReady       // CS_DEBUGGED set — a debugger is attached
    case poolReady(Int, String)  // JIT pool ready (MB, method)
    case required            // no JIT source available
    case failed(String)
}

@MainActor
final class JITStateModel: ObservableObject {
    static let shared = JITStateModel()
    @Published var state: JITState = .unknown

    func refresh() {
        if let p = TVJIT.current {
            state = .poolReady(p.size / 1024 / 1024, p.method.rawValue)
        } else if TVJIT.lastFailure != nil {
            state = .failed(TVJIT.lastFailure ?? "unknown")
        } else if jit_check_debugged() {
            state = .debuggerReady
        } else {
            state = .required
        }
    }
}