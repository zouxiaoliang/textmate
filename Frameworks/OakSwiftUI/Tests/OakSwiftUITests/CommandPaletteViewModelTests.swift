import Foundation
import Testing
@testable import OakSwiftUI

@MainActor
@Suite("CommandPaletteViewModel")
struct CommandPaletteViewModelTests {
	@Test func defaultModeIsRecentProjects() {
		let vm = CommandPaletteViewModel()
		#expect(vm.activeMode == .recentProjects)
	}

	@Test func typingGreaterThanSwitchesToCommandsMode() {
		let vm = CommandPaletteViewModel()
		vm.filterText = ">format"
		#expect(vm.activeMode == .commands)
		#expect(vm.queryText == "format")
	}

	@Test func typingAtSwitchesToSymbolsMode() {
		let vm = CommandPaletteViewModel()
		vm.filterText = "@viewDidLoad"
		#expect(vm.activeMode == .symbols)
		#expect(vm.queryText == "viewDidLoad")
	}

	@Test func typingColonSwitchesToGoToLineMode() {
		let vm = CommandPaletteViewModel()
		vm.filterText = ":42"
		#expect(vm.activeMode == .goToLine)
		#expect(vm.queryText == "42")
	}

	@Test func typingTildeSwitchesToSettingsMode() {
		let vm = CommandPaletteViewModel()
		vm.filterText = "~wrap"
		#expect(vm.activeMode == .settings)
		#expect(vm.queryText == "wrap")
	}

	@Test func typingSlashSwitchesToFindMode() {
		let vm = CommandPaletteViewModel()
		vm.filterText = "/auth"
		#expect(vm.activeMode == .findInProject)
		#expect(vm.queryText == "auth")
	}

	@Test func typingHashSwitchesToBundleEditorMode() {
		let vm = CommandPaletteViewModel()
		vm.filterText = "#ruby"
		#expect(vm.activeMode == .bundleEditor)
		#expect(vm.queryText == "ruby")
	}

	@Test func emptyFilterDefaultsToRecentProjects() {
		let vm = CommandPaletteViewModel()
		vm.filterText = ">test"
		vm.filterText = ""
		#expect(vm.activeMode == .recentProjects)
	}

	@Test func fuzzyFilteringWorks() {
		let vm = CommandPaletteViewModel()
		let items = [
			OakCommandPaletteItem(title: "Format File", subtitle: "", keyEquivalent: "", category: .menuAction, actionIdentifier: "menu:formatFile:"),
			OakCommandPaletteItem(title: "Find in Project", subtitle: "", keyEquivalent: "", category: .menuAction, actionIdentifier: "menu:findInProject:"),
			OakCommandPaletteItem(title: "Open Recent", subtitle: "", keyEquivalent: "", category: .menuAction, actionIdentifier: "menu:openRecent:"),
		]
		vm.setItems(items, forMode: .commands)
		vm.filterText = ">fmt"
		#expect(vm.filteredItems.count == 1)
		#expect(vm.filteredItems.first?.item.title == "Format File")
	}

	@Test func frecencyBoostIncreasesScoreForRecentItems() {
		let vm = CommandPaletteViewModel()
		let now = Date().timeIntervalSinceReferenceDate

		vm.updateFrecency(for: "menu:formatFile:", at: now)
		vm.updateFrecency(for: "menu:formatFile:", at: now)
		vm.updateFrecency(for: "menu:formatFile:", at: now)

		let boost = vm.frecencyBoost(for: "menu:formatFile:")
		#expect(boost > 0)
	}

	@Test func scopedPaletteMatchesBranchesAndAcceptsFileSuggestions() {
		let branch = OakCommandPaletteItem(title: "Check Out topic/ui", subtitle: "", keyEquivalent: "", category: .menuAction, actionIdentifier: "checkout")
		let vm = CommandPaletteViewModel(label: "Git", placeholder: "Search actions, branches, and tags…") { query in
			let item = OakCommandPaletteItem(title: "Show History for File: \(query)", subtitle: "", keyEquivalent: "", category: .menuAction, actionIdentifier: "history")
			item.representedObject = query
			return [item]
		}
		vm.setItems([branch], forMode: .commands)
		#expect(vm.filteredItems.count == 1)
		vm.filterText = "topic/ui"
		#expect(vm.selectedItem === branch)

		vm.filterText = "  /src/file.mm  "
		#expect(vm.activeMode == .commands)
		#expect(vm.queryText == "/src/file.mm")
		var openedFile: String?
		vm.onItemSelected = { openedFile = $0.representedObject as? String }
		vm.acceptSelection()
		#expect(openedFile == "/src/file.mm")
	}

	@Test func recentProjectsWithTheSameNameCanBeFoundByFullPath() {
		func project(_ path: String, subtitle: String) -> OakCommandPaletteItem {
			let item = OakCommandPaletteItem(title: "TextMate", subtitle: subtitle, keyEquivalent: "", category: .recentProject, actionIdentifier: path)
			item.representedObject = path
			return item
		}
		let vm = CommandPaletteViewModel(label: "Recent Projects", placeholder: "Search recent projects…") { _ in [] }
		let work = project("/Users/dev/work/TextMate", subtitle: "~/work/TextMate")
		let personal = project("/Users/dev/personal/TextMate", subtitle: "Favorite · ~/personal/TextMate")
		vm.setItems([work, personal], forMode: .commands)
		vm.filterText = "/Users/dev/personal"
		#expect(vm.filteredItems.count == 1)
		#expect(vm.selectedItem === personal)
	}

