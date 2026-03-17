import AppKit
import SwiftUI

final class StatusBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private let viewModel = UsageViewModel()
    private var clickMonitor: Any?
    private var rightClickMonitor: Any?
    private var rightClickMenu: NSMenu!

    override init() {
        // Status item with SF Symbol icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()

        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.yaxis", accessibilityDescription: "Claude Code Usage")
            button.image?.isTemplate = true  // Adapts to light/dark menu bar
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp])
            button.target = self
        }

        // Right-click context menu
        rightClickMenu = NSMenu()
        rightClickMenu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        rightClickMenu.items.forEach { $0.target = self }

        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let button = self.statusItem.button, event.window == button.window else {
                return event
            }
            self.statusItem.menu = self.rightClickMenu
            button.performClick(nil)
            self.statusItem.menu = nil
            return nil
        }

        // Popover hosting the SwiftUI UsageView
        popover.contentSize = NSSize(width: 560, height: 230)
        popover.behavior = .transient     // Dismiss on outside click
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: UsageView(viewModel: viewModel))
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        stopClickMonitor()
        viewModel.dismissPopover()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            guard let button = statusItem.button else { return }
            viewModel.run()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            startClickMonitor()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Click-to-dismiss

    private func startClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.popover.contentViewController?.view.window else {
                return event
            }
            if event.window == window {
                self.popover.performClose(nil)
                return nil  // consume the event
            }
            return event
        }
    }

    private func stopClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }
}
