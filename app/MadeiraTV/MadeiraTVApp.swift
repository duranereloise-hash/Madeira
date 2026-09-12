import SwiftUI
import UIKit

@main
struct SwitchTVApp: App {
    @State private var launchTarget: GameEntry?

    var body: some Scene {
        WindowGroup {
            SwitchLauncherView()
                .onOpenURL { url in
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
        UIApplication.shared.isIdleTimerDisabled = true
        GamepadManager.shared.start()
        UploadHost.shared.start()
        JITStateModel.shared.refresh()
    }
}