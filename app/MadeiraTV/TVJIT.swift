import Foundation
import UIKit

/// How the JIT pool was obtained.
enum JITMethod: String {
    case entitlement          // allow-jit entitlement — no debugger at all
    case mapJit = "MAP_JIT"   // MAP_JIT under a generic debugger (Xcode/remote JIT)
    case brk = "StikDebug"    // StikDebug BRK #0xf00d protocol
}

struct JITPool {
    let rx: UnsafeMutableRawPointer
    let rw: UnsafeMutableRawPointer
    let size: Int
    let method: JITMethod
}

/// JIT acquisition ladder for tvOS 26. Tries every realistic way to get
/// executable memory. The pool, once acquired, is cached for the process
/// lifetime (same as iOS): a later launch reuses it, and after a debugger
/// detaches no new executable pages can be made anyway.
///
/// Ladder (all optional, first success wins):
///   1. allow-jit entitlement    — paid dev account / TrollStore. No debugger.
///   2. MAP_JIT under ANY debugger — Xcode attach / remote JIT server.
///   3. StikDebug BRK #0xf00d (universal script) — our JITAllocator.c already
///      implements this protocol, so the app is compatible out of the box.
///   4. Built-in StikJIT (Rust XCFramework) launched from the helper
///      extension — fully in-app, no external app needed. See
///      StikJITCoordinator in TVRunner.
final class TVJIT {

    static let defaultPoolMB = 896

    private(set) static var current: JITPool?
    private(set) static var lastFailure: String?

    private struct RawPool {
        let rxAddr: vm_address_t
        let rwAddr: vm_address_t
    }

    static var methodOverride: String? {
        UserDefaults.standard.string(forKey: "madeira.jitMethod")
    }

    static var allowBRK: Bool {
        UserDefaults.standard.bool(forKey: "madeira.jitAllowBRK")
    }

    /// Allow the built-in StikJIT path (requires the helper extension to be
    /// linked in, a pairing file, Developer Mode and LocalDevVPN on the box).
    static var allowBuiltIn: Bool {
        UserDefaults.standard.bool(forKey: "madeira.jitAllowBuiltIn")
    }

    static func acquire(poolSize: Int = defaultPoolMB * 1024 * 1024) -> JITPool? {
        if let p = current { return p }
        let override = methodOverride

        func attempt(_ viaMapJIT: Bool, _ method: JITMethod) -> JITPool? {
            guard let rxAddr = allocateRX(poolSize, viaMapJIT: viaMapJIT) else { return nil }
            guard let rw = attachRWAlias(rxAddr: rxAddr, size: poolSize) else {
                vm_deallocate(mach_task_self_, rxAddr, vm_size_t(poolSize))
                return nil
            }
            let rx = UnsafeMutableRawPointer(bitPattern: rxAddr)!
            let rwm = UnsafeMutableRawPointer(bitPattern: rw.rwAddr)!
            _ = jit_make_region_no_footprint(rwm, poolSize, "pool-RW-tv")
            current = JITPool(rx: rx, rw: rwm, size: poolSize, method: method)
            return current
        }

        // 1. Entitlement (paid account / TrollStore): no debugger needed.
        if override == nil || override == "entitlement" {
            if checkAppEntitlement("com.apple.security.cs.allow-jit") {
                if let p = attempt(true, .entitlement) { return p }
            }
            lastFailure = "No allow-jit entitlement (paid Apple Developer account or TrollStore)"
            if override == "entitlement" { return nil }
        }

        // 2. MAP_JIT under a generic debugger.
        if override == nil || override == "mapjit" {
            if jit_check_debugged() {
                if let p = attempt(true, .mapJit) { return p }
                lastFailure = "MAP_JIT refused by the kernel under this debugger"
            }
            if override == "mapjit" { return nil }
        }

        // 3. StikDebug BRK protocol (opt-in — unsafe under other debuggers).
        if override == "stik" || (override == nil && allowBRK) {
            if jit_check_debugged(), let p = attempt(false, .brk) { return p }
            lastFailure = "StikDebug BRK protocol failed or no debugger attached"
            if override == "stik" { return nil }
        }

        // 4. Built-in StikJIT (in-app, needs helper extension + pairing file).
        if override == "stikjit" || (override == nil && allowBuiltIn) {
            if let p = StikJITCoordinator.shared.acquirePool() { return p }
            lastFailure = "Built-in StikJIT failed: \(StikJITCoordinator.shared.lastError ?? "unknown")"
        }
        return nil
    }

