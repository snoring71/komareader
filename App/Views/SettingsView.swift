import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.coverShape) private var coverShape: CoverShape = .comic
    @AppStorage(SettingsKeys.coverShadow) private var coverShadow: Double = CoverStyle.defaultShadowStrength
    @AppStorage(SettingsKeys.coverShadowDirection) private var shadowDirection: CoverShadowDirection = .around
    @AppStorage(SettingsKeys.roundedCorners) private var roundedCorners = true
    @AppStorage(CoverIntro.settingKey) private var showCoverIntro = true

    var body: some View {
        @Bindable var policy = model.coverPolicy
        NavigationStack {
            Form {
                Section {
                    Toggle("Make Covers for Books in iCloud", isOn: $policy.makeCoversForCloudBooks)
                        .accessibilityIdentifier("settings-cloud-covers")
                    Toggle("Use Wi-Fi Only", isOn: $policy.wifiOnly)
                        .disabled(!policy.makeCoversForCloudBooks)
                    LabeledContent("Status") {
                        Text(policy.pauseReason ?? "Running")
                            .foregroundStyle(policy.pauseReason == nil ? Color.secondary : Color.orange)
                    }
                } header: {
                    Text("Covers")
                } footer: {
                    Text("To make a cover for a book that is only in iCloud, Comic Reader downloads it once, saves the cover to iCloud Drive for your other devices, and removes the download again. It fetches one book at a time and pauses in Low Data Mode, in Low Power Mode and when the battery is low.")
                }

                Section {
                    Picker("Cover Shape", selection: $coverShape) {
                        ForEach(CoverShape.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("settings-cover-shape")
                    Toggle("Rounded Corners", isOn: $roundedCorners)
                        .accessibilityIdentifier("settings-rounded-corners")
                    LabeledContent("Cover Shadow") {
                        HStack(spacing: 12) {
                            Slider(value: $coverShadow, in: 0...1, step: 0.05)
                                .frame(maxWidth: 260)
                                .accessibilityIdentifier("settings-cover-shadow")
                            Text(coverShadow < 0.001 ? "Off" : "\(Int((coverShadow * 100).rounded()))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    Picker("Shadow Direction", selection: $shadowDirection) {
                        ForEach(CoverShadowDirection.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(coverShadow < 0.001)
                    .accessibilityIdentifier("settings-shadow-direction")
                } header: {
                    Text("Library Appearance")
                } footer: {
                    Text("Covers are trimmed to this shape in the library. Manga B6 is a little wider than Comic 2:3 and fits most manga and digital comics better.")
                }

                Section {
                    NavigationLink("Book Defaults") { ReaderDefaultsView() }
                        .accessibilityIdentifier("settings-book-defaults")
                    // For every book alike, so here rather than among the Book Defaults (#93).
                    Toggle("Show Cover First", isOn: $showCoverIntro)
                        .accessibilityIdentifier("settings-show-cover-first")
                } header: {
                    Text("Reading")
                } footer: {
                    Text("Book Defaults are how books open until you change a setting while reading one. Show Cover First shows the cover when a book opens: for a moment if you've read it before, or until you turn to the first page.")
                }

                Section("Library") {
                    LabeledContent("Folder", value: model.libraryName)
                    LabeledContent("Books", value: "\(model.books.filter { !$0.isMissing }.count)")
                    Button("Change Library Folder…") {
                        dismiss()
                        model.changeFolder()
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
