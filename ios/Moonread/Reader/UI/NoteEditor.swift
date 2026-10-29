import SwiftUI
import UIKit

@MainActor @Observable
final class NoteEditorModel {
    private let baseline: AnnotationEdit
    var saving = false
    var hasUnsavedChanges: Bool {
        !saving && !committed && (initiallyChanged || conflictChoice || deleteChoice || text != baseline.note || edit.startUtf8 != baseline.startUtf8 || edit.endUtf8 != baseline.endUtf8 || edit.excerpt != baseline.excerpt)
    }
    private var initiallyChanged: Bool {
        guard baseline.marks.count == 1, let mark = baseline.marks.first else { return true }
        return baseline.startUtf8 != mark.startUtf8 || baseline.endUtf8 != mark.endUtf8 || baseline.note != mark.note
    }
    var edit: AnnotationEdit
    var conflicts: [AnnotationCandidate] = []
    private var conflictBaselines: [String: [AnnotationCandidate]] = [:]
    let service: AppDataService
    var conflictChoice = false
    var loadingConflicts = true
    var deleteChoice = false
    var text: String
    var error: String?
    private var committed = false
    @ObservationIgnored private let aiCommit: AIAnnotationCommitHooks?
    @ObservationIgnored private let onCommitted: (() -> Void)?
    init(edit: AnnotationEdit, service: AppDataService = .shared, onCommitted: (() -> Void)? = nil, aiCommit: AIAnnotationCommitHooks? = nil) {
        self.edit = edit; baseline = edit; self.service = service; text = edit.note; self.onCommitted = onCommitted; self.aiCommit = aiCommit
    }
    func loadConflicts() async {
        defer { loadingConflicts = false }
        do {
            let bundle = try await service.annotationEditingBundle(edit)
            let next = (bundle.values.contains(where: AnnotationReduction.conflicts) || edit.baselines.values.contains(where: AnnotationReduction.conflicts))
                ? bundle.values.flatMap { $0 }.filter { $0.mergedInto == nil }.sorted { ($0.created, $0.id) < ($1.created, $1.id) } : []
            if bundle.mapValues({ Set($0.map(\.id)) }) != conflictBaselines.mapValues({ Set($0.map(\.id)) }) {
                conflictChoice = false; deleteChoice = false
            }
            conflictBaselines = bundle
            conflicts = next
            for (id, heads) in bundle where edit.baselines[id] == nil { edit.baselines[id] = heads }
        } catch { self.error = ReaderMessages.error(error) }
    }
    func choose(_ value: AnnotationCandidate) {
        error = nil
        deleteChoice = value.content == nil
        if let content = value.content {
            edit.startUtf8 = content.start; edit.endUtf8 = content.end; edit.excerpt = content.excerpt; text = content.note
        } else { text = "" }
        conflictChoice = true
    }
    func keepBoth() async {
        let contents = conflicts.compactMap(\.content).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        guard let first = contents.first, let last = contents.map(\.end).max() else { return }
        do {
            edit.startUtf8 = contents.map(\.start).min() ?? first.start; edit.endUtf8 = last
            edit.excerpt = String(try await service.textRange(edit.bookId, start: edit.startUtf8, end: last).text.prefix(160))
            text = contents.map(\.note).filter { !$0.isEmpty }.joined(separator: "\n\n")
            deleteChoice = false; conflictChoice = true
        } catch { self.error = ReaderMessages.error(error) }
    }
    func beginCommit() -> Task<Bool, Never>? {
        guard !saving else { return nil }
        saving = true
        return Task { defer { saving = false }; return await commitContents() }
    }
    func commit() async -> Bool {
        guard let write = beginCommit() else { return false }
        return await write.value
    }
    private func commitContents() async -> Bool {
        guard !committed else { return true }
        guard error == nil else { return false }
        var ticket: AIAnnotationCommitTicket?
        defer { if let ticket { aiCommit?.finish(ticket) } }
        do {
            if !conflicts.isEmpty && !conflictChoice { return false }
            ticket = try aiCommit?.begin()
            if !conflicts.isEmpty {
                let content = deleteChoice ? nil : AnnotationContent(start: edit.startUtf8, end: edit.endUtf8, excerpt: edit.excerpt, note: text)
                try await service.resolveAnnotation(edit, expected: conflictBaselines, content: content)
            } else {
                _ = try await service.saveNote(edit, text: text)
                await loadConflicts()
                if !conflicts.isEmpty { return false }
            }
            committed = true; aiCommit?.saved(); onCommitted?(); return true
        } catch {
            await loadConflicts(); self.error = ReaderMessages.error(error); return false
        }
    }
}


struct NoteEditor: View {
    @Environment(\.theme) private var theme
    @State private var model: NoteEditorModel
    private var saving: Bool { model.saving }
    let close: () -> Void
    init(edit: AnnotationEdit, onCommitted: (() -> Void)? = nil, aiCommit: AIAnnotationCommitHooks? = nil, close: @escaping () -> Void) {
        _model = State(initialValue: NoteEditorModel(edit: edit, onCommitted: onCommitted, aiCommit: aiCommit))
        self.close = close
    }
    init(model: NoteEditorModel, close: @escaping () -> Void) { _model = State(initialValue: model); self.close = close }
    var body: some View {
        NavigationStack { NoteEditorContent(model: model, close: close) }
    }
}

