import SwiftUI
import UIKit
import Metal
import QuartzCore

/// tvOS host for the presenting CAMetalLayer.
///
/// This is the tvOS counterpart of MetalHostView in the iOS app
/// (ContentView.swift). DXMT renders D3D11 into a CAMetalLayer; on iOS
/// that layer lives in a raw window-level UIView because SwiftUI hosting
/// can silently drop Metal presents (see the big comment in ContentView).
/// The same applies on tvOS, so we do the same thing:
///
///   • A process-lifetime singleton view that is added directly to the
///     UIWindow (above the SwiftUI hierarchy).
///   • Its CAMetalLayer is registered with DXMT once via
///     madeira_display_set_layer(); after that DXMT presents into it.
///   • Interaction is disabled — input comes from the gamepad, not the
///     screen.
///   • The game surface is aspect-fit (letterboxed) inside the screen so
///     a 4:3/16:9 Windows game renders correctly on a 16:9 TV.
///
/// The layer survives the view teardown (one layer, one swapchain, for
/// the process lifetime) — exactly like the iOS singleton.
final class TVMetalHostView: UIView {

    static let shared = TVMetalHostView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
    private static var layerRegistered = false

    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// 16:9 logical surface (matches the TV). Games that render 4:3 are
    /// letterboxed by Wine/aspect-fit inside this.
    static let logicalSize = CGSize(width: 1280, height: 720)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        contentScaleFactor = UIScreen.main.scale
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.drawableSize = CGSize(width: 1280, height: 720)
        // Same private display-sync avoidance as the iOS host (MeloNX
        // pattern): takes presents out of the display-sync scheduler.
        let syncSel = NSSelectorFromString("setDisplaySyncEnabled:")
        if metalLayer.responds(to: syncSel) {
            metalLayer.perform(syncSel, with: NSNumber(value: false))
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Attach the layer to the key window and register it with DXMT.
    /// Safe to call repeatedly — the layer is registered once.
    static func attach() {
        let host = TVMetalHostView.shared
        let w = UIApplication.shared.windows.first { $0.isKeyWindow }
            ?? UIApplication.shared.windows.first
        guard let win = w else { return }

        if host.superview !== win {
            host.removeFromSuperview()
            host.frame = aspectFitFrame(in: win.bounds)
            win.addSubview(host)
        }
        if !layerRegistered {
            layerRegistered = true
            madeira_display_set_layer(host.metalLayer)
        }
    }

    static func detach() {
        TVMetalHostView.shared.removeFromSuperview()
    }

    /// Largest 16:9 rect that fits centered in `bounds`.
    static func aspectFitFrame(in bounds: CGRect) -> CGRect {
        let lw = logicalSize.width, lh = logicalSize.height
        let scale = min(bounds.width / lw, bounds.height / lh)
        let w = lw * scale, h = lh * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2,
                      width: max(w, 1), height: max(h, 1))
    }
}