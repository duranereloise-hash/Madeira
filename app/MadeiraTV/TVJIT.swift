import Foundation
import UIKit

/// How the JIT pool was obtained.
enum JITMethod: String {
    case entitlement          // allow-jit entitlement — no debugger at all
    case mapJit = "MAP_JIT"   // MAP_JIT under a generic debugger (Xcode/remote JIT)
    case brk = "StikDebug"    // StikDebug BRK #0xf00d protocol (external app)
    case builtInStikJIT = "StikJIT"  // built-in StikJIT helper extension
}

struct JITPool {
    let rx: UnsafeMutableRawPointer
    let rw: UnsafeMutableRawPointer
    let size: Int
    let method: JITMethod
}

/// JIT acquisition ladder for tvOS 26. Tries every realistic way to get
/// executable memory, first success wins; the pool is cached for the
/// process lifetime (same as iOS).
///
/// Ladder:
///   1. allow-jit entitlement    — paid dev account / TrollStore. No debugger.
///   2. MAP_JIT under ANY debugger — Xcode attach / remote JIT server.
///   3. StikDebug BRK #0xf00d (universal script) — JITAllocator.c already
///      implements this protocol.
///   4. Built-in StikJIT — the StikJITTV helper extension attaches its own
///      debug server over the RSD tunnel, then the same BRK protocol is
///      used to prepare the pool. No external app needed.
///
/// `madeira.jitMethod` (UserDefaults) overrides with: entitlement, mapjit,
/// stik, stikjit (default = auto ladder).
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

    static var allowBuiltIn: Bool {
        UserDefaults.standard.bool(forKey: "madeira.jitAllowBuiltIn")
    }

    static func acquire(poolSize: Int = defaultPoolMB * 1024 * 1024) -> JITPool? {
        if let p = current { return p }
        let override = methodOverride

        func shouldTry(_ m: String) -> Bool {
            override == nil || override == m
        }

        func makePool(_ rxAddr: vm_address_t, _ method: JITMethod) -> JITPool? {
            guard let rw = attachRWAlias(rxAddr: rxAddr, size: poolSize) else {
                vm_deallocate(mach_task_self_, rxAddr, vm_size_t(poolSize))
                return nil
            }
            let rx = UnsafeMutableRawPointer(bitPattern: rxAddr)!
            let rwm = UnsafeMutableRawPointer(bitPattern: rw.rwAddr)!
            _ = jit_make_region_no_footprint(rwm, poolSize, "pool-RW-tv")
            let pool = JITPool(rx: rx, rw: rwm, size: poolSize, method: method)
            current = pool
            return pool
        }

        // 1. Entitlement: no debugger at all.
        if shouldTry("entitlement"), checkAppEntitlement("com.apple.security.cs.allow-jit"),
           let addr = allocateRX(poolSize, viaMapJIT: true),
           let p = makePool(addr, .entitlement) {
            return p
        }
        if override == "entitlement" {
            lastFailure = "No allow-jit entitlement (paid Apple Developer account or TrollStore)"
            return nil
        }

        // 2. MAP_JIT under any attached debugger.
        if shouldTry("mapjit"), jit_check_debugged(),
           let addr = allocateRX(poolSize, viaMapJIT: true),
           let p = makePool(addr, .mapJit) {
            return p
        }
        if override == "mapjit" {
            lastFailure = jit_check_debugged()
                ? "MAP_JIT refused by the kernel under this debugger"
                : "No debugger attached (CS_DEBUGGED unset)"
            return nil
        }

        // 3. StikDebug BRK protocol (external app; opt-in).
        if shouldTry("stik"), allowBRK, jit_check_debugged(),
           let addr = allocateRX(poolSize, viaMapJIT: false),
           let p = makePool(addr, .brk) {
            return p
        }
        if override == "stik" {
            lastFailure = "StikDebug BRK failed or not enabled (madeira.jitAllowBRK=1 needed)"
            return nil
        }

        // 4. Built-in StikJIT: helper attaches its debug server, then the
        //    same BRK protocol prepares the pool.
        if shouldTry("stikjit"), allowBuiltIn {
            if StikJITCoordinator.shared.enableBuiltIn(),
               let addr = allocateRX(poolSize, viaMapJIT: false),
               let p = makePool(addr, .builtInStikJIT) {
                return p
            }
            lastFailure = "Built-in StikJIT failed: \(StikJITCoordinator.shared.lastError ?? "unknown")"
            if override == "stikjit" { return nil }
        }

        lastFailure = "No JIT source available (entitlement, debugger, StikDebug or built-in StikJIT)"
        return nil
    }

    static func detach() {
        jit26_detach()
    }

    // MARK: - Pool building

    /// RX region: vm_allocate(VM_FLAGS_MAP_JIT) or the StikDebug BRK
    /// protocol. Placement is checked against FEX's position-dependent emit
    /// threshold (0x119000000) and the guest 64G window [0x70,0x80)G.
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

    /// Non-executable RW alias over the RX region (W^X).
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