struct NoteEditorContent: View {
    @Environment(\.theme) private var theme
    @Bindable var model: NoteEditorModel
    let close: () -> Void
    var usesNavigation = true
    private var saving: Bool { model.saving }
    private var fields: some View {
            VStack(spacing: 0) {
                if !model.conflicts.isEmpty && model.conflictChoice {
                    HStack {
                        Text(model.deleteChoice ? "已选择删除，完成后移除批注" : "已选定结果，可继续编辑").font(.callout)
                        Spacer()
                        Button("重新选择") { model.conflictChoice = false; model.deleteChoice = false }
                    }.padding()
                } else if !model.conflicts.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: LayoutTokens.control) {
                            Text("批注存在并发修改").font(.headline)
                            // Each version carries its own choice; nothing depends on card order.
                            ForEach(model.conflicts) { candidate in
                                VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                                    if let content = candidate.content {
                                        Text(verbatim: content.excerpt).font(.callout).foregroundStyle(Color(uiColor: theme.secondary))
                                        Text(verbatim: content.note.isEmpty ? String(localized: "仅高亮") : content.note)
                                    } else { Text("删除这条批注") }
                                    Button("使用这一版") { model.choose(candidate) }
                                        .buttonStyle(.bordered).tint(Color(uiColor: theme.accent))
                                        // The scope's ink foreground would otherwise override the tinted label.
                                        .foregroundStyle(Color(uiColor: theme.accent))
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                        .accessibilityIdentifier(candidate.content == nil ? "chooseAnnotationDeletion" : "chooseAnnotation-\(candidate.id)")
                                }.padding(LayoutTokens.control).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(uiColor: theme.raised), in: .rect(cornerRadius: 8))
                                    .accessibilityElement(children: .contain)
                            }
                            Button { Task { await model.keepBoth() } } label: { Text("保留两者").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered).tint(Color(uiColor: theme.ink))
                            Text("选择范围后，可在下方手动编辑最终评论。").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                        }.padding()
                    }.frame(maxHeight: 300)
                }
                if model.deleteChoice && model.conflictChoice {
                    Text("已选择删除，完成后移除批注").foregroundStyle(Color(uiColor: theme.secondary))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("noteDeletionState")
                } else {
                    NoteEditorForm(model: model, enabled: !saving, text: model.text, excerpt: model.edit.excerpt, focus: !model.loadingConflicts && (model.conflicts.isEmpty || model.conflictChoice))
                }
            }
                // UIKit owns keyboard avoidance for this form. There must not
                // be a second SwiftUI resize while the sheet is closing.
                .ignoresSafeArea(.keyboard)
    }
    var body: some View {
        Group {
            if usesNavigation {
                fields.navigationTitle("批注").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { cancelButton }
                        ToolbarItem(placement: .confirmationAction) { saveButton }
                    }
            } else {
                VStack(spacing: 0) {
                    ReaderToolPageHeader("批注") { cancelButton; saveButton }
                    fields
                }
            }
        }
            .task { await model.loadConflicts() }
            .onReceive(NotificationCenter.default.publisher(for: .cloudDataReceived).receive(on: DispatchQueue.main)) { _ in Task { await model.loadConflicts() } }
            .onChange(of: model.text) { _, _ in model.error = nil }
            .modifier(SystemReadingConfirmation(editor: true))
            .interactiveDismissDisabled(saving)
            .alert("暂时无法保存", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("知道了", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
    }
    private var cancelButton: some View {
        Button("取消", systemImage: "xmark") { close() }
            .labelStyle(.titleOnly).disabled(saving).accessibilityIdentifier("closeNote")
    }
    private var saveButton: some View {
        Button("完成", systemImage: "checkmark") { finish() }
            .labelStyle(.titleOnly)
            .disabled(saving || (!model.conflicts.isEmpty && !model.conflictChoice)).accessibilityIdentifier("saveNote")
    }
    private func finish() {
        guard let write = model.beginCommit() else { return }
        Task {
            if await write.value {
                close()
            }
        }
    }
}


private struct NoteEditorForm: UIViewControllerRepresentable {
    @Environment(\.theme) private var theme
    let model: NoteEditorModel
    let enabled: Bool
    let text: String
    let excerpt: String
    let focus: Bool

    func makeUIViewController(context: Context) -> NoteEditorFormController {
        NoteEditorFormController(model: model)
    }

    func updateUIViewController(_ controller: NoteEditorFormController, context: Context) {
        controller.editingEnabled = enabled
        controller.applyTheme(theme)
        controller.applyContent(text: text, excerpt: excerpt)
        controller.shouldFocus = focus
    }
}


