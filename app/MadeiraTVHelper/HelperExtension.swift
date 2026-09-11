import Foundation
import StikJITTV

/// MadeiraTVHelper — the helper App Extension that runs the blocking
/// StikJIT.enableJIT flow for the host (MadeiraTV).
///
/// Why a separate process? INTEGRATION.md: "a process that attaches a
/// debugger to itself deadlocks". So the actual RSD tunnel + DDI mount +
/// debugserver attach + universal.js script execution happen HERE, in the
/// extension, while the host app supplies its own pid via XPC. After the
/// script runs, the debug server is attached to the HOST and the host's
/// own BRK #0xf00d protocol (jit26_prepare_region) becomes servable — the
/// host then allocates its JIT pool as in the StikDebug case.
///
/// This extension is the tvOS counterpart of the iOS "helper extension"
/// from StikJIT's integration guide. It links StikJITTV.framework (built
/// from the StikJIT repo) and performs the work on a dedicated serial
/// queue, per the guide's requirements.
@main
final class MadeiraTVHelper {

    static let machServiceName = "com.willfaust.madeira-tv.helper"

    // StikJIT's synchronous APIs must run on one dedicated serial queue.
    private static let workQueue = DispatchQueue(label: "com.willfaust.madeira-tv.helper.jit")

    private static var connection: NSXPCConnection?

    static func main() {
        // Set up the XPC listener for the mach service the host connects to.
        let listener = NSXPCListener(machServiceName: machServiceName)
        let delegate = HelperXPCDelegate()
        listener.delegate = delegate
        listener.resume()
        delegate.listener = listener

        // Keep the process alive: the extension runs until the host drops
        // the connection (the delegate ends the process then).
        dispatchMain()
    }
}

/// Implements the NSXPCListenerDelegate and the @objc protocol the host
/// calls (StikJITHelperProtocol from StikJITCoordinator.swift).
final class HelperXPCDelegate: NSObject, NSXPCListenerDelegate, StikJITHelperProtocol {

    var listener: NSXPCListener?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: StikJITHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func enableJITForProcess(targetPID: Int32,
                             pairingFileURL: URL,
                             ddiBaseURL: URL,
                             reply: @escaping (Bool, String) -> Void) {
        MadeiraTVHelper.workQueue.async {
            do {
                try StikJIT.enableJIT(
                    targetPID: targetPID,
                    pairingFile: pairingFileURL,
                    ddiPaths: DDIPaths.default(in: ddiBaseURL),
                    script: .universal,
                    forceScript: false,
                    preparationProgress: { _ in },
                    progress: { _ in }
                )
                reply(true, "JIT enabled for pid \(targetPID)")
            } catch {
                reply(false, error.localizedDescription)
            }
            // One-shot helper: exit after the (long) JIT operation. The host
            // re-launches us per game launch. Match INTEGRATION.md's
            // "one serial queue, synchronous enableJIT".
            self.listener?.stop()
            exit(0)
        }
    }
}