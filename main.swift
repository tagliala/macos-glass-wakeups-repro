// Minimal test: idle wakeups after showing an NSPanel that contains the
// Liquid Glass material, compared with controls.
//
// Build: swiftc -O main.swift -o glass-wakeups
// Run:   ./glass-wakeups --mode appkit-glass --auto
//
// Options (all optional, for variations of the same test):
//   --auto          show the panel 3 s after launch, close it 3 s later
//   --twice         with --auto: wait 3 s and run a second show/close cycle
//   --click         show through the status item button (performClick)
//   --activate      activate the app before showing the panel
//   --borderless    borderless, transparent panel at status bar level
//   --below-item    place the panel right below the status item
//   --under-mouse   place the panel under the mouse cursor

import AppKit
import SwiftUI

enum Mode: String, CaseIterable {
    case neverOpen = "never-open"          // control: panel never shown
    case noContent = "no-content"          // panel shown, empty
    case plain                             // SwiftUI content, no glass
    case appkitGlass = "appkit-glass"      // NSGlassEffectView around the hosting view
    case swiftuiGlass = "swiftui-glass"    // SwiftUI .glassEffect
    case appkitGlassClear = "appkit-glass-clear"           // NSGlassEffectView, style .clear
    case appkitGlassContainer = "appkit-glass-container"   // NSGlassEffectContainerView around it
    case swiftuiGlassContainer = "swiftui-glass-container" // GlassEffectContainer + .glassEffect
    case popoverGlass = "popover-glass"    // NSPopover from the status item, SwiftUI .glassEffect
    case popoverPlain = "popover-plain"    // NSPopover from the status item, no .glassEffect
    case popoverTeardown = "popover-teardown" // popover-glass, popover and content released on close
    case visualEffect = "visual-effect"    // NSVisualEffectView (.popover), no glass
    case controlTimer = "control-timer"    // positive control: our own 3 s GCD timer
}

let args = CommandLine.arguments
func flag(_ name: String) -> Bool { args.contains(name) }

func say(_ line: String) {
    print(line)
    fflush(stdout)
}

struct HelloView: View {
    let glass: Bool
    var container = false

    var body: some View {
        let content = VStack(spacing: 12) {
            Text("Hello")
            Button("Press me") {}
        }
        .padding(24)

        if glass && container {
            GlassEffectContainer {
                content.glassEffect(.regular, in: .rect(cornerRadius: 12))
            }
        } else if glass {
            content.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            content
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let mode: Mode
    var statusItem: NSStatusItem!
    var panel: NSPanel!
    var popover: NSPopover?
    var controlTimer: DispatchSourceTimer?
    weak var weakPopover: NSPopover?
    weak var weakController: NSViewController?
    weak var weakContentView: NSView?

    init(mode: Mode) { self.mode = mode }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "G"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 140),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        if flag("--borderless") {
            panel.styleMask = [.nonactivatingPanel, .borderless]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
        }

        switch mode {
        case .neverOpen, .noContent, .controlTimer:
            break
        case .plain:
            panel.contentView = NSHostingView(rootView: HelloView(glass: false))
        case .appkitGlass, .appkitGlassClear, .appkitGlassContainer:
            let glass = NSGlassEffectView()
            glass.cornerRadius = 12
            if mode == .appkitGlassClear { glass.style = .clear }
            glass.contentView = NSHostingView(rootView: HelloView(glass: false))
            if mode == .appkitGlassContainer {
                let container = NSGlassEffectContainerView()
                container.contentView = glass
                panel.contentView = container
            } else {
                panel.contentView = glass
            }
        case .swiftuiGlass:
            panel.contentView = NSHostingView(rootView: HelloView(glass: true))
        case .swiftuiGlassContainer:
            panel.contentView = NSHostingView(rootView: HelloView(glass: true, container: true))
        case .popoverGlass, .popoverPlain, .popoverTeardown:
            makePopover()
        case .visualEffect:
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            let hosting = NSHostingView(rootView: HelloView(glass: false))
            hosting.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            panel.contentView = effect
        }

        if mode == .controlTimer {
            let t = DispatchSource.makeTimerSource(queue: .global())
            t.schedule(deadline: .now() + 3, repeating: 3)
            t.setEventHandler {}
            t.resume()
            controlTimer = t
        }

        say("pid \(ProcessInfo.processInfo.processIdentifier) mode \(mode.rawValue)")
        guard flag("--auto") else { return }
        cycle(remaining: flag("--twice") ? 2 : 1)
    }

    func makePopover() {
        let p = NSPopover()
        p.behavior = .applicationDefined
        p.contentViewController = NSHostingController(rootView: HelloView(glass: mode != .popoverPlain))
        popover = p
        weakPopover = p
        weakController = p.contentViewController
        weakContentView = p.contentViewController?.view
    }

    /// Show 3 s from now, close 3 s later; repeat. The same timing is used
    /// for the modes that never show anything, so every run is comparable.
    func cycle(remaining: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            if flag("--click") { statusItem.button?.performClick(nil) } else { show() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                hide()
                let finish = { [self] in
                    if remaining > 1 {
                        say("panel closed, cycle \(remaining)")
                        cycle(remaining: remaining - 1)
                    } else {
                        say("done: panel closed")
                    }
                }
                if mode == .popoverTeardown { teardown(then: finish) } else { finish() }
            }
        }
    }

    var showsNothing: Bool { mode == .neverOpen || mode == .controlTimer }

    func show() {
        guard !showsNothing else { return }
        if flag("--activate") { NSApp.activate(ignoringOtherApps: true) }
        if let popover, let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            return
        }
        panel.center()
        if flag("--below-item"), let f = statusItem.button?.window?.frame {
            panel.setFrameTopLeftPoint(NSPoint(x: f.minX, y: f.minY - 4))
        }
        if flag("--under-mouse") {
            let m = NSEvent.mouseLocation
            panel.setFrameOrigin(NSPoint(x: m.x - 120, y: m.y - 70))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        if let popover { popover.performClose(nil) } else { panel.orderOut(nil) }
    }

    /// Release the popover and its content after the close animation, then
    /// prove with weak references that they were deallocated.
    func teardown(then finish: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            autoreleasepool {
                popover?.contentViewController = nil
                popover = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                autoreleasepool { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2)) }
                func state(_ o: AnyObject?) -> String { o == nil ? "deallocated" : "ALIVE" }
                say("teardown: popover \(state(weakPopover)), controller \(state(weakController)), view \(state(weakContentView))")
                if flag("--twice") { makePopover() }
                finish()
            }
        }
    }

    @objc func toggle() {
        if panel.isVisible || popover?.isShown == true { hide() } else { show() }
    }
}

var mode = Mode.appkitGlass
if let i = args.firstIndex(of: "--mode"), i + 1 < args.count {
    guard let m = Mode(rawValue: args[i + 1]) else {
        FileHandle.standardError.write(
            "unknown mode; use one of: \(Mode.allCases.map(\.rawValue).joined(separator: ", "))\n"
                .data(using: .utf8)!)
        exit(2)
    }
    mode = m
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(mode: mode)
app.delegate = delegate
app.run()