    /// Try to release the cached pool (called on app teardown if ever needed).
    static func discard() {
        guard let p = current else { return }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: p.rx), vm_size_t(p.size))
        current = nil
    }

    static func detach() {
        jit26_detach()
    }

    // MARK: - Pool building

    /// RX region: either vm_allocate(VM_FLAGS_MAP_JIT) or the StikDebug
    /// BRK protocol. Placement is checked against FEX's position-dependent
    /// emit threshold (0x119000000) and the guest 64G window [0x70,0x80)G.
    private static func allocateRX(_ size: Int, viaMapJIT: Bool) -> vm_address_t? {
        pinLowMemory()
        let goodLow = 0x119000000
        let guestLo = 0x7000000000
        let guestHi = 0x8000000000
        for _ in 0..<3 {
            var addr: vm_address_t = 0
            if viaMapJIT {
                let kr = vm_allocate(mach_task_self_, &addr, vm_size_t(size),
                                     VM_FLAGS_ANYWHERE | VM_FLAGS_MAP_JIT)
                guard kr == KERN_SUCCESS else { return nil }
            } else {
                guard let p = jit26_prepare_region(nil, size),
                      p != UnsafeMutableRawPointer(bitPattern: 0) else { return nil }
                addr = vm_address_t(bitPattern: p)
            }
            let a = Int(addr)
            let inGuestWindow = a + size > guestLo && a < guestHi
            if a >= goodLow && !inGuestWindow { return addr }
            vm_deallocate(mach_task_self_, addr, vm_size_t(size))
        }
        return nil
    }

    /// Pre-claim low address space (16 MB chunks, kept for process lifetime)
    /// so the RX allocation lands above FEX's emit threshold.
    private static func pinLowMemory() {
        let chunkSize = 16 * 1024 * 1024
        let pinTarget: vm_address_t = 0x119000000
        for _ in 0..<32 {
            var addr: vm_address_t = 0
            let kr = vm_allocate(mach_task_self_, &addr, vm_size_t(chunkSize), VM_FLAGS_ANYWHERE)
            if kr != KERN_SUCCESS { break }
            if addr + vm_address_t(chunkSize) >= pinTarget { break }
        }
    }

    /// Non-executable RW alias over the RX region (W^X: write via RW, exec
    /// via RX). No JIT flags needed on the alias — it never executes.
    private static func attachRWAlias(rxAddr: vm_address_t, size: Int) -> RawPool? {
        var rwAddr: vm_address_t = 0
        var cur: vm_prot_t = 0
        var max: vm_prot_t = 0
        let kr1 = vm_remap(mach_task_self_, &rwAddr, vm_size_t(size), 0, VM_FLAGS_ANYWHERE,
                           mach_task_self_, rxAddr, 0, &cur, &max, VM_INHERIT_NONE)
        guard kr1 == KERN_SUCCESS else { return nil }
        let kr2 = vm_protect(mach_task_self_, rwAddr, vm_size_t(size), 0,
                             VM_PROT_READ | VM_PROT_WRITE)
        guard kr2 == KERN_SUCCESS else {
            vm_deallocate(mach_task_self_, rwAddr, vm_size_t(size))
            return nil
        }
        return RawPool(rxAddr: rxAddr, rwAddr: rwAddr)
    }
}