import AppKit
import ColonCore
import SwiftUI

/// Root of the GIF panel's hosting view: the shared glass card around the GIF picker.
struct GIFRootView: View {
    @ObservedObject var model: GIFPickerModel
    let loader: GIFImageLoader
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = PickerTheme(scheme)
        GlassCard(theme: theme,
                  size: CGSize(width: GIFMetrics.cardWidth, height: GIFMetrics.cardHeight),
                  alignment: .top,
                  isPresented: model.isPresented,
                  reduceMotion: model.reduceMotion) {
            GIFPickerView(model: model, loader: loader, theme: theme)
        }
    }
}

/// Search field on top, animated grid (or a state message) in the middle, title + attribution below.
struct GIFPickerView: View {
    @ObservedObject var model: GIFPickerModel
    let loader: GIFImageLoader
    let theme: PickerTheme

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .frame(height: GIFMetrics.searchFieldHeight)
            Rectangle().fill(theme.divider).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            GIFFooter(model: model, theme: theme)
                .frame(height: GIFMetrics.footerHeight)
        }
        .overlay(alignment: .top) {
            if model.isLoading || model.isRefining {
                RefiningShimmer(theme: theme)
                    .padding(.top, GIFMetrics.searchFieldHeight)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.isLoading || model.isRefining)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Text("GIF")
                .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.accent.opacity(theme.isDark ? 0.16 : 0.12)))
            GIFSearchField(model: model, theme: theme)
                .frame(height: 24)
            if model.isRefining || model.isReranked {
                GIFJevBadge(isRefining: model.isRefining, theme: theme)
                    .transition(.opacity)
            }
            Keycap("esc", theme: theme)
        }
        .padding(.horizontal, 16)
        .animation(.pickerEase(0.2), value: model.isRefining || model.isReranked)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .starting, .loading:
            GIFSkeletonGrid(theme: theme, reduceMotion: model.reduceMotion)
                .transition(.opacity)
        case .results:
            GIFGrid(model: model, loader: loader, theme: theme)
                .transition(.opacity)
        case .empty:
            GIFMessageView(symbol: "magnifyingglass",
                           title: "No GIFs for “\(model.searchText.trimmingCharacters(in: .whitespaces))”",
                           message: "Try a feeling or a reaction, like “excited”, “facepalm” or “thank you”.",
                           theme: theme)
                .transition(.opacity)
        case .problem(let problem):
            GIFProblemView(problem: problem, model: model, theme: theme)
                .transition(.opacity)
        }
    }
}

// MARK: - Search field

/// AppKit text field so the controller can focus it deterministically and arrow/return/escape
/// reach the model before the field editor consumes them.
struct GIFSearchField: NSViewRepresentable {
    let model: GIFPickerModel
    let theme: PickerTheme

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search GIFs")
        model.searchField = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != model.searchText { field.stringValue = model.searchText }
        field.textColor = NSColor(theme.text)
        field.placeholderAttributedString = NSAttributedString(string: "Search GIPHY", attributes: [
            .foregroundColor: NSColor(theme.tertiary),
            .font: NSFont.systemFont(ofSize: 17),
        ])
        (field.currentEditor() as? NSTextView)?.insertionPointColor = NSColor(theme.accent)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: GIFPickerModel

        init(model: GIFPickerModel) {
            self.model = model
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.searchTextDidChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            model.handleCommand(selector)
        }
    }
}

// MARK: - Grid

private struct GIFGrid: View {
    @ObservedObject var model: GIFPickerModel
    let loader: GIFImageLoader
    let theme: PickerTheme

    private let columns = Array(repeating: GridItem(.fixed(GIFMetrics.cellWidth), spacing: GIFMetrics.gridSpacing),
                                count: GIFMetrics.columns)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVGrid(columns: columns, spacing: GIFMetrics.gridSpacing) {
                    ForEach(model.results) { result in
                        GIFCell(result: result,
                                isSelected: model.selectedID == result.id,
                                isInserting: model.insertingID == result.id,
                                loader: loader,
                                theme: theme)
                            .id(result.id)
                            .onContinuousHover { phase in
                                if case .active = phase { model.hover(result.id) }
                            }
                            .onTapGesture { model.pick(result) }
                    }
                }
                .padding(GIFMetrics.gridInset)
            }
            .scrollIndicators(.never)
            .onChange(of: model.scrollRequest) { _, _ in
                guard let id = model.selectedID else { return }
                if model.selectedIndex == 0 {
                    proxy.scrollTo(id, anchor: .top)
                } else {
                    withAnimation(.pickerEase(0.18)) { proxy.scrollTo(id) }
                }
            }
        }
    }
}

