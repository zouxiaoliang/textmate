import SwiftUI

struct CommandPaletteView: View {
	@ObservedObject var viewModel: CommandPaletteViewModel
	@EnvironmentObject var theme: OakThemeEnvironment
	@FocusState private var isSearchFieldFocused: Bool

	var body: some View {
		VStack(spacing: 0) {
			searchField
			Divider()
			resultsList
			if viewModel.managesItems { managementFooter }
		}
		.background(Color(nsColor: theme.backgroundColor).opacity(0.85))
		.clipShape(RoundedRectangle(cornerRadius: 6))
		.onKeyPress(.downArrow) { viewModel.selectNext(); return .handled }
		.onKeyPress(.upArrow) { viewModel.selectPrevious(); return .handled }
		.onKeyPress(keys: [.return]) { press in
			if viewModel.managesItems, press.modifiers.contains(.command), let item = viewModel.selectedItem {
				viewModel.toggleMark(item)
			} else {
				viewModel.acceptSelection()
			}
			return .handled
		}
		.onKeyPress(.escape) { viewModel.requestDismiss(); return .handled }
		.onAppear { isSearchFieldFocused = true }
	}

	private var managementFooter: some View {
		VStack(spacing: 0) {
			Divider()
			HStack(spacing: 10) {
				Text(viewModel.removalError ?? (viewModel.markedItems.isEmpty ? "⌘↩ Select project" : "\(viewModel.markedItems.count) selected"))
					.font(.caption)
					.foregroundStyle(viewModel.removalError == nil ? Color.secondary : Color.red)
				Spacer()
				Button(viewModel.markedItems.count > 1 ? "Open Projects" : "Open Project") { viewModel.acceptSelection() }
					.disabled(viewModel.itemsToOpen.isEmpty)
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
		}
	}

	private func resultRow(_ ranked: RankedItem, at index: Int) -> some View {
		let item = ranked.item
		let marked = viewModel.markedItems.contains(item.id)
		return HStack(spacing: 4) {
			if viewModel.managesItems {
				Button { viewModel.toggleMark(item) } label: {
					Image(systemName: marked ? "checkmark.square.fill" : "square")
						.foregroundStyle(marked ? Color.accentColor : Color.secondary)
						.frame(width: 24, height: 26)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.disabled(!item.enabled)
				.accessibilityLabel(marked ? "Deselect \(item.title)" : "Select \(item.title)")
			}
			CommandPaletteRowView(item: item, matchedIndices: ranked.matchedIndices, isSelected: index == viewModel.selectedIndex)
				.contentShape(Rectangle())
				.onTapGesture {
					guard item.enabled else { return }
					viewModel.selectedIndex = index
					if !viewModel.managesItems { viewModel.acceptSelection() }
				}
			if viewModel.managesItems, let label = item.removalLabel {
				Button { viewModel.remove(item) } label: {
					Image(systemName: "minus.circle")
						.foregroundStyle(.secondary)
						.frame(width: 26, height: 26)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.help(label)
				.accessibilityLabel(label)
			} else if viewModel.managesItems {
				Color.clear.frame(width: 26, height: 1)
			}
		}
		.id(ranked.id)
	}

	private var searchField: some View {
		HStack(spacing: 6) {
			if let label = viewModel.searchLabel {
				modePill(label)
			}
			TextField(viewModel.searchPlaceholder, text: $viewModel.filterText)
				.textFieldStyle(.plain)
				.font(.system(size: theme.fontSize, design: .monospaced))
				.focused($isSearchFieldFocused)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
	}

	private func modePill(_ label: String) -> some View {
		Text(label)
			.font(.system(size: max(theme.fontSize - 2, 9), weight: .medium))
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.background(Color.accentColor.opacity(0.2))
			.foregroundStyle(Color.accentColor)
			.clipShape(RoundedRectangle(cornerRadius: 4))
	}

	private var resultsList: some View {
		ScrollViewReader { proxy in
			ScrollView(.vertical) {
				LazyVStack(spacing: 0) {
					if viewModel.filteredItems.isEmpty {
						Text(viewModel.queryText.isEmpty ? "No items to show" : "No matching results")
							.font(.system(size: theme.fontSize))
							.foregroundStyle(.secondary)
							.frame(maxWidth: .infinity, alignment: .leading)
							.padding(8)
					}
					ForEach(Array(viewModel.filteredItems.enumerated()), id: \.element.id) { index, ranked in
						resultRow(ranked, at: index)
					}
				}
				.padding(.vertical, 4)
				.padding(.horizontal, 4)
			}
			.frame(maxHeight: max(theme.fontSize * 2.4, 32) * 10 + 8)
			.onChange(of: viewModel.selectedIndex) { _, newValue in
				guard newValue < viewModel.filteredItems.count else { return }
				withAnimation(.easeOut(duration: 0.1)) {
					proxy.scrollTo(viewModel.filteredItems[newValue].id, anchor: .center)
				}
			}
		}
	}
}
