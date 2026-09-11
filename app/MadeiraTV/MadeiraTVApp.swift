import SwiftUI
import UIKit

@main
struct MadeiraTVApp: App {
    @State private var launchTarget: GameEntry?

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .onOpenURL { url in
                    // madeira://launch/<name> — open a game straight from
                    // another app, RetroArch-style.
                    if let game = URLHandler.shared.game(for: url) {
                        launchTarget = game
                    }
                }
                .sheet(item: $launchTarget) { game in
                    TVRunner(game: game)
                }
        }
    }

    init() {
        // Keep the box awake while a game is presenting.
        UIApplication.shared.isIdleTimerDisabled = true
        // Gamepad is the primary input on Apple TV — start early.
        GamepadManager.shared.start()
        // HTTP upload host (RetroArch-style content delivery).
        UploadHost.shared.start()
        // JIT status badge in the menu.
        JITStateModel.shared.refresh()
    }
}