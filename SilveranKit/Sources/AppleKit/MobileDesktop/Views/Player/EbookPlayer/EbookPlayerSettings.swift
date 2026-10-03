#if os(iOS) || os(macOS)
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
/// The reader's Customize sheet: the handful of choices people change while reading.
/// Everything else lives one level down in More Options.
struct EbookPlayerSettings: View {
    @Bindable var settingsVM: SettingsViewModel
    /// The scheme the reader is showing (after the Light/Dark choice), so swatches preview
    /// the variant the person will actually see.
    let readerColorScheme: ColorScheme

    private var isDark: Bool { readerColorScheme == .dark }

    var body: some View {
        List {
            Section {
                textSizeRow
                NavigationLink {
                    ReaderFontPickerView(settingsVM: settingsVM)
                } label: {
                    LabeledContent("Font", value: ReaderFontOptions.label(for: settingsVM.fontFamily))
                }
            }

            Section("Appearance") {
                Picker("Appearance", selection: appearanceBinding) {
                    Text("System").tag(ReaderAppearanceMode.system)
                    Text("Light").tag(ReaderAppearanceMode.light)
                    Text("Dark").tag(ReaderAppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                themeSwatches
            }

            Section {
                Picker("Layout", selection: $settingsVM.scrollingMode) {
                    Text("Pages").tag(false)
                    Text("Scroll").tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: settingsVM.scrollingMode) { _, _ in settingsVM.save() }

                NavigationLink("More Options") {
                    ReaderMoreOptionsView(settingsVM: settingsVM)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.top, 4, for: .scrollContent)
    }

    // MARK: Text size

    private var textSizeRow: some View {
        let smaller = ReaderTypography.smaller(than: settingsVM.fontSize)
        let larger = ReaderTypography.larger(than: settingsVM.fontSize)
        let percent = ReaderTypography.percentOfDefault(settingsVM.fontSize)
        return HStack {
            Button {
                if let smaller { setFontSize(smaller) }
            } label: {
                Text("A")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 56, height: 32)
            }
            .disabled(smaller == nil)
            .accessibilityLabel("Smaller text")

            Spacer()
            Text("\(percent)%")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Spacer()

            Button {
                if let larger { setFontSize(larger) }
            } label: {
                Text("A")
                    .font(.system(size: 24, weight: .medium))
                    .frame(width: 56, height: 32)
            }
            .disabled(larger == nil)
            .accessibilityLabel("Larger text")
        }
        .buttonStyle(.bordered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Text size")
        .accessibilityValue("\(percent) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
                case .increment: if let larger { setFontSize(larger) }
                case .decrement: if let smaller { setFontSize(smaller) }
                @unknown default: break
            }
        }
    }

    private func setFontSize(_ size: Double) {
        settingsVM.fontSize = size
        settingsVM.save()
    }

    // MARK: Appearance and themes

    private var appearanceBinding: Binding<ReaderAppearanceMode> {
        Binding(
            get: { settingsVM.appearanceMode },
            set: { newValue in
                settingsVM.appearanceMode = newValue
                settingsVM.save()
            },
        )
    }

    private var customSwatchThemes: [ReaderTheme] {
        settingsVM.customThemes.filter { $0.availableFor(colorScheme: isDark ? "dark" : "light") }
    }

    private var themeSwatches: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(ReaderThemeFamily.builtIn) { family in
                    let id = family.themeId(isDark: isDark)
                    if let theme = settingsVM.resolveTheme(id: id) {
                        ThemeSwatch(
                            name: family.name,
                            theme: theme,
                            isSelected: settingsVM.activeThemeId(for: readerColorScheme) == id,
                        ) {
                            settingsVM.selectThemeFamily(family, for: readerColorScheme)
                        }
                    }
                }
                ForEach(customSwatchThemes) { theme in
                    ThemeSwatch(
                        name: theme.name,
                        theme: theme,
                        isSelected: settingsVM.activeThemeId(for: readerColorScheme) == theme.id,
                    ) {
                        settingsVM.selectCustomTheme(theme, for: readerColorScheme)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct ThemeSwatch: View {
    let name: String
    let theme: ReaderTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(hex: theme.backgroundColor) ?? .white)
                    .frame(width: 64, height: 52)
                    .overlay {
                        Text("Aa")
                            .font(.system(size: 20, weight: .semibold, design: .serif))
                            .foregroundStyle(Color(hex: theme.foregroundColor) ?? .black)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.secondary.opacity(0.35),
                                lineWidth: isSelected ? 3 : 1,
                            )
                    }
                Text(name)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(width: 68)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) theme")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Font

private struct ReaderFontPickerView: View {
    @Bindable var settingsVM: SettingsViewModel
    @State private var customFamilies: [CustomFontFamily] = []
    @State private var showFontManager = false

    var body: some View {
        List {
            Section {
                ForEach(ReaderFontOptions.generic + ReaderFontOptions.apple, id: \.value) { font in
                    fontRow(label: font.label, value: font.value)
                }
            }
            if !customFamilies.isEmpty || isUnlistedCustomFont {
                Section("Your Fonts") {
                    ForEach(customFamilies) { family in
                        fontRow(label: family.name, value: family.name)
                    }
                    if isUnlistedCustomFont {
                        fontRow(
                            label: settingsVM.fontFamily,
                            value: settingsVM.fontFamily,
                            note: "Not on this device. Showing System Default."
                        )
                    }
                }
            }
            Section {
                Button("Manage Your Fonts…") { showFontManager = true }
            }
        }
        .contentMargins(.top, 4, for: .scrollContent)
        .navigationTitle("Font")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showFontManager) {
            IOSFontManagerView(
                customFamilies: $customFamilies,
                selectedFont: $settingsVM.fontFamily,
                onSave: { settingsVM.save() },
            )
        }
        .task {
            await CustomFontsActor.shared.refreshFonts()
            customFamilies = await CustomFontsActor.shared.availableFamilies
        }
    }

    /// A custom font chosen on another device or since removed; keep it visible and selected.
    /// The reader shows System Default until the font is added here (owner decision, 2026-10-03).
    private var isUnlistedCustomFont: Bool {
        !ReaderFontOptions.isBuiltIn(settingsVM.fontFamily)
            && !customFamilies.contains { $0.name == settingsVM.fontFamily }
    }

    private func fontRow(label: String, value: String, note: String? = nil) -> some View {
        Button {
            settingsVM.fontFamily = value
            settingsVM.save()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(ReaderFontOptions.previewFont(for: note == nil ? value : kDefaultFontFamily))
                        .foregroundStyle(.primary)
                    if let note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if settingsVM.fontFamily == value {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .tint(.primary)
        .accessibilityAddTraits(settingsVM.fontFamily == value ? .isSelected : [])
    }
}

// MARK: - More Options

private struct ReaderMoreOptionsView: View {
    @Bindable var settingsVM: SettingsViewModel
    @State private var confirmReset = false

    var body: some View {
        List {
            Section("Text") {
                segmentedRow("Line Spacing") {
                    Picker("Line Spacing", selection: lineSpacingBinding) {
                        Text("Compact").tag(ReaderTypography.LineSpacing?.some(.compact))
                        Text("Normal").tag(ReaderTypography.LineSpacing?.some(.normal))
                        Text("Relaxed").tag(ReaderTypography.LineSpacing?.some(.relaxed))
                    }
                }
                segmentedRow("Margins") {
                    Picker("Margins", selection: marginsBinding) {
                        Text("Narrow").tag(ReaderTypography.Margins?.some(.narrow))
                        Text("Normal").tag(ReaderTypography.Margins?.some(.normal))
                        Text("Wide").tag(ReaderTypography.Margins?.some(.wide))
                    }
                }
                Toggle("Justify Text", isOn: justifyBinding)
            }

            Section {
                segmentedRow("Page Turn") {
                    Picker("Page Turn", selection: $settingsVM.pageTurnStyle) {
                        Text("None").tag("none")
                        Text("Slide").tag("slide")
                        Text("Curl").tag("curl")
                    }
                    .onChange(of: settingsVM.pageTurnStyle) { _, _ in settingsVM.save() }
                }
                Toggle("Single Column", isOn: singleColumnBinding)
            } header: {
                Text("Pages")
            } footer: {
                if settingsVM.scrollingMode {
                    Text("Page turns and columns apply when Layout is set to Pages.")
                }
            }
            .disabled(settingsVM.scrollingMode)

            Section {
                spacingSlider(
                    "Word Spacing",
                    value: $settingsVM.wordSpacing,
                    range: -0.5...2.0,
                    step: 0.1,
                    format: { String(format: "%.1f em", $0) },
                )
                spacingSlider(
                    "Letter Spacing",
                    value: $settingsVM.letterSpacing,
                    range: -0.1...0.5,
                    step: 0.01,
                    format: { String(format: "%.2f em", $0) },
                )
            } header: {
                Text("Accessibility")
            } footer: {
                Text("Extra space between words or letters can make text easier to follow.")
            }

            Section {
                NavigationLink("Manage Themes") {
                    ManageThemesView(settingsVM: settingsVM)
                }
            }

            Section {
                Button("Reset Text & Layout") { confirmReset = true }
            } footer: {
                Text("Restores size, font, spacing, margins and page settings. Themes are kept.")
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 4, for: .scrollContent)
        .navigationTitle("More Options")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Reset text and layout to the defaults?",
            isPresented: $confirmReset,
            titleVisibility: .visible,
        ) {
            Button("Reset", role: .destructive) { resetTextAndLayout() }
        }
    }

    private var lineSpacingBinding: Binding<ReaderTypography.LineSpacing?> {
        Binding(
            get: { ReaderTypography.LineSpacing.matching(settingsVM.lineSpacing) },
            set: { newValue in
                guard let newValue else { return }
                settingsVM.lineSpacing = newValue.value
                settingsVM.save()
            },
        )
    }

    private var marginsBinding: Binding<ReaderTypography.Margins?> {
        Binding(
            get: {
                ReaderTypography.Margins.matching(
                    leftRight: settingsVM.marginLeftRight,
                    topBottom: settingsVM.marginTopBottom,
                )
            },
            set: { newValue in
                guard let newValue else { return }
                settingsVM.marginLeftRight = newValue.leftRight
                settingsVM.marginTopBottom = newValue.topBottom
                settingsVM.save()
            },
        )
    }

    private var justifyBinding: Binding<Bool> {
        Binding(
            get: { settingsVM.textAlignment == "justify" },
            set: { newValue in
                settingsVM.textAlignment = newValue ? "justify" : "left"
                settingsVM.save()
            },
        )
    }

    private var singleColumnBinding: Binding<Bool> {
        Binding(
            get: { settingsVM.singleColumnMode || settingsVM.scrollingMode },
            set: { newValue in
                settingsVM.singleColumnMode = newValue
                settingsVM.save()
            },
        )
    }

    /// A label above a full-width segmented control, so rows line up at every width.
    private func segmentedRow(
        _ title: String,
        @ViewBuilder picker: () -> some View,
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            picker()
                .pickerStyle(.segmented)
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private func spacingSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String,
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: format(value.wrappedValue))
            Slider(value: value, in: range, step: step) {
                Text(title)
            }
            .accessibilityValue(format(value.wrappedValue))
            .onChange(of: value.wrappedValue) { _, _ in settingsVM.save() }
        }
    }

    /// Resets only what this menu shows. Display Options (overlay, mini player, page-turn
    /// taps) and the theme are separate choices and are left alone (BF-057).
    private func resetTextAndLayout() {
        settingsVM.fontSize = kDefaultFontSize
        settingsVM.fontFamily = kDefaultFontFamily
        settingsVM.lineSpacing = kDefaultLineSpacing
        settingsVM.marginLeftRight = kDefaultMarginLeftRightIOS
        settingsVM.marginTopBottom = kDefaultMarginTopBottom
        settingsVM.wordSpacing = kDefaultWordSpacing
        settingsVM.letterSpacing = kDefaultLetterSpacing
        settingsVM.textAlignment = kDefaultTextAlignment
        settingsVM.singleColumnMode = kDefaultSingleColumnMode
        settingsVM.scrollingMode = kDefaultScrollingMode
        settingsVM.pageTurnStyle = kDefaultPageTurnStyle
        settingsVM.save()
    }
}

private struct IOSFontManagerView: View {
    @Binding var customFamilies: [CustomFontFamily]
    @Binding var selectedFont: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showFontImporter = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showFontImporter = true
                    } label: {
                        Label("Import Font", systemImage: "plus.circle")
                    }
                    .fileImporter(
                        isPresented: $showFontImporter,
                        allowedContentTypes: [
                            UTType(filenameExtension: "ttf") ?? .data,
                            UTType(filenameExtension: "otf") ?? .data,
                            UTType.font,
                        ],
                        allowsMultipleSelection: true,
                    ) { result in
                        Task {
                            switch result {
                                case .success(let urls):
                                    for url in urls {
                                        try? await CustomFontsActor.shared.importFont(from: url)
                                    }
                                    await refreshFonts()
                                case .failure:
                                    break
                            }
                        }
                    }
                }

                Section("Custom Fonts") {
                    if customFamilies.isEmpty {
                        Text("No custom fonts imported")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(customFamilies) { family in
                            DisclosureGroup {
                                ForEach(family.variants) { variant in
                                    HStack {
                                        Text(variant.styleDescription)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            deleteVariant(variant, from: family)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(family.name)
                                        Text(
                                            "\(family.variants.count) variant\(family.variants.count == 1 ? "" : "s")"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedFont == family.name {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteFamily(family)
                                } label: {
                                    Label("Delete All", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Manage Fonts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await refreshFonts()
        }
    }

    private func refreshFonts() async {
        await CustomFontsActor.shared.refreshFonts()
        customFamilies = await CustomFontsActor.shared.availableFamilies
    }

    private func deleteFamily(_ family: CustomFontFamily) {
        Task {
            if selectedFont == family.name {
                selectedFont = "System Default"
                onSave()
            }
            try? await CustomFontsActor.shared.deleteFamily(family)
            await MainActor.run {
                customFamilies.removeAll { $0.id == family.id }
            }
        }
    }

    private func deleteVariant(_ variant: CustomFontVariant, from family: CustomFontFamily) {
        Task {
            try? await CustomFontsActor.shared.deleteVariant(variant)
            await MainActor.run {
                if let familyIndex = customFamilies.firstIndex(where: { $0.id == family.id }) {
                    customFamilies[familyIndex].variants.removeAll { $0.id == variant.id }
                    if customFamilies[familyIndex].variants.isEmpty {
                        if selectedFont == family.name {
                            selectedFont = "System Default"
                            onSave()
                        }
                        customFamilies.remove(at: familyIndex)
                    }
                }
            }
        }
    }
}

#endif

#endif
