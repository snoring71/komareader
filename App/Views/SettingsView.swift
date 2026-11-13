import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

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
