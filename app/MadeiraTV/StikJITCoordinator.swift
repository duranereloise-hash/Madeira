import Foundation

/// Host-side coordination with the built-in StikJIT helper extension.
///
/// Per the official INTEGRATION.md, enabling JIT for yourself from inside
/// the same process deadlocks (a process cannot attach a debugger to
/// itself), so StikJIT runs in a separate helper app extension:
///
///   MadeiraTV (host, get-task-allow, pairing file, this class)
///        │  XPC / app group (com.willfaust.madeira-tv.helper)
///        ▼
///   MadeiraTVHelper (app extension, links StikJITTV.framework,
///                    does the blocking enableJIT on a serial queue)
///
/// The helper then attaches its debug server to OUR pid over the RSD
/// tunnel, which means our own JITAllocator.c BRK #0xf00d protocol
/// (jit26_prepare_region) suddenly works — so after enableBuiltIn()
/// succeeds, TVJIT allocates the pool via the BRK path and everything
/// downstream is identical to the StikDebug case.
///
/// Because the helper extension is compiled as a separate target in the
/// Xcode project (see BUILDING.md), this coordinator talks to it over an
/// App Group + XPC connection. The helper target is added to the project
/// once StikJITTV.xcframework exists; until then this class reports the
/// exact missing prerequisite instead of failing silently.
final class StikJITCoordinator {

    static let shared = StikJITCoordinator()

    private(set) var lastError: String?

    // App Group shared between host and helper (same as the iOS convention).
    private static let appGroupID = "group.com.willfaust.madeira-tv"
    private static let xpcMachService = "com.willfaust.madeira-tv.helper"

    /// Where the user must place a pairing file (AFC/Finder/idevice_pair),
    /// Documents/StikJIT/pairingFile.plist — also uploadable via the HTTP
    /// host (POST /pairing).
    static var pairingFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT/pairingFile.plist")
    }

    static var hasPairingFile: Bool {
        FileManager.default.fileExists(atPath: pairingFileURL.path)
    }

    /// TXM presence is reported by the helper once connected; until then
    /// we cannot know (tvOS has no IOKit path for it).
    static var isTXMPresent: Bool? { nil }

    private var connection: NSXPCConnection?

    private init() {}

    /// Full preflight + enableJIT flow, matching INTEGRATION.md's
    /// "Built-in StikJIT: Gate every entry point":
    ///   1. get-task-allow present?
    ///   2. pairing file present?
    ///   3. helper reachable over XPC?
    ///   4. helper runs prepareDevice + enableJIT (blocking, serial queue)
    ///   5. on success our BRK protocol becomes servable — pool next.
    func enableBuiltIn() -> Bool {
        lastError = nil

        guard checkAppEntitlement("get-task-allow") else {
            lastError = "get-task-allow missing — reinstall with a signing method that keeps it (SideStore/Sideloadly)"
            return false
        }
        guard Self.hasPairingFile else {
            lastError = "No pairing file at Documents/StikJIT/pairingFile.plist (upload via Services → 'Upload pairing file')"
            return false
        }

        // The helper target is not linked into this snapshot (needs
        // StikJITTV.xcframework first — see BUILDING.md). When it exists,
        // this block is replaced by the XPC call below.
        guard Self.helperExtensionExists() else {
            lastError = "Helper extension not found — add the MadeiraTVHelper target with StikJITTV.framework (BUILDING.md §7)"
            return false
        }

        let ok = callHelper()
        if !ok && lastError == nil {
            lastError = "Helper enableJIT returned failure (see helper log)"
        }
        return ok
    }

    /// Whether the helper extension is embedded in this build.
    private static func helperExtensionExists() -> Bool {
        // The helper is a separate .appex; look it up relative to the main
        // bundle (PlugIns/…). Return false until the target is added.
        if let plugins = Bundle.main.builtInPlugInsURL {
            let appex = plugins.appendingPathComponent("MadeiraTVHelper.appex")
            if FileManager.default.fileExists(atPath: appex.path) { return true }
        }
        return false
    }

    /// XPC round-trip to the helper. The helper performs the blocking
    /// StikJIT.prepareDevice + enableJIT on its own serial queue and
    /// reports progress + completion. Until the helper target exists we
    /// never reach here (helperExtensionExists() is false).
    private func callHelper() -> Bool {
        let conn = NSXPCConnection(machServiceName: Self.xpcMachService)
        conn.remoteObjectInterface = NSXPCInterface(with: StikJITHelperProtocol.self)
        conn.resume()
        self.connection = conn
        defer {
            conn.invalidate()
            self.connection = nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        var lastStage = "starting"

        let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.lastError = "Helper connection failed: \(error.localizedDescription)"
            semaphore.signal()
        } as? StikJITHelperProtocol

        proxy?.enableJITForProcess(
            targetPID: getpid(),
            pairingFileURL: Self.pairingFileURL,
            ddiBaseURL: Self.ddiBaseURL
        ) { [weak self] success, message in
            if !success { self?.lastError = message }
            result = success
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 120)
        return result
    }

    /// DDI cache lives in the shared App Group container so both the host
    /// and the helper see the same mounted/dowloaded Developer Disk Image.
    static var ddiBaseURL: URL {
        let fm = FileManager.default
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return group.appendingPathComponent("StikJIT", isDirectory: true)
        }
        return fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
    }
}

/// The XPC interface the helper extension implements. Keep it in @objc
/// protocol form so NSXPCInterface can marshal it.
@objc protocol StikJITHelperProtocol {
    func enableJITForProcess(targetPID: Int32,
                             pairingFileURL: URL,
                             ddiBaseURL: URL,
                             reply: @escaping (Bool, String) -> Void)
}