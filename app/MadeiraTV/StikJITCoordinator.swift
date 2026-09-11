import Foundation

/// Coordination with the built-in StikJIT framework (the Swift/Rust
/// XCFramework from github.com/StikDebug/StikJIT) so JIT can be enabled
/// entirely in-app on tvOS, with no external StikDebug app.
///
/// Per the official INTEGRATION.md, StikJIT needs a separate helper
/// process (a process that attaches a debugger to itself deadlocks), so
/// the real work runs in a helper app extension; this coordinator in the
/// main app is the host side:
///
///   Host app (MadeiraTV, get-task-allow, pairing file)
///       │  XPC / NotificationCenter (app group)
///       ▼
///   Helper extension (StikJIT.framework, DDI cache, blocking enableJIT)
///
/// The helper extension target is not part of this repo yet — the XCFramework
/// must be built first (StikJIT's own build: xcodegen + xcodebuild archive +
/// create-xcframework), then a small tvOS "App Intent"/"Extension" target is
/// added that links StikJIT.framework and runs its synchronous APIs on a
/// serial queue. This file wires that shape into MadeiraTV without the
/// helper actually being compiled in until then.
///
/// Recovery / fallback: if this path is unavailable (no helper, no pairing
/// file), TVJIT simply continues to the next acquisition method instead of
/// blocking the game launch.
final class StikJITCoordinator {

    static let shared = StikJITCoordinator()

    private(set) var lastError: String?

    /// Where the user must place a pairing file (AFC/Finder/idevice_pair),
    /// same as the iOS convention: Documents/StikJIT/pairingFile.plist
    static var pairingFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT/pairingFile.plist")
    }

    static var hasPairingFile: Bool {
        FileManager.default.fileExists(atPath: pairingFileURL.path)
    }

    static var isTXMPresent: Bool {
        // StikJIT exposes StikJIT.isTXMPresent; the helper reports it. Until
        // the helper is linked, report unknown as "not present" so the
        // coordinator does not block on it.
        false
    }

    private init() {}

    /// Runs the helper extension's enableJIT (synchronously on the helper's
    /// serial queue per INTEGRATION.md), then builds the pool from the RX
    /// address the debug server prepared.
    ///
    /// Because the helper extension does not exist in this snapshot, this
    /// reports the exact prerequisite that is missing. When the helper is
    /// added, this becomes:
    ///
    ///     StikJIT.enableJIT(targetPID: getpid(),
    ///                       pairingFile: tempPairingFile,
    ///                       ddiPaths: paths,
    ///                       script: .universal,
    ///                       forceScript: forceScript,
    ///                       preparationProgress: reportStage,
    ///                       progress: reportLog)
    ///
    /// and then `TVJIT.acquire()` is called again; the BRK-based
    /// jit26_prepare_region will now succeed because the debug server is
    /// attached and serving the universal script.
    func acquirePool() -> (rx: UnsafeMutableRawPointer,
                           rw: UnsafeMutableRawPointer,
                           size: Int)? {
        guard Self.hasPairingFile else {
            lastError = "No pairing file at Documents/StikJIT/pairingFile.plist"
            return nil
        }
        guard checkAppEntitlement("get-task-allow") else {
            lastError = "get-task-allow missing — reinstall with a signing method that keeps it"
            return nil
        }
        lastError = "StikJIT helper extension not linked yet — build StikJIT.xcframework and add the tvOS helper target (see PORT_PLAN.md §6)"
        return nil
    }
}