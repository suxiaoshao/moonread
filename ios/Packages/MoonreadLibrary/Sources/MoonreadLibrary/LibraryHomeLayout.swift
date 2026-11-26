import MoonreadDesign
import SwiftUI

public struct LibraryHomeLayout<SectionContent: View>: View {
    let enabledSections: [LibraryHomeSection]
    let showsSection: (LibraryHomeSection) -> Bool
    let editHome: () -> Void
    let refresh: () async -> Void
    let homeSection: (LibraryHomeSection) -> SectionContent
    @Environment(\.horizontalSizeClass) private var sizeClass

    public init(enabledSections: [LibraryHomeSection], showsSection: @escaping (LibraryHomeSection) -> Bool,
                editHome: @escaping () -> Void, refresh: @escaping () async -> Void,
                @ViewBuilder section: @escaping (LibraryHomeSection) -> SectionContent) {
        self.enabledSections = enabledSections
        self.showsSection = showsSection
        self.editHome = editHome
        self.refresh = refresh
        homeSection = section
    }
    public var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if enabledSections.contains(where: showsSection) {
                    VStack(alignment: .leading, spacing: 24) {
                        if sizeClass == .regular && geometry.size.width >= 720 {
                            wideSections
                        } else {
                            sectionStack(enabledSections)
                        }
                    }
                    .padding([.horizontal, .top], 20).padding(.bottom)
                    .frame(maxWidth: 1040).frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView {
                        Label(enabledSections.isEmpty ? "首页区块已全部隐藏" : "暂无可显示的区块",
                              systemImage: "rectangle.3.group")
                    } actions: {
                        Button("编辑首页", systemImage: "pencil", action: editHome).buttonStyle(.bordered)
                    }
                    .frame(minHeight: geometry.size.height)
                }
            }
            .refreshable { await refresh() }
        }.themedPage()
    }

    @ViewBuilder private var wideSections: some View {
        let enabled = enabledSections
        let hasBanner = enabled.first == .resume
        let columns = hasBanner ? Array(enabled.dropFirst()) : enabled
        let leftCount = (columns.count + 1) / 2
        let left = Array(columns.prefix(leftCount))
        let right = Array(columns.dropFirst(leftCount))
        if hasBanner, showsSection(.resume) { homeSection(.resume) }
        if columns.contains(where: showsSection) {
            HStack(alignment: .top, spacing: 24) {
                if left.contains(where: showsSection) {
                    sectionStack(left).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                if right.contains(where: showsSection) {
                    sectionStack(right).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private func sectionStack(_ sections: [LibraryHomeSection]) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(sections.filter(showsSection)) { section in
                homeSection(section)
            }
        }
    }
}
