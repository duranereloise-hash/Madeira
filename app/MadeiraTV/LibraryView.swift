import SwiftUI

struct SwitchLauncherView: View {
    @ObservedObject var library = GameLibrary.shared
    @ObservedObject var jit = JITStateModel.shared
    @ObservedObject var host = UploadHost.shared

    @State private var selectedTab: Tab = .games
    @State private var running: GameEntry?
    @State private var showUpload = false

    enum Tab: String, CaseIterable {
        case games = "Games"
        case settings = "Settings"

        var icon: String {
            switch self {
            case .games: return "square.grid.3x3.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch selectedTab {
                case .games: gamesView
                case .settings: settingsView
                }
            }
            .background(Color(white: 0.06).ignoresSafeArea())
            .navigationDestination(item: $running) { game in
                TVRunner(game: game)
            }
        }
        .overlay(alignment: .bottom) { tabBar }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.3)) { selectedTab = tab }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 22, weight: .semibold))
                        Text(tab.rawValue)
                            .font(.system(.caption2, design: .rounded).weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(selectedTab == tab ? .white : .white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .background(Rectangle().fill(Color(white: 0.1)))
    }

    private var gamesView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                headerBar
                if let first = library.games.first { heroCard(first) }
                gameGrid
                Spacer(minLength: 80)
            }
            .padding(.horizontal, 40)
            .padding(.top, 20)
        }
    }

    private var headerBar: some View {
        HStack {
            HStack(spacing: 12) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.accentColor)
                Text("SwitchTV")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
            }
            Spacer()
            HStack(spacing: 16) {
                Text("\(library.games.count)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color(white: 0.12)))
                Button { showUpload = true } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 32))
                }.buttonStyle(.plain)
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 32)).foregroundStyle(.accentColor)
            }
        }
    }

    private func heroCard(_ game: GameEntry) -> some View {
        Button { running = game } label: {
            HStack(spacing: 28) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LinearGradient(colors: [.accentColor.opacity(0.6), .accentColor.opacity(0.15)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 340, height: 192)
                    if let url = library.coverURL(for: game),
                       let img = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 340, height: 192)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    } else {
                        Image(systemName: "play.fill").font(.system(size: 60))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }.shadow(color: .accentColor.opacity(0.4), radius: 20, y: 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text("NOW PLAYING").font(.system(.caption, design: .rounded).weight(.bold))
                        .foregroundStyle(.accentColor)
                    Text(game.name).font(.system(size: 38, weight: .bold, design: .rounded))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Image(systemName: "gamecontroller.fill")
                        Text("Press A to launch")
                    }.font(.system(.subheadline, design: .rounded)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
                .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(white: 0.1)))
        }.buttonStyle(.card)
    }

    private var gameGrid: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your Games").font(.system(size: 28, weight: .bold, design: .rounded))
            if library.games.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 280))], spacing: 24) {
                    ForEach(library.games) { game in
                        GameTile(game: game, library: library) { running = game }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("No games yet").font(.title2.weight(.semibold))
            Text("Tap + to upload an .exe file").font(.subheadline).foregroundStyle(.secondary)
            Button { showUpload = true } label: {
                Label("Upload", systemImage: "network")
                    .padding(.horizontal, 24).padding(.vertical, 10)
            }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings").font(.system(size: 38, weight: .bold, design: .rounded)).padding(.top, 20)
                VStack(spacing: 0) {
                    settingsRow("JIT Status", value: jitBadgeText, color: jitBadgeColor)
                    Divider().padding(.leading, 16)
                    settingsRow("Controllers", value: "\(GamepadManager.shared.connectedCount)")
                    Divider().padding(.leading, 16)
                    settingsRow("Upload Addr.", value: host.displayURL)
                    Divider().padding(.leading, 16)
                    settingsRow("StikJIT", value: StikJITCoordinator.hasPairingFile ? "Paired" : "Not set",
                                color: StikJITCoordinator.hasPairingFile ? .green : .orange)
                }.background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.1)))
                Text("SwitchTV — powered by Madeira/Wine/FEX/DXMT")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.padding(.horizontal, 40)
            Spacer(minLength: 80)
        }
    }

    private func settingsRow(_ label: String, value: String, color: Color = .secondary) -> some View {
        HStack {
            Text(label).font(.body.weight(.medium))
            Spacer()
            Text(value).font(.subheadline.monospaced()).foregroundStyle(color)
        }.padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var jitBadgeText: String {
        switch jit.state {
        case .unknown: return "Checking..."
        case .debuggerReady: return "Debugger attached"
        case .poolReady(let mb, let method): return "\(mb) MB (\(method))"
        case .required: return "None — attach debugger"
        case .failed(let msg): return "Failed: \(msg)"
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
}

struct GameTile: View {
    let game: GameEntry
    let library: GameLibrary
    let action: () -> Void

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.08)],
                                             startPoint: .top, endPoint: .bottom))
                    if let url = library.coverURL(for: game),
                       let img = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 32)).foregroundStyle(.white.opacity(0.3))
                            Text(String(game.name.prefix(1)).uppercased())
                                .font(.system(size: 40, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white.opacity(0.15))
                        }
                    }
                }
                .frame(width: 260, height: 146)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                Text(game.name)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width: 260).foregroundStyle(.primary)
            }
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .shadow(color: isFocused ? .accentColor.opacity(0.5) : .clear, radius: isFocused ? 18 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isFocused)
        }.buttonStyle(.plain).focusable()
    }
}