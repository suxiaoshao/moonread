import MoonreadDesign
import SwiftUI

public enum LibraryHomeSection: String, CaseIterable, Identifiable {
    case resume, shelves, saved, recent

    public var id: Self { self }
    public var title: LocalizedStringKey {
        switch self {
        case .resume: "继续阅读"
        case .shelves: "我的书架"
        case .saved: "虚拟书架"
        case .recent: "最近阅读"
        }
    }
}

public struct LibraryHomeSections {
    public var visible: [LibraryHomeSection]

    public init(visible: [String] = [], hidden: [String] = []) {
        let hidden = Set(hidden.compactMap(LibraryHomeSection.init(rawValue:)))
        var seen = hidden
        self.visible = (visible.compactMap(LibraryHomeSection.init(rawValue:)) + LibraryHomeSection.allCases)
            .filter { seen.insert($0).inserted }
    }

    public var hidden: [LibraryHomeSection] { LibraryHomeSection.allCases.filter { !visible.contains($0) } }

    mutating func hide(_ section: LibraryHomeSection) { visible.removeAll { $0 == section } }
    mutating func show(_ section: LibraryHomeSection) { visible.append(section) }
}

public struct LibraryHomeEditor: View {
    @State private var sections: LibraryHomeSections
    let save: (LibraryHomeSections) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var detent: PresentationDetent = .medium

    public init(sections: LibraryHomeSections, detent: PresentationDetent = .medium, save: @escaping (LibraryHomeSections) -> Void) {
        _sections = State(initialValue: sections)
        self.save = save
        _detent = State(initialValue: detent)
    }

    public var body: some View {
        NavigationStack {
            List {
                if !sections.visible.isEmpty {
                    Section("显示") {
                        ForEach(sections.visible) { section in
                            sectionRow(section, visible: true)
                        }
                        .onMove { sections.visible.move(fromOffsets: $0, toOffset: $1) }
                    }
                }
                if !sections.hidden.isEmpty {
                    Section("隐藏") {
                        ForEach(sections.hidden) { section in
                            sectionRow(section, visible: false)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .themedPage()
            .navigationTitle("编辑首页").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SystemToolbarButton("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SystemToolbarButton("完成", role: .confirm) {
                        save(sections)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onChange(of: typeSize, initial: true) { _, size in
            if size.isAccessibilitySize { detent = .large }
        }
    }

    private func sectionRow(_ section: LibraryHomeSection, visible: Bool) -> some View {
        HStack(spacing: LayoutTokens.compact) {
            Button {
                withAnimation {
                    if visible { sections.hide(section) }
                    else { sections.show(section) }
                }
            } label: {
                Image(systemName: visible ? "minus.circle.fill" : "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(visible ? Color.red : Color.green)
                    .frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(visible ? Text("隐藏\(Text(section.title))") : Text("显示\(Text(section.title))"))
            Text(section.title)
        }
        .listRowBackground(Color(uiColor: theme.surface))
    }
}
