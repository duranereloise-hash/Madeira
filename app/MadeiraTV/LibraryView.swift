import SwiftUI
import UIKit

// MARK: - Game card

/// Focusable card for the library grid. Grows and glows when focused
/// (standard tvOS "game center" card behaviour), shows a cover or a
/// generated initial.
struct GameCard: View {
    let game: GameEntry
    @ObservedObject var library: GameLibrary

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                if let url = library.coverURL(for: game),
                   let img = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    Text(String(game.name.prefix(1)).uppercased())
                        .font(.system(size: 64, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(width: 280, height: 158)
            .shadow(color: .black.opacity(0.5), radius: 12, y: 8)

            Text(game.name)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 280)
                .foregroundStyle(.primary)
        }
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .shadow(color: isFocused ? .accentColor.opacity(0.6) : .clear, radius: isFocused ? 22 : 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isFocused)
        .focusable()
    }
}

// MARK: - Library view

/// The tvOS main menu: a "Now Playing" hero row, the game grid, and a
/// services/diagnostics section. Everything is driven by the focus
/// engine — no touch anywhere.
struct LibraryView: View {
    @ObservedObject var library = GameLibrary.shared
    @ObservedObject var jit = JITStateModel.shared

    @State private var showServices = false
    @State private var running: GameEntry?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    header
                    if let hero = library.games.first {
                        heroRow(hero)
                    }
                    gamesSection
                    servicesSection
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 40)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationDestination(item: $running) { game in
                TVRunner(game: game)
            }
            .sheet(isPresented: $showServices) { ServicesView() }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Madeira TV")
                    .font(.system(size: 52, weight: .heavy, design: .rounded))
                Text(jitBadgeText)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(jitBadgeColor)
            }
            Spacer()
            Text(library.games.count == 1 ? "1 game" : "\(library.games.count) games")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var jitBadgeText: String {
        switch jit.state {
        case .unknown: return "JIT: checking…"
        case .debuggerReady: return "JIT: debugger attached"
        case .poolReady(let mb, let method): return "JIT: pool ready (\(mb) MB, \(method))"
        case .required: return "JIT: none — launch from StikDebug or attach Xcode"
        case .failed(let msg): return "JIT: \(msg)"
        }
    }

    private var jitBadgeColor: Color {
        switch jit.state {
        case .poolReady: return .green
        case .debuggerReady: return .yellow
        case .required, .failed: return .orange
        case .unknown: return .secondary
        }
    }

    private func heroRow(_ game: GameEntry) -> some View {
        Button {
            running = game
        } label: {
            HStack(spacing: 28) {
                if let url = library.coverURL(for: game),
                   let img = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 320, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(colors: [.accentColor.opacity(0.7), .accentColor.opacity(0.25)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 320, height: 180)
                        .overlay {
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 64))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("NOW PLAYING")
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .foregroundStyle(.accentColor)
                    Text(game.name)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    Text("Press to launch")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(white: 0.11))
            )
        }
        .buttonStyle(.card)
    }

    private var gamesSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("Library")
            if library.games.isEmpty {
                Text(library.lastScanError == nil
                     ? "No games yet. Open Services and upload an .exe."
                     : "Scan failed: \(library.lastScanError!)")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 60)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: [GridItem(.fixed(230))], spacing: 28) {
                        ForEach(library.games) { game in
                            GameCard(game: game, library: library)
                                .onTapGesture { running = game }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .focusSection()
            }
        }
    }

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("Services")
            HStack(spacing: 28) {
                Button {
                    showServices = true
                } label: {
                    Label("Upload games", systemImage: "network")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    library.refresh()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 30, weight: .bold, design: .rounded))
    }
}

// MARK: - Services / upload screen

/// Shows the HTTP host address and port, plus a short how-to. The actual
/// server lives in UploadHost (started at app launch).
struct ServicesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var host = UploadHost.shared

    var body: some View {
        VStack(spacing: 24) {
            Text("Upload games")
                .font(.system(size: 42, weight: .bold, design: .rounded))
            VStack(spacing: 8) {
                Text("Open this address on your computer or phone:")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(host.displayURL)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.14)))
            }
            Text("Games are saved to Documents/Games and appear in the "
                 + "library automatically. You can also open a game on Apple TV "
                 + "from another app with madeira://launch/<game>")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 700)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}