import AppKit
import SwiftUI
import Combine

private class KeyablePanel: NSPanel {
	override var canBecomeKey: Bool { true }
}

@MainActor @objc public class OakCommandPalette: NSObject, NSWindowDelegate {
	private static let frameOffsetKey = "OakCommandPaletteFrameOffset"
	private static let topInset: CGFloat = 72
	private static let windowMargin: CGFloat = 8

	@objc public weak var delegate: OakCommandPaletteDelegate?
	@objc public private(set) weak var parentWindow: NSWindow?

	private let theme: OakThemeEnvironment
	private var panel: KeyablePanel?
	private var viewModel: CommandPaletteViewModel?
	private var cancellables = Set<AnyCancellable>()

	@objc public init(theme: OakThemeEnvironment) {
		self.theme = theme
		super.init()
	}

	@objc public func show(in parentWindow: NSWindow, items: [OakCommandPaletteItem]) {
		let vm = CommandPaletteViewModel()

		let commands = items.filter {
			$0.category == .menuAction || $0.category == .bundleCommand
		}
		vm.setItems(commands, forMode: .commands)

		let projects = items.filter { $0.category == .recentProject }
		vm.setItems(projects, forMode: .recentProjects)

		vm.onModeSwitch = { [weak self] mode in
			self?.delegate?.commandPaletteRequestItems(forMode: mode.intValue) ?? []
		}
		vm.onSearchDocument = { [weak self] query in
			self?.delegate?.commandPaletteSearchDocument(query) ?? []
		}
		present(in: parentWindow, model: vm) { [weak self] item in
			self?.delegate?.commandPaletteDidSelectItem(item)
		}
	}

	@objc public func show(in parentWindow: NSWindow?, items: [OakCommandPaletteItem], label: String,
	                       placeholder: String, suggestions: @escaping (String) -> [OakCommandPaletteItem],
	                       onSelect: @escaping (OakCommandPaletteItem) -> Void) {
		let vm = CommandPaletteViewModel(label: label, placeholder: placeholder, suggestions: suggestions)
		vm.setItems(items, forMode: .commands)
		present(in: parentWindow, model: vm, onSelect: onSelect)
	}

	@objc public func showManaging(in parentWindow: NSWindow?, items: [OakCommandPaletteItem], label: String,
	                               placeholder: String, onOpen: @escaping ([OakCommandPaletteItem]) -> Void,
	                               onRemove: @escaping (OakCommandPaletteItem) -> Bool) {
		let vm = CommandPaletteViewModel(label: label, placeholder: placeholder) { _ in [] }
		vm.setItems(items, forMode: .commands)
		vm.onItemRemoved = onRemove
		vm.onItemsSelected = { [weak self] items in
			guard let self else { return }
			self.finishSelection()
			onOpen(items)
		}
		present(in: parentWindow, model: vm)
	}

	private func finishSelection() {
		let parent = parentWindow
		dismissWithoutNotify()
		// Re-focus the parent before running responder chain actions.
		parent?.makeKeyAndOrderFront(nil)
	}

	private func present(in parentWindow: NSWindow?, model vm: CommandPaletteViewModel, onSelect: ((OakCommandPaletteItem) -> Void)? = nil) {
		dismissWithoutNotify()
		self.parentWindow = parentWindow
		if let onSelect {
			vm.onItemSelected = { [weak self] item in
				guard let self else { return }
				self.finishSelection()
				onSelect(item)
			}
		}
		vm.onDismiss = { [weak self] in
			guard let self else { return }
			let parent = self.parentWindow
			self.dismiss()
			parent?.makeKey()
		}

		self.viewModel = vm

		let rootView = CommandPaletteView(viewModel: vm)
			.environmentObject(theme)

		let hostingView = NSHostingView(rootView: rootView)

		let parentFrame = parentWindow?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 650)
		let panelWidth = parentWindow == nil ? CGFloat(560) : min(max(parentFrame.width * 0.5, 400), 700)
		let panelHeight: CGFloat = 400