private struct GIFCell: View {
    let result: GIFResult
    let isSelected: Bool
    let isInserting: Bool
    let loader: GIFImageLoader
    let theme: PickerTheme
    @State private var image: NSImage?
    @State private var failed = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: GIFMetrics.cellRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            shape.fill(theme.hover)
            if let image {
                AnimatedImageView(image: image)
                    .transition(.opacity)
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(theme.tertiary)
            }
            if isInserting {
                ZStack {
                    Color.black.opacity(0.35)
                    ProgressView().controlSize(.small)
                }
                .transition(.opacity)
            }
        }
        .frame(width: GIFMetrics.cellWidth, height: GIFMetrics.cellHeight)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(isSelected ? theme.accent : theme.hairline, lineWidth: isSelected ? 2.5 : 1)
        }
        .scaleEffect(isSelected ? 1.03 : 1)
        .shadow(color: isSelected ? theme.accent.opacity(0.35) : .clear, radius: 8)
        .zIndex(isSelected ? 1 : 0)
        .animation(.pickerEase(0.16), value: isSelected)
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .animation(.easeOut(duration: 0.15), value: isInserting)
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(result.displayTitle.isEmpty ? "GIF" : result.displayTitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .task(id: result.preview.url) {
            failed = false
            if let cached = loader.cachedImage(for: result.preview.url) {
                image = cached
                return
            }
            image = nil
            let loaded = await loader.image(for: result.preview.url)
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
    }
}

/// `NSImageView` with `animates = true`, scaled to fill its cell (cropping the overflow).
struct AnimatedImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> AspectFillImageView {
        AspectFillImageView()
    }

    func updateNSView(_ view: AspectFillImageView, context: Context) {
        view.image = image
    }
}

final class AspectFillImageView: NSView {
    private let imageView = NSImageView()

    var image: NSImage? {
        get { imageView.image }
        set {
            guard newValue !== imageView.image else { return }
            imageView.image = newValue
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        imageView.animates = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageFrameStyle = .none
        imageView.isEditable = false
        imageView.canDrawSubviewsIntoLayer = true
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        guard let size = imageView.image?.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            imageView.frame = bounds
            return
        }
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        imageView.frame = CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
                                 width: fitted.width, height: fitted.height)
    }

    // Clicks and hover belong to the SwiftUI cell.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Pulsing placeholders while the first results load.
private struct GIFSkeletonGrid: View {
    let theme: PickerTheme
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(GIFMetrics.cellWidth), spacing: GIFMetrics.gridSpacing),
                            count: GIFMetrics.columns)
        LazyVGrid(columns: columns, spacing: GIFMetrics.gridSpacing) {
            ForEach(0..<9, id: \.self) { index in
                RoundedRectangle(cornerRadius: GIFMetrics.cellRadius, style: .continuous)
                    .fill(theme.content.opacity(theme.isDark ? 0.06 : 0.05))
                    .frame(height: GIFMetrics.cellHeight)
                    .opacity(pulse ? 0.45 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever().delay(Double(index % 3) * 0.12),
                               value: pulse)
            }
        }
        .padding(GIFMetrics.gridInset)
        .onAppear { pulse = true }
        .accessibilityLabel("Loading GIFs")
    }
}

// MARK: - Messages

private struct GIFMessageView<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    let theme: PickerTheme
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 46, height: 46)
                .background(Circle().fill(theme.accent.opacity(theme.isDark ? 0.14 : 0.11)))
                .padding(.bottom, 14)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.bottom, 6)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(theme.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { actions }
                .padding(.top, 18)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 340)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension GIFMessageView where Actions == EmptyView {
    init(symbol: String, title: String, message: String, theme: PickerTheme) {
        self.init(symbol: symbol, title: title, message: message, theme: theme) { EmptyView() }
    }
}

private struct GIFProblemView: View {
    let problem: GIFProblem
    let model: GIFPickerModel
    let theme: PickerTheme

    var body: some View {
        switch problem {
        case .noKey:
            GIFMessageView(symbol: "key.fill",
                           title: "Add a GIPHY key to search GIFs",
                           message: "GIF search uses your own free GIPHY API key. Create an app on the GIPHY developer dashboard, copy its key, and paste it into Settings → GIFs.",
                           theme: theme) {
                GIFActionButton("Open GIF Settings", isPrimary: true, theme: theme) { model.onOpenSettings?() }
                GIFActionButton("Get a free key", symbol: "arrow.up.right", theme: theme) {
                    NSWorkspace.shared.open(GIPHYClient.dashboardURL)
                }
            }
        case .badKey:
            GIFMessageView(symbol: "lock.trianglebadge.exclamationmark",
                           title: "GIPHY didn’t accept your key",
                           message: "Check the key in Settings → GIFs. Keys are on the GIPHY developer dashboard.",
                           theme: theme) {
                GIFActionButton("Open GIF Settings", isPrimary: true, theme: theme) { model.onOpenSettings?() }
            }
        case .rateLimited:
            GIFMessageView(symbol: "hourglass",
                           title: "GIPHY’s hourly limit is reached",
                           message: "Free beta keys allow 100 requests an hour. Try again in a little while, or request a production key from GIPHY.",
                           theme: theme) {
                GIFActionButton("Try Again", isPrimary: true, theme: theme) { model.onRetry?() }
            }
        case .offline:
            GIFMessageView(symbol: "wifi.slash",
                           title: "You’re offline",
                           message: "GIF search needs an internet connection.",
                           theme: theme) {
                GIFActionButton("Try Again", isPrimary: true, theme: theme) { model.onRetry?() }
            }
        case .failed:
            GIFMessageView(symbol: "exclamationmark.triangle.fill",
                           title: "Couldn’t reach GIPHY",
                           message: "Something went wrong loading GIFs. Your text is untouched.",
                           theme: theme) {
                GIFActionButton("Try Again", isPrimary: true, theme: theme) { model.onRetry?() }
            }
        }
    }
}

