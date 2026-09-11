import Foundation
import GameController

/// Bridges GameController.framework input to the Wine side through the
/// existing winios_* bridge functions (Winios.h).
///
/// Apple TV has no touch surface, so the gamepad (Siri Remote,
/// DualShock/DualSense, Xbox controller) is the PRIMARY input device.
///
/// Wine exposes no XInput yet (the iOS app's controller tab is explicitly
/// "not wired" — COM/WinRT XInput lands later), so this layer maps the
/// pad onto two input paths Wine already understands:
///   • Keyboard layer — sticks/D-pad → arrow keys, face buttons →
///     Enter/Esc/Space/Tab, bumpers → Shift/Ctrl. Works everywhere.
///   • Mouse layer — right stick → relative mouse motion (mouse-look),
///     right trigger → left click, left trigger → right click.
/// When a real XInput bridge lands, this manager only needs an extra
/// mapping table; the winios_* plumbing is unchanged.
final class GamepadManager {

    static let shared = GamepadManager()

    private(set) var connectedCount = 0
    var onConnectionChange: (() -> Void)?

    private var keyboardController: GCController?
    private var mouseController: GCController?

    // Stick dead zone (0…1)
    private let deadZone: Float = 0.25

    // Virtual keys (Windows)
    private let vkUp: Int32 = 0x26, vkDown: Int32 = 0x28
    private let vkLeft: Int32 = 0x25, vkRight: Int32 = 0x27
    private let vkEnter: Int32 = 0x0D, vkEsc: Int32 = 0x1B
    private let vkSpace: Int32 = 0x20, vkTab: Int32 = 0x09
    private let vkShift: Int32 = 0x10, vkCtrl: Int32 = 0x11

    /// Keyboard button state we track to avoid duplicate presses.
    private var keyStates: [Int32: Bool] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(controllerConnected),
            name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(controllerDisconnected),
            name: .GCControllerDidDisconnect, object: nil)
    }

    /// Call once at app launch. Then keep observing connect/disconnect.
    func start() {
        for c in GCController.controllers() { bind(c) }
        connectedCount = GCController.controllers().count
        onConnectionChange?()
    }

    @objc private func controllerConnected(_ n: Notification) {
        guard let c = n.object as? GCController else { return }
        bind(c)
        connectedCount = GCController.controllers().count
        onConnectionChange?()
    }

    @objc private func controllerDisconnected(_ n: Notification) {
        guard let c = n.object as? GCController else { return }

        // If a controller that currently holds keys disconnects, Wine would
        // keep the keys pressed forever. Release everything it could have
        // held before dropping it.
        if keyboardController === c || mouseController === c {
            releaseAll()
        }
        if keyboardController === c { keyboardController = nil }
        if mouseController === c { mouseController = nil }
        connectedCount = GCController.controllers().count
        onConnectionChange?()
    }

    /// Release every key we may have pressed. Called on controller
    /// disconnect so a pad that vanishes mid-game never leaves Wine with a
    /// stuck button.
    private func releaseAll() {
        for (vk, down) in keyStates where down {
            winios_post_key(vk, 0)
        }
        keyStates.removeAll()
        leftTriggerDown = false
        rightTriggerDown = false
        mouseInited = false
    }

    private func bind(_ c: GCController) {
        guard let pad = c.extendedGamepad else { return }

        // Assign roles: first pad = keyboard layer, second = mouse layer.
        // Remaining pads are ignored (kept simple; a mapping screen can
        // come later).
        if keyboardController == nil {
            keyboardController = c
        } else if mouseController == nil {
            mouseController = c
        }

        pad.valueChangedHandler = { [weak self] _, _ in
            self?.poll(pad)
        }
    }

    // MARK: - Polling

    private func poll(_ pad: GCExtendedGamepad) {
        let c = pad.controller

        if c === keyboardController {
            pollKeyboard(pad)
        }
        if c === mouseController {
            pollMouse(pad)
        }
    }

    // MARK: Keyboard layer

    private func pollKeyboard(_ pad: GCExtendedGamepad) {
        // Left stick / D-pad → arrows. 0.25 dead zone; analogue push gives
        // smoother walking in games that read arrow keys as held keys.
        let x = pad.leftThumbstick.xAxis.value
        let y = pad.leftThumbstick.yAxis.value
        let dx = pad.dpad.xAxis.value
        let dy = pad.dpad.yAxis.value

        setKey(vkLeft, x < -deadZone || dx < -0.5)
        setKey(vkRight, x > deadZone || dx > 0.5)
        setKey(vkUp, y > deadZone || dy > 0.5)      // GC y up = "up"
        setKey(vkDown, y < -deadZone || dy < -0.5)

        // Face buttons
        setKey(vkEnter, pad.buttonA.isPressed)      // A → Enter
        setKey(vkEsc, pad.buttonB.isPressed)        // B → Esc
        setKey(vkSpace, pad.buttonX.isPressed)      // X → Space
        setKey(vkTab, pad.buttonY.isPressed)        // Y → Tab
        setKey(vkShift, pad.leftShoulder.isPressed) // LB → Shift
        setKey(vkCtrl, pad.rightShoulder.isPressed) // RB → Ctrl
    }

    private func setKey(_ vk: Int32, _ down: Bool) {
        guard keyStates[vk] != down else { return }
        keyStates[vk] = down
        winios_post_key(vk, down ? 1 : 0)
    }

    // MARK: Mouse layer

    private var lastMouseX: Float = 0
    private var lastMouseY: Float = 0
    private var mouseInited = false
    private var leftTriggerDown = false
    private var rightTriggerDown = false

    private func pollMouse(_ pad: GCExtendedGamepad) {
        let x = pad.rightThumbstick.xAxis.value
        let y = pad.rightThumbstick.yAxis.value

        if !mouseInited {
            lastMouseX = x; lastMouseY = y
            mouseInited = true
        }
        let dx = x - lastMouseX
        let dy = y - lastMouseY
        lastMouseX = x; lastMouseY = y

        // Relative mouse motion (F_MOVE, MOUSEEVENTF_MOVE) — same semantics
        // as the iOS mouse-look path: winios_pointer(ix, iy, F_MOVE, 0).
        let scale: Float = 1800.0   // counts per unit stick travel
        let ix = Int32(max(-30000, min(30000, dx * scale)))
        let iy = Int32(max(-30000, min(30000, dy * scale)))
        if ix != 0 || iy != 0 {
            winios_pointer(ix, iy, 0x1, 0)  // F_MOVE
        }

        // Triggers → mouse buttons, click on the DOWN edge only.
        let lt = pad.leftTrigger.isPressed
        let rt = pad.rightTrigger.isPressed
        if lt && !leftTriggerDown {
            leftTriggerDown = true
            winios_pointer(0, 0, 0x0008, 0); winios_pointer(0, 0, 0x0010, 0) // R down+up
        } else if !lt {
            leftTriggerDown = false
        }
        if rt && !rightTriggerDown {
            rightTriggerDown = true
            winios_pointer(0, 0, 0x0002, 0); winios_pointer(0, 0, 0x0004, 0) // L down+up
        } else if !rt {
            rightTriggerDown = false
        }
    }
}