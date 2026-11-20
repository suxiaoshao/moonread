import SwiftUI

struct ReaderSettingsView: View {
    @Binding var settings: ReaderSettings
    let preview: ReadingPreviewSource
    let encoding: String?
    let isRestartingEncoding: Bool
    let changeEncoding: ((String?) -> Void)?
    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.displayScale) private var displayScale
    @AppStorage("readingSettingsTab") private var tab = ReadingSettingsTab.typography
    @State private var localEditing = ReadingSettingsEditing()
    let editing: ReadingSettingsEditing?
    var editorClosed: () -> Void = {}
    private var editor: ReadingSettingsEditing { editing ?? localEditing }
    private var editedAppearance: ThemeAppearance? {
        get { editor.editedAppearance }
        nonmutating set { editor.editedAppearance = newValue }
    }
    private var previewPresented: Bool {
        get { editor.previewPresented }
        nonmutating set { editor.previewPresented = newValue }
    }
    private var previewDetent: PresentationDetent {
        get { editor.previewDetent }
        nonmutating set { editor.previewDetent = newValue }
    }
    @State private var previewHeight: CGFloat = 0
    private var draft: PaletteDraft? {
        get { editor.draft }
    }
    private var navigation: NavigationPresentationState {
        get { editor.navigation }
        nonmutating set { editor.navigation = newValue }
    }
    private var previewPosition: ReadingPreviewPosition {
        get { editor.previewPosition }
        nonmutating set { editor.previewPosition = newValue }
    }
    private var previewVisible: Bool {
        get { editor.previewVisible }
        nonmutating set { editor.previewVisible = newValue }
    }
    private var appeared: Bool {
        get { editor.appeared }
        nonmutating set { editor.appeared = newValue }
    }

    init(settings: Binding<ReaderSettings>, preview: ReadingPreviewSource = .sample, encoding: String? = nil, isRestartingEncoding: Bool = false, changeEncoding: ((String?) -> Void)? = nil,
         editing: ReadingSettingsEditing? = nil, editorClosed: @escaping () -> Void = {}) {
        _settings = settings; self.preview = preview; self.encoding = encoding; self.isRestartingEncoding = isRestartingEncoding; self.changeEncoding = changeEncoding
        self.editing = editing
        self.editorClosed = editorClosed
    }
    private var appearance: ThemeAppearance { editedAppearance ?? themes.reader.plan.appearance }
    private var previewExpanded: Bool { verticalSizeClass == .compact || previewDetent == .large }
    private var previewCollapsed: Bool { verticalSizeClass != .compact && previewDetent == .height(60) }
    private var previewTheme: ThemeSurface {
        if let draft {
            return ThemeSurface(plan: ResolvedTheme(highContrast: themes.highContrast,
                surface: .palette(appearance: draft.palette.appearance, id: draft.palette.id, colors: draft.palette.colors)))
        }
        var snapshot = themes.snapshot
        snapshot.preferences.readerMode = appearance == .light ? .light : .dark
        guard let plan = try? resolveThemes(value: snapshot, system: themes.system, highContrast: themes.highContrast) else { return themes.reader }
        return ThemeSurface(plan: plan.reader, readerTexture: plan.readerTexture)
    }
    var body: some View {
        @Bindable var editing = editor
        GeometryReader { geometry in
            // Keep enough room for both native controls and readable text.
            let wide = geometry.size.width >= 760
            let compact = horizontalSizeClass == .compact
            // The system sheet covers a full-height control viewport. Only the
            // scrollable content needs room to move its last row above it.
            let bottomContentInset = compact && !wide && previewVisible
                ? min(geometry.size.height, max(0, previewHeight - geometry.safeAreaInsets.bottom)) : 0
            HStack(spacing: 0) {
                ReadingSettingsControls(settings: $settings, tab: $tab, editedAppearance: $editing.editedAppearance, encoding: encoding, isRestartingEncoding: isRestartingEncoding, changeEncoding: changeEncoding,
                                     bottomContentInset: bottomContentInset, editPalette: { value in
                                         if compact && !wide && previewPresented { previewDetent = .large }
                                         editor.beginPalette(value, presenter: previewVisible ? .preview : .settings)
                                     })
                    .frame(width: wide ? min(400, geometry.size.width * 0.46) : nil)
                    .frame(maxHeight: .infinity, alignment: .top)
                if wide && editor.paletteSession?.presenter != .preview {
                    readingPreview
                        .background {
                            ReadingPreviewBackdrop(surface: previewTheme)
                        }
                        .clipShape(.rect(cornerRadius: 16))
                        .padding(LayoutTokens.content)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !wide && !compact {
                    VStack(spacing: 0) {
                        Button {
                            withAnimation(MotionTokens.panel(reduced: reduceMotion)) {
                                previewDetent = previewDetent == .height(60) ? .medium : .height(60)
                            }
                        } label: {
                            HStack {
                                Text("阅读预览 · \(Int(settings.fontSize))").font(.caption.weight(.medium))
                                Spacer()
                                Image(systemName: previewDetent == .height(60) ? "chevron.up" : "chevron.down")
                            }.frame(minHeight: LayoutTokens.hit).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color(uiColor: previewTheme.secondary))
                        .padding(.horizontal, LayoutTokens.content)
                        .accessibilityIdentifier("toggleReadingPreview")
                        if previewDetent != .height(60) {
                            readingPreview.frame(height: min(300, geometry.size.height * 0.4))
                        }
                    }
                    .background {
                        ReadingPreviewBackdrop(surface: previewTheme)
                    }
                } else if compact && !wide && !previewPresented {
                    Button("阅读预览", systemImage: "doc.text.magnifyingglass") {
                        previewDetent = verticalSizeClass == .compact ? .large : .height(60)
                        previewPresented = true
                    }
                    .frame(maxWidth: .infinity, minHeight: LayoutTokens.hit)
                    .accessibilityIdentifier("showReadingPreview")
                }
            }
            .background(Color(uiColor: theme.canvas).ignoresSafeArea())
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.visible, for: .navigationBar)
            .toolbarVisibility(compact ? .hidden : .automatic, for: .tabBar)
            .statusBarHidden(false)
            .background(NavigationTransitionObserver(willLeave: { _ in
                previewPosition.capture()
                navigation.begin(hasPresentation: previewVisible)
            }, completed: { _, cancelled in navigation.finish(cancelled: cancelled) }))
            .onAppear {
                navigation.appear()
                if !appeared {
                    appeared = true
                    previewPresented = verticalSizeClass != .compact
                }
            }
            .sheet(item: paletteBinding(.settings), onDismiss: editorClosed) { value in
                if case let .palette(draft) = value.payload { paletteEditor(draft) }
            }
            .sheet(isPresented: Binding(get: { editor.paletteSession?.presenter == .preview || (compact && !wide && previewPresented && !navigation.isSuspended) }, set: {
                guard editor.paletteSession?.presenter != .preview else { return }
                if compact && !wide && !navigation.isSuspended { previewPresented = $0 }
            }), onDismiss: {
                previewVisible = false
                navigation.presentationDismissed()
            }) {
                VStack(spacing: 0) {
                    Button {
                        if verticalSizeClass == .compact {
                            previewPresented = false
                        } else { withAnimation(MotionTokens.panel(reduced: reduceMotion)) {
                            previewDetent = previewCollapsed ? .medium : (previewDetent == .medium ? .large : .height(60))
                        } }
                    } label: {
                        HStack {
                            Text("阅读预览 · \(Int(settings.fontSize))").font(.caption.weight(.medium))
                            Spacer()
                            Text(previewExpanded ? "收起" : "展开").font(.caption)
                            Image(systemName: previewExpanded ? "chevron.down" : "chevron.up")
                        }
                        .frame(minHeight: LayoutTokens.hit).contentShape(.rect)
                    }
                    .buttonStyle(.plain).padding(.horizontal, LayoutTokens.content)
                    .foregroundStyle(Color(uiColor: previewTheme.secondary))
                    .accessibilityIdentifier("toggleReadingPreview")
                    .accessibilityLabel(previewExpanded ? "收起预览" : "展开预览")
                    #if DEBUG
                    .accessibilityValue(ProcessInfo.processInfo.arguments.contains("--ui-testing")
                        ? (previewExpanded ? "full" : previewDetent == .medium ? "half" : "compact") : "")
                    #endif
                    readingPreview
                        .opacity(previewCollapsed ? 0 : 1)
                        .accessibilityHidden(previewCollapsed)
                        .allowsHitTesting(!previewCollapsed)
                }
                .clipped()
                .padding(.top, LayoutTokens.control)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height + proxy.safeAreaInsets.bottom
                } action: { height in
                    if previewHeight != height { previewHeight = height }
                }
                .presentationSizing(.page)
                .presentationDetents([.height(60), .medium, .large], selection: $editing.previewDetent)
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.resizes)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationBackground {
                    ReadingPreviewBackdrop(surface: previewTheme).ignoresSafeArea()
                }
                .preferredColorScheme(previewTheme.scheme)
                .readerToolPresentation()
                .interactiveDismissDisabled()
                .onAppear { previewVisible = true }
                .sheet(item: paletteBinding(.preview), onDismiss: {
                    if verticalSizeClass != .compact { previewDetent = .height(60) }
                    editorClosed()
                }) { value in
                    if case let .palette(draft) = value.payload { paletteEditor(draft) }
                }
            }
            .onChange(of: themes.snapshot.preferences.readerMode) { _, _ in editedAppearance = nil }
        }
    }
    private var readingPreview: some View {
        ReadingPreviewPane(source: preview, settings: settings, surface: previewTheme, position: previewPosition)
            .onDisappear { previewPosition.capture() }
    }
    private func paletteBinding(_ presenter: ReaderEditPresenter) -> Binding<ReaderEditSession?> {
        let current = editor.paletteSession(for: presenter)
        return Binding(get: { editor.paletteSession(for: presenter) }, set: {
            if $0 == nil, let current { editor.finishPalette(current.id) }
        })
    }

    private func paletteEditor(_ value: PaletteDraft) -> some View {
        PaletteEditor(draft: value, showsAppPreview: false)
        .readerToolPresentation()
        .themeScope(theme)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: theme.canvas))
    }
}

#if DEBUG
/// The isolated screenshot route uses the same app preference owner.
struct PageShotReaderSettings: View {
    @Environment(ReaderSettingsStore.self) private var settings
    @State private var error: String?
    var body: some View {
        Group {
            if settings.value != nil {
                ReaderSettingsView(settings: settings.binding)
            } else if let error { Text(verbatim: error) }
            else { ProgressView() }
        }.task {
            do { try settings.load() }
            catch { self.error = ReaderMessages.error(error) }
        }
    }
}
#endif
