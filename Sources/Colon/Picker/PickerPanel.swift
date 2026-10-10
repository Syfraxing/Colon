import AppKit
import SwiftUI

/// Borderless, non-activating floating panel. It can become key only in search mode, so the
/// app being typed into keeps focus and its caret while the inline picker is up.
final class PickerPanel: NSPanel {
    var allowsKey = false
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the card draws its own shadow inside the transparent margin
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        acceptsMouseMovedEvents = false
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Mouse handling the controller does itself in inline mode, where the panel is never key and
/// hover/click must work without SwiftUI gestures (and without reacting to rows moving under a still mouse).
@MainActor
protocol PickerMouseHandling: AnyObject {
    /// Return true to consume the event.
    func pickerMouseMoved(at windowPoint: NSPoint) -> Bool
    func pickerMouseDown(at windowPoint: NSPoint) -> Bool
}

final class PickerHostingView: NSHostingView<PickerRootView> {
    weak var mouseHandler: PickerMouseHandling?
    private var trackingArea: NSTrackingArea?

    required init(rootView: PickerRootView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        if mouseHandler?.pickerMouseMoved(at: event.locationInWindow) == true { return }
        super.mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if mouseHandler?.pickerMouseDown(at: event.locationInWindow) == true { return }
        super.mouseDown(with: event)
    }
}

/// Behind-window blur: Liquid Glass on macOS 26+, `NSVisualEffectView` before that.
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat
    var isDark: Bool

    func makeNSView(context: Context) -> NSView {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            return glass
        }
        #endif
        let effect = NSVisualEffectView()
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        return effect
    }

    func updateNSView(_ view: NSView, context: Context) {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            return
        }
        #endif
        if let effect = view as? NSVisualEffectView {
            effect.material = isDark ? .hudWindow : .popover
            effect.layer?.cornerRadius = cornerRadius
        }
    }
}