		var panelFrame = NSRect(x: parentFrame.origin.x + (parentFrame.width - panelWidth) / 2,
		                        y: parentFrame.maxY - Self.topInset - panelHeight,
		                        width: panelWidth, height: panelHeight)

		// Restore the user's last position, stored as an offset from the parent window origin
		// so the palette follows whichever window (or screen) it is opened from.
		if parentWindow == nil {
			panelFrame.origin.y = parentFrame.maxY - parentFrame.height * 0.2 - panelHeight
		} else if let offsets = UserDefaults.standard.array(forKey: Self.frameOffsetKey) as? [CGFloat], offsets.count == 2 {
			panelFrame.origin = NSPoint(x: parentFrame.origin.x + offsets[0], y: parentFrame.origin.y + offsets[1])
		}

		panelFrame.origin = Self.clampToParentWindow(panelFrame, parentFrame: parentFrame)

		let p = KeyablePanel(
			contentRect: panelFrame,
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		p.level = .floating
		p.isOpaque = false
		p.backgroundColor = .clear
		p.hasShadow = true
		p.isMovableByWindowBackground = true
		p.contentView = hostingView
		p.delegate = self

		parentWindow?.addChildWindow(p, ordered: .above)
		p.makeKeyAndOrderFront(nil)

		self.panel = p
	}

	@objc public func loadFrecencyData(_ data: NSDictionary) {
		var entries: [String: FrecencyEntry] = [:]
		for case let (key as String, value as NSDictionary) in data {
			let count = (value["count"] as? Int) ?? 0
			let lastUsed = (value["lastUsed"] as? TimeInterval) ?? 0
			entries[key] = FrecencyEntry(count: count, lastUsed: lastUsed)
		}
		viewModel?.loadFrecency(entries)
	}

	private func dismissWithoutNotify() {
		guard let p = panel else { return }
		p.delegate = nil
		p.parent?.removeChildWindow(p)
		p.orderOut(nil)
		panel = nil
		viewModel = nil
		cancellables.removeAll()
	}

	@objc public func dismiss() {
		guard panel != nil else { return }
		dismissWithoutNotify()
		delegate?.commandPaletteDidDismiss()
	}

	@objc public var isVisible: Bool {
		panel?.isVisible ?? false
	}

	// MARK: - Position

	/// Keeps the palette fully inside its parent window (or hugging its top edge
	/// when the window is too short to fit it).
	private static func clampToParentWindow(_ frame: NSRect, parentFrame: NSRect) -> NSPoint {
		var origin = frame.origin
		if frame.width < parentFrame.width - 2 * windowMargin {
			origin.x = max(parentFrame.minX + windowMargin, min(origin.x, parentFrame.maxX - windowMargin - frame.width))
		} else {
			origin.x = parentFrame.origin.x + (parentFrame.width - frame.width) / 2
		}
		if frame.height < parentFrame.height - 2 * windowMargin {
			origin.y = max(parentFrame.minY + windowMargin, min(origin.y, parentFrame.maxY - windowMargin - frame.height))
		} else {
			origin.y = parentFrame.maxY - windowMargin - frame.height
		}
		return origin
	}

	private func saveFrameOffset() {
		guard let panel, let parent = parentWindow, panel.isVisible else { return }
		let offsets = [panel.frame.origin.x - parent.frame.origin.x,
		               panel.frame.origin.y - parent.frame.origin.y]
		UserDefaults.standard.set(offsets, forKey: Self.frameOffsetKey)
	}

	// MARK: - NSWindowDelegate

	nonisolated public func windowDidMove(_ notification: Notification) {
		// The delegate is only attached to the palette's own panel, so the moved
		// window is always the panel; save its offset from the parent window.
		Task { @MainActor in
			self.saveFrameOffset()
		}
	}

	nonisolated public func windowDidResignKey(_ notification: Notification) {
		guard let window = notification.object as? NSWindow else { return }
		let identity = ObjectIdentifier(window)
		Task { @MainActor in
			guard let panel = self.panel, ObjectIdentifier(panel) == identity else { return }
			self.dismiss()
		}
	}
}
