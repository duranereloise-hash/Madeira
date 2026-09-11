import SwiftUI
import UIKit

/// Full-screen runner for a launched game. Mirrors the iOS
/// runWineFullSequence (ContentView.swift): JIT pool via the BRK
/// protocol, wineserver, Wine, wait-for-first-present, then detach.
/// Menu / onExitCommand stops Wine and returns to the library.
struct TVRunner: View {
    let game: GameEntry

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var jit = JITStateModel.shared
    @State private var phase = "Preparing…"
    @State private var poolReady = false
    @State private var running = false
    @State private var showExitHint = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                Text(game.name)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text(phase)
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.secondary)
                if showExitHint {
                    Text("Press  Menu  to stop and return")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
            }
        }
        .onAppear { launch() }
        .onExitCommand { stop() }
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Launch sequence

    private func launch() {
        guard !poolReady else { return }
        phase = "Checking JIT…"
        jit.refresh()

        // The ladder in TVJIT.acquire() decides HOW to get the pool:
        // entitlement → MAP_JIT under a debugger → StikDebug BRK. It is
        // cached for the process lifetime, so subsequent launches are free.
        if let p = TVJIT.current {
            apply(pool: p)
            return
        }
        phase = "Acquiring JIT pool…"
        jit_install_trap_handler()

        DispatchQueue.global(qos: .userInitiated).async {
            guard let pool = TVJIT.acquire() else {
                DispatchQueue.main.async {
                    phase = "JIT unavailable: \(TVJIT.lastFailure ?? "unknown reason")"
                    jit.refresh()
                }
                return
            }
            DispatchQueue.main.async { self.apply(pool: pool) }
            self.startWine()
        }
    }

    private func apply(pool: TVJIT.JITPool) {
        poolReady = true
        jit.state = .poolReady(pool.size / 1024 / 1024)
        setenv("WINE_IOS_JIT_RX", String(format: "%lx", Int(bitPattern: pool.rx)), 1)
        setenv("WINE_IOS_JIT_RW", String(format: "%lx", Int(bitPattern: pool.rw)), 1)
        setenv("WINE_IOS_JIT_SIZE", String(format: "%lx", pool.size), 1)
        setenv("MADEIRA_EXE", game.windowsPath, 1)
        unsetenv("MADEIRA_ARGS")
        setenv("MADEIRA_USE_ARM64EC", "1", 1)
        phase = "JIT via \(pool.method.rawValue) — starting wineserver…"
    }

    private func startWine() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let prefix = docs.appendingPathComponent("wine").path
        let rc = wineserver_start(prefix)
        DispatchQueue.main.async {
            phase = rc == 0 ? "Wineserver up — starting Wine…" : "Wineserver failed (\(rc))"
        }
        guard rc == 0 else { return }
        Thread.sleep(forTimeInterval: 2.0)
        ws_log_quiet = 1
        let wrc = wine_process_start(prefix)
        DispatchQueue.main.async {
            running = wrc == 0
            phase = wrc == 0 ? "Running — first frames…" : "Wine failed to start"
        }
        guard wrc == 0 else { return }

        // Wait for first present (or cap), then detach the debugger like iOS.
        // Detach is only meaningful for a debugger-backed pool; skip it when
        // the pool came from the entitlement (no debugger involved at all).
        let pollStart = CFAbsoluteTimeGetCurrent()
        var presentingSince: CFAbsoluteTime?
        while wine_process_is_running() != 0 {
            Thread.sleep(forTimeInterval: 0.25)
            let now = CFAbsoluteTimeGetCurrent()
            if presentingSince == nil, madeira_get_present_count() >= 1 {
                presentingSince = now
                DispatchQueue.main.async { phase = "Presenting — detaching in 20s" }
            }
            if let t = presentingSince, now - t > 20.0 { break }
            if now - pollStart > 1200.0 { break }
        }
        if TVJIT.current?.method != .entitlement {
            TVJIT.detach()
        }
        DispatchQueue.main.async {
            phase = running ? "Running" : "Wine exited"
            ws_log_quiet = 0
            showExitHint = running
        }
    }

    private func stop() {
        guard running || poolReady else {
            dismiss()
            return
        }
        phase = "Stopping…"
        DispatchQueue.global(qos: .userInitiated).async {
            wineserver_stop()
            Thread.sleep(forTimeInterval: 1.0)
            DispatchQueue.main.async { dismiss() }
        }
    }
}