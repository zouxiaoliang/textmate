import AppKit
import Combine

public enum PaletteMode: String, CaseIterable, Sendable {
	case recentProjects
	case commands
	case symbols
	case bundleEditor
	case goToLine
	case findInProject
	case settings

	public var prefix: Character? {
		switch self {
		case .recentProjects: return nil
		case .commands:       return ">"
		case .symbols:        return "@"
		case .bundleEditor:   return "#"
		case .goToLine:       return ":"
		case .findInProject:  return "/"
		case .settings:       return "~"
		}
	}

	public var label: String {
		switch self {
		case .recentProjects: return "Recent Projects"
		case .commands:       return "Commands"
		case .symbols:        return "Symbols"
		case .bundleEditor:   return "Bundles"
		case .goToLine:       return "Go to Line"
		case .findInProject:  return "Find"
		case .settings:       return "Settings"
		}
	}

	public var placeholder: String {
		switch self {
		case .recentProjects: return "Search recent projects..."
		case .commands:       return "Search commands..."
		case .symbols:        return "Search symbols..."
		case .bundleEditor:   return "Search bundles..."
		case .goToLine:       return "Type a line number..."
		case .findInProject:  return "Search in project..."
		case .settings:       return "Search settings..."
		}
	}

	public var intValue: Int {
		switch self {
		case .recentProjects: return 0
		case .commands:       return 1
		case .symbols:        return 2
		case .bundleEditor:   return 3
		case .goToLine:       return 4
		case .findInProject:  return 5
		case .settings:       return 6
		}
	}

	public init?(prefix: Character) {
		guard let mode = PaletteMode.allCases.first(where: { $0.prefix == prefix }) else {
			return nil
		}
		self = mode
	}
}

public struct RankedItem: Identifiable, Sendable {
	public let item: OakCommandPaletteItem
	public let matchedIndices: [Int]
	public let score: Double
	public var id: UUID { item.id }
}

public struct FrecencyEntry {
	public var count: Int
	public var lastUsed: TimeInterval

	public init(count: Int, lastUsed: TimeInterval) {
		self.count = count
		self.lastUsed = lastUsed
	}
}

@MainActor
public class CommandPaletteViewModel: ObservableObject {
	@Published public var filterText: String = "" {
		didSet { processFilterChange() }
	}
	@Published public private(set) var activeMode: PaletteMode = .recentProjects
	@Published public private(set) var filteredItems: [RankedItem] = []
	@Published public var selectedIndex: Int = 0
	@Published private(set) var markedItems: Set<UUID> = []
	@Published private(set) var removalError: String?

	public var onItemSelected: ((OakCommandPaletteItem) -> Void)?
	var onItemsSelected: (([OakCommandPaletteItem]) -> Void)?
	var onItemRemoved: ((OakCommandPaletteItem) -> Bool)?
	public var onDismiss: (() -> Void)?
	public var onModeSwitch: ((PaletteMode) -> [OakCommandPaletteItem])?
	public var onSearchDocument: ((String) -> [OakCommandPaletteItem])?

	private var itemsByMode: [PaletteMode: [OakCommandPaletteItem]] = [:]
	public private(set) var frecencyData: [String: FrecencyEntry] = [:]
	private let scopedSearch: (label: String, placeholder: String, suggestions: (String) -> [OakCommandPaletteItem])?

	public init() { scopedSearch = nil }

	init(label: String, placeholder: String, suggestions: @escaping (String) -> [OakCommandPaletteItem]) {
		scopedSearch = (label, placeholder, suggestions)
		activeMode = .commands
	}

	var searchLabel: String? {
		scopedSearch?.label ?? (activeMode == .recentProjects ? nil : activeMode.label)
	}

	var searchPlaceholder: String { scopedSearch?.placeholder ?? activeMode.placeholder }

	public var queryText: String {
		if scopedSearch != nil { return filterText.trimmingCharacters(in: .whitespacesAndNewlines) }
		guard let prefix = activeMode.prefix, filterText.first == prefix else {
			return filterText
		}
		return String(filterText.dropFirst())
	}

	public func setItems(_ items: [OakCommandPaletteItem], forMode mode: PaletteMode) {
		itemsByMode[mode] = items
		if mode == activeMode {
			applyFilter()
		}
	}

	public func selectNext() {
		if selectedIndex < filteredItems.count - 1 {
			selectedIndex += 1
		}
	}

	public func selectPrevious() {
		if selectedIndex > 0 {
			selectedIndex -= 1
		}
	}

	public func acceptSelection() {
		if let onItemsSelected {
			let items = itemsToOpen
			if !items.isEmpty { onItemsSelected(items) }
		} else if let item = selectedItem, item.enabled {
			onItemSelected?(item)
		}
	}

	var managesItems: Bool { onItemsSelected != nil }