/// One native scroll view owns the keyboard and a content-sized input. Empty
/// space below a short note belongs to the form, not an invisible tall editor.
@MainActor
private final class NoteEditorFormController: UIViewController, UITextViewDelegate, UIGestureRecognizerDelegate {
    private let model: NoteEditorModel
    private let scroll = UIScrollView()
    private let input = UITextView()
    private let excerpt = UILabel()
    private let quote = UIView()
    private var theme = ThemeSurface.initial
    private var initiallyFocused = false
    private var appeared = false
    var shouldFocus = false {
        didSet {
            if !shouldFocus && isViewLoaded { input.resignFirstResponder(); initiallyFocused = false }
            else if appeared { focusInitially() }
        }
    }
    var editingEnabled = true

    init(model: NoteEditorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = theme.surface
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        scroll.accessibilityIdentifier = "noteEditorScroll"
        view.addSubview(scroll)

        excerpt.text = model.edit.excerpt
        excerpt.numberOfLines = 0
        excerpt.font = .preferredFont(forTextStyle: .subheadline)
        excerpt.adjustsFontForContentSizeCategory = true
        excerpt.textColor = theme.secondary
        excerpt.accessibilityIdentifier = "noteExcerpt"
        excerpt.translatesAutoresizingMaskIntoConstraints = false
        quote.backgroundColor = theme.raised
        quote.layer.cornerRadius = LayoutTokens.inputRadius
        quote.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        quote.addSubview(excerpt)

        input.text = model.text
        input.font = .preferredFont(forTextStyle: .body)
        input.adjustsFontForContentSizeCategory = true
        input.backgroundColor = theme.input
        input.textContainerInset = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        input.textContainer.lineFragmentPadding = 0
        input.layer.cornerRadius = LayoutTokens.inputRadius
        input.layer.cornerCurve = .continuous
        input.layer.borderWidth = LayoutTokens.border
        input.isScrollEnabled = false
        input.delegate = self
        input.accessibilityLabel = String(localized: "批注内容")
        input.accessibilityIdentifier = "noteEditorText"

        let content = UIStackView(arrangedSubviews: [quote, input])
        content.axis = .vertical
        content.spacing = 20
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
            excerpt.topAnchor.constraint(equalTo: quote.layoutMarginsGuide.topAnchor),
            excerpt.leadingAnchor.constraint(equalTo: quote.layoutMarginsGuide.leadingAnchor),
            excerpt.trailingAnchor.constraint(equalTo: quote.layoutMarginsGuide.trailingAnchor),
            excerpt.bottomAnchor.constraint(equalTo: quote.layoutMarginsGuide.bottomAnchor),
            input.heightAnchor.constraint(greaterThanOrEqualToConstant: 104)
        ])

        applyTheme(theme)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (controller: NoteEditorFormController, _: UITraitCollection) in
            controller.updateInputBorder()
        }

        let outsideTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        outsideTap.cancelsTouchesInView = false
        outsideTap.delegate = self
        view.addGestureRecognizer(outsideTap)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        // SwiftUI can forward a child's appearance before its sheet transition
        // finishes. Focus after that transition's own responder restoration.
        if let coordinator = transitionCoordinator,
           coordinator.animate(alongsideTransition: nil, completion: { [weak self] context in
               if !context.isCancelled { self?.focusInitially() }
           }) { return }
        focusInitially()
    }

    private func focusInitially() {
        guard shouldFocus, !initiallyFocused else { return }
        initiallyFocused = input.becomeFirstResponder()
    }

    @objc private func dismissKeyboard() { view.endEditing(true) }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard editingEnabled, input.isFirstResponder else { return false }
        // Native cursor placement, text selection and its handles keep their taps.
        return touch.view !== input && touch.view?.isDescendant(of: input) != true
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        editingEnabled
    }

    private func updateInputBorder() {
        let color = input.isFirstResponder ? theme.focus : theme.border
        input.layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
    }

    func applyContent(text: String, excerpt: String) {
        guard isViewLoaded else { return }
        self.excerpt.text = excerpt
        if input.text != text {
            input.text = text
            input.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            input.invalidateIntrinsicContentSize()
        }
    }

    func applyTheme(_ value: ThemeSurface) {
        theme = value
        overrideUserInterfaceStyle = value.style
        guard isViewLoaded else { return }
        view.backgroundColor = value.surface
        quote.backgroundColor = value.raised
        excerpt.textColor = value.secondary
        input.backgroundColor = value.input
        input.textColor = value.ink
        input.tintColor = value.selection
        updateInputBorder()
    }

    func textViewDidBeginEditing(_ textView: UITextView) { updateInputBorder() }
    func textViewDidEndEditing(_ textView: UITextView) { updateInputBorder() }

    func textViewDidChange(_ textView: UITextView) {
        model.text = textView.text
        input.invalidateIntrinsicContentSize()
        view.layoutIfNeeded()
        let caret = input.caretRect(for: input.selectedTextRange?.end ?? input.endOfDocument)
        scroll.scrollRectToVisible(input.convert(caret.insetBy(dx: 0, dy: -12), to: scroll), animated: false)
    }
}
