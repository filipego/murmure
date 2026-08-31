import AppKit
import SwiftUI

/// Minimal window contract used to keep the recording HUD's compositor lifetime bounded.
@MainActor
protocol HUDPresenting: AnyObject {
    func present()
    func dismiss(onHidden: @escaping @MainActor () -> Void)
}

/// Owns the HUD only while dictation is active.
///
/// A hidden transparent `NSPanel` can still retain its WindowServer surface. Releasing the
/// panel after its fade-out prevents that surface from living for the entire app session.
@MainActor
final class HUDLifecycle {
    private let makeHUD: @MainActor () -> any HUDPresenting
    private var hud: (any HUDPresenting)?
    private var transitionID = 0

    init(makeHUD: @escaping @MainActor () -> any HUDPresenting) {
        self.makeHUD = makeHUD
    }

    var hasHUD: Bool { hud != nil }

    func setActive(_ isActive: Bool) {
        transitionID &+= 1
        let currentTransition = transitionID

        if isActive {
            let activeHUD: any HUDPresenting
            if let hud {
                activeHUD = hud
            } else {
                activeHUD = makeHUD()
                hud = activeHUD
            }
            activeHUD.present()
            return
        }

        guard let dismissingHUD = hud else { return }
        dismissingHUD.dismiss { [weak self, weak dismissingHUD] in
            guard let self, let dismissingHUD else { return }
            guard self.transitionID == currentTransition else { return }
            guard self.hud === dismissingHUD else { return }
            self.hud = nil
        }
    }
}

/// The floating capsule that appears while you hold the key.
///
/// The single most important property here is that this panel **never becomes key**.
/// If it did, the user's text field would lose focus and `TextInjector` would have
/// nothing to insert into. Hence `.nonactivatingPanel` plus `canBecomeKey == false`.
@MainActor
final class HUDPanel: NSPanel, HUDPresenting {
    private var transitionID = 0

    init(controller: DictationController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        contentView = NSHostingView(rootView: HUDView(controller: controller))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Parks the panel just above the Dock, horizontally centered on the active screen.
    ///
    /// `NSScreen.main` is the screen with the *key window* — and an accessory app with a
    /// non-activating panel never has one, so it can be nil. Falling back to `screens.first`
    /// keeps the HUD on-screen instead of stranding it at the origin.
    func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            Log.app.error("no screen available to position HUD")
            return
        }
        let visible = screen.visibleFrame
        let size = frame.size
        setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + 96
            )
        )
    }

    func present() {
        transitionID &+= 1
        // Every active state change (starting → listening → finishing) calls this. Without
        // the early exit the panel would reset to alpha 0 and re-fade on each one, which
        // reads as a flicker mid-utterance.
        guard !isVisible || alphaValue < 1 else { return }

        reposition()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 1
        }
    }

    func dismiss(onHidden: @escaping @MainActor () -> Void) {
        transitionID &+= 1
        let currentTransition = transitionID
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit always calls this on the main thread.
            MainActor.assumeIsolated {
                guard let self, self.transitionID == currentTransition else { return }
                self.orderOut(nil)
                onHidden()
            }
        }
    }
}