	var itemsToOpen: [OakCommandPaletteItem] {
		if markedItems.isEmpty { return selectedItem.flatMap { $0.enabled ? [$0] : nil } ?? [] }
		return (itemsByMode[activeMode] ?? []).filter { $0.enabled && markedItems.contains($0.id) }
	}

	func toggleMark(_ item: OakCommandPaletteItem) {
		guard managesItems, item.enabled else { return }
		if markedItems.remove(item.id) == nil { markedItems.insert(item.id) }
	}

	func remove(_ item: OakCommandPaletteItem) {
		guard item.removalLabel != nil, let onItemRemoved else { return }
		guard onItemRemoved(item) else {
			removalError = "Couldn’t remove \(item.title)."
			return
		}
		removalError = nil
		let previous = selectedItem?.id
		markedItems.remove(item.id)
		itemsByMode[activeMode]?.removeAll { $0.id == item.id }
		applyFilter()
		selectedIndex = filteredItems.firstIndex { $0.id == previous } ?? min(selectedIndex, max(0, filteredItems.count - 1))
	}

	public func requestDismiss() {
		onDismiss?()
	}

	public func updateFrecency(for identifier: String, at timestamp: TimeInterval? = nil) {
		let ts = timestamp ?? Date().timeIntervalSinceReferenceDate
		var entry = frecencyData[identifier] ?? FrecencyEntry(count: 0, lastUsed: ts)
		entry.count += 1
		entry.lastUsed = ts
		frecencyData[identifier] = entry
	}

	public func frecencyBoost(for identifier: String) -> Double {
		guard let entry = frecencyData[identifier] else { return 0 }
		let now = Date().timeIntervalSinceReferenceDate
		let hoursSinceLastUse = (now - entry.lastUsed) / 3600.0
		return Double(min(entry.count, 20)) * exp(-hoursSinceLastUse / 168.0)
	}

	public func loadFrecency(_ data: [String: FrecencyEntry]) {
		frecencyData = data
	}

	public var selectedItem: OakCommandPaletteItem? {
		guard selectedIndex >= 0, selectedIndex < filteredItems.count else { return nil }
		return filteredItems[selectedIndex].item
	}

	private func processFilterChange() {
		if scopedSearch != nil {
			applyFilter()
			selectedIndex = 0
			return
		}
		let newMode: PaletteMode
		if let first = filterText.first, let mode = PaletteMode(prefix: first) {
			newMode = mode
		} else {
			newMode = .recentProjects
		}

		if newMode != activeMode {
			activeMode = newMode
			// goToLine generates synthetic items — no delegate needed
			if newMode != .goToLine {
				// Settings always re-fetch (titles change based on toggle state)
				let shouldRefresh = newMode == .settings || itemsByMode[newMode] == nil
				if shouldRefresh, let items = onModeSwitch?(newMode) {
					itemsByMode[newMode] = items.isEmpty ? nil : items
				}
			}
		}

		// Find mode searches the current document — re-query on every keystroke
		if activeMode == .findInProject {
			let q = queryText
			if !q.isEmpty, let items = onSearchDocument?(q), !items.isEmpty {
				itemsByMode[.findInProject] = items
			} else {
				itemsByMode[.findInProject] = nil
			}
		}

		applyFilter()
		selectedIndex = 0
	}

	private func applyFilter() {
		let query = queryText

		// GoToLine generates a synthetic item from the query
		if activeMode == .goToLine {
			filteredItems = goToLineItems(query: query)
			return
		}

		let items = itemsByMode[activeMode] ?? []

		if query.isEmpty {
			filteredItems = items.map { RankedItem(item: $0, matchedIndices: [], score: 0) }
			return
		}

		let matches = items
			.compactMap { item -> RankedItem? in
				let frecency = frecencyBoost(for: item.actionIdentifier)
				if let result = FuzzyMatcher.score(item.title, query: query) {
					return RankedItem(item: item, matchedIndices: result.matchedIndices, score: Double(result.score) * (1 + frecency))
				}
				if item.category == .recentProject,
				   let result = FuzzyMatcher.score(item.representedObject as? String ?? item.subtitle, query: query)
				     ?? FuzzyMatcher.score(item.subtitle, query: query) {
					return RankedItem(item: item, matchedIndices: [], score: Double(result.score) * 0.5)
				}
				return nil
			}
			.sorted { $0.score > $1.score }
		let suggestions = scopedSearch?.suggestions(query) ?? []
		filteredItems = matches + suggestions.map { RankedItem(item: $0, matchedIndices: [], score: 0) }
	}

	private func goToLineItems(query: String) -> [RankedItem] {
		let lineStr = query.isEmpty ? "..." : query
		let title = "Go to line \(lineStr)"
		let item = OakCommandPaletteItem(
			title: title, subtitle: "", keyEquivalent: "",
			category: .goToLine, actionIdentifier: "line:\(query)")
		return [RankedItem(item: item, matchedIndices: [], score: 0)]
	}

	// findInProject is no longer synthetic — items are provided by the delegate
}