private struct GIFActionButton: View {
    let title: String
    let symbol: String?
    let isPrimary: Bool
    let theme: PickerTheme
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String? = nil, isPrimary: Bool = false, theme: PickerTheme,
         action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.isPrimary = isPrimary
        self.theme = theme
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isPrimary ? Color.white : theme.text)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isPrimary ? theme.accent.opacity(hovering ? 1 : 0.9) : theme.content.opacity(hovering ? 0.14 : 0.09))
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Footer & chrome

private struct GIFFooter: View {
    @ObservedObject var model: GIFPickerModel
    let theme: PickerTheme

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let notice = model.notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ShellTheme.warning)
                } else if model.phase == .results, let result = model.selectedResult {
                    Text(result.displayTitle.isEmpty ? "Untitled GIF" : result.displayTitle)
                        .foregroundStyle(theme.secondary)
                } else if model.phase == .results, model.isTrending {
                    Text("Trending").foregroundStyle(theme.tertiary)
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .transaction { $0.animation = nil }
            Spacer(minLength: 8)
            if model.phase == .results {
                HStack(spacing: 6) {
                    Keycap("←↑↓→", theme: theme)
                    Text("move").foregroundStyle(theme.tertiary)
                    Keycap("↩", theme: theme).padding(.leading, 4)
                    Text("insert").foregroundStyle(theme.tertiary)
                }
                .font(.system(size: 10.5, weight: .medium))
                .fixedSize()
                Rectangle().fill(theme.divider).frame(width: 1, height: 16).padding(.horizontal, 2)
            }
            PoweredByGIPHY(theme: theme)
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.divider).frame(height: 1)
        }
    }
}

/// GIPHY's required attribution, shown wherever its results appear.
struct PoweredByGIPHY: View {
    let theme: PickerTheme

    var body: some View {
        HStack(spacing: 4) {
            Text("Powered by")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.tertiary)
            GIPHYMark()
                .frame(width: 10, height: 12.5)
            Text("GIPHY")
                .font(.system(size: 11.5, weight: .black))
                .tracking(0.3)
                .foregroundStyle(theme.text)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Powered by GIPHY")
    }
}

/// GIPHY's logo mark, drawn in code (the executable target has no image resources): a frame of
/// green, purple, blue and yellow bars with the pink folded corner, on a 16 × 20 grid.
struct GIPHYMark: View {
    private static let green = Color(red: 0.0, green: 1.0, blue: 0.6)
    private static let purple = Color(red: 0.6, green: 0.2, blue: 1.0)
    private static let blue = Color(red: 0.0, green: 0.8, blue: 1.0)
    private static let yellow = Color(red: 1.0, green: 0.953, blue: 0.361)
    private static let pink = Color(red: 1.0, green: 0.4, blue: 0.4)

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width / 16, size.height / 20)
            func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
                context.fill(Path(CGRect(x: x * unit, y: y * unit, width: w * unit, height: h * unit)), with: .color(color))
            }
            bar(0, 2, 2, 18, Self.green)      // left
            bar(14, 6, 2, 14, Self.purple)    // right
            bar(0, 18, 16, 2, Self.blue)      // bottom
            bar(0, 0, 10, 2, Self.yellow)     // top
            bar(10, 0, 2, 2, Self.pink)       // folded corner
            bar(12, 2, 2, 2, Self.pink)
            bar(14, 4, 2, 2, Self.pink)
            bar(10, 2, 2, 4, Self.purple.opacity(0.85))
            bar(12, 4, 2, 2, Self.purple.opacity(0.85))
        }
        .accessibilityHidden(true)
    }
}

/// Shows that Jev is reordering (spinner) or has reordered (sparkles) the results.
private struct GIFJevBadge: View {
    let isRefining: Bool
    let theme: PickerTheme

    var body: some View {
        HStack(spacing: 4) {
            if isRefining {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "sparkles").font(.system(size: 9, weight: .bold))
            }
            Text("Jev")
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(isRefining ? theme.tertiary : theme.accent)
        .help(isRefining ? "Jev is ranking these GIFs" : "Ranked by Jev")
    }
}