	@Test func filePalettePreservesExternalRankingAndSelection() {
		func file(_ path: String) -> OakCommandPaletteItem {
			OakCommandPaletteItem(title: "main.go", subtitle: path, keyEquivalent: "", category: .file, actionIdentifier: path)
		}
		let vm = CommandPaletteViewModel(label: "Open Quickly", placeholder: "Search files…") { _ in [] }
		var query = ""
		var scope = 0
		vm.configureSearch(query: "main.go:42", scopes: ["All", "Open Documents"], scope: 0) {
			query = $0
			scope = $1
		}
		#expect(vm.filterText == "main.go:42")
		let first = file("src/main.go")
		let second = file("test/main.go")
		vm.setSearchResults([first, second], searching: true)
		#expect(vm.filteredItems.map(\.item.actionIdentifier) == ["src/main.go", "test/main.go"])
		#expect(vm.isSearching)
		vm.selectNext()
		vm.setSearchResults([file("test/main.go"), first], searching: false)
		#expect(!vm.isSearching)
		#expect(vm.selectedItem?.actionIdentifier == "test/main.go")

		vm.filterText = "src/main.go:21"
		vm.searchScope = 1
		#expect(query == "src/main.go:21")
		#expect(scope == 1)
		var selected: String?
		vm.onItemSelected = { selected = $0.actionIdentifier }
		vm.setSearchResults([first], searching: false)
		vm.acceptSelection()
		#expect(selected == "src/main.go")
	}

	@Test func frecencyBoostDecaysOverTime() {
		let vm = CommandPaletteViewModel()
		let now = Date().timeIntervalSinceReferenceDate
		let oneWeekAgo = now - 168 * 3600

		vm.updateFrecency(for: "old", at: oneWeekAgo)
		vm.updateFrecency(for: "recent", at: now)

		let oldBoost = vm.frecencyBoost(for: "old")
		let recentBoost = vm.frecencyBoost(for: "recent")
		#expect(recentBoost > oldBoost)
	}

	@Test func managingProjectsKeepsSelectionAcrossSearchAndRemovesOnlyTheRequestedEntry() {
		let vm = CommandPaletteViewModel(label: "Manage Recent Projects", placeholder: "Search…") { _ in [] }
		let recent = OakCommandPaletteItem(title: "TextMate", subtitle: "~/work/TextMate", keyEquivalent: "", category: .recentProject, actionIdentifier: "recent")
		let favorite = OakCommandPaletteItem(title: "TextMate", subtitle: "Favorite · ~/work/TextMate", keyEquivalent: "", category: .recentProject, actionIdentifier: "favorite")
		let other = OakCommandPaletteItem(title: "Example", subtitle: "~/work/Example", keyEquivalent: "", category: .recentProject, actionIdentifier: "other")
		recent.removalLabel = "Remove from Recent Projects"
		var opened: [String] = []
		vm.onItemsSelected = { opened = $0.map(\.actionIdentifier) }
		vm.onItemRemoved = { $0 === recent }
		vm.setItems([recent, favorite, other], forMode: .commands)
		vm.toggleMark(recent)
		vm.toggleMark(favorite)
		vm.filterText = "Example"
		#expect(vm.selectedItem === other)
		vm.toggleMark(other)
		vm.remove(recent)
		vm.acceptSelection()
		#expect(opened == ["favorite", "other"])
		vm.filterText = "TextMate"
		#expect(vm.filteredItems.map(\.item.id) == [favorite.id])
	}

	@Test func failedProjectRemovalKeepsTheRecordAndSelection() {
		let vm = CommandPaletteViewModel(label: "Manage Recent Projects", placeholder: "Search…") { _ in [] }
		let item = OakCommandPaletteItem(title: "TextMate", subtitle: "~/work/TextMate", keyEquivalent: "", category: .recentProject, actionIdentifier: "recent")
		item.removalLabel = "Remove from Recent Projects"
		vm.onItemsSelected = { _ in }
		vm.onItemRemoved = { _ in false }
		vm.setItems([item], forMode: .commands)
		vm.toggleMark(item)
		vm.remove(item)
		#expect(vm.removalError != nil)
		#expect(vm.selectedItem === item)
		#expect(vm.itemsToOpen.first === item)
	}

	@Test func selectionNavigationWorks() {
		let vm = CommandPaletteViewModel()
		let items = [
			OakCommandPaletteItem(title: "Aa", subtitle: "", keyEquivalent: "", category: .menuAction, actionIdentifier: "a"),
			OakCommandPaletteItem(title: "Bb", subtitle: "", keyEquivalent: "", category: .menuAction, actionIdentifier: "b"),
			OakCommandPaletteItem(title: "Cc", subtitle: "", keyEquivalent: "", category: .menuAction, actionIdentifier: "c"),
		]
		vm.setItems(items, forMode: .commands)
		vm.filterText = ">"
		#expect(vm.selectedIndex == 0)
		vm.selectNext()
		#expect(vm.selectedIndex == 1)
		vm.selectNext()
		#expect(vm.selectedIndex == 2)
		vm.selectNext()
		#expect(vm.selectedIndex == 2)
		vm.selectPrevious()
		#expect(vm.selectedIndex == 1)
	}
}
