import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var store: ConfigStore
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var reloadToken = 0
    @State private var backToken = 0
    @State private var showControls = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            InstagramWebView(
                store: store,
                isLoading: $isLoading,
                errorMessage: $errorMessage,
                reloadToken: reloadToken,
                backToken: backToken
            )

            if isLoading && errorMessage == nil {
                ProgressView("Loading Instagram…")
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.12))
            }

            if let errorMessage {
                errorCard(errorMessage)
            }

            VStack {
                Spacer()
                VStack(spacing: 10) {
                    Button {
                        backToken += 1
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.footnote.weight(.semibold))
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")

                    Button {
                        showControls = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.footnote.weight(.semibold))
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Insta settings")
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 8)
        }
        .sheet(isPresented: $showControls) {
            ControlsSheet(store: store) {
                errorMessage = nil
                isLoading = true
                reloadToken += 1
            }
        }
        .onChange(of: store.rulesEnabled) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: AppConstants.rulesEnabledDefaultsKey)
        }
        .task {
            store.refreshFromRemote()
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
            Text("Couldn't open Instagram")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Retry") {
                errorMessage = nil
                isLoading = true
                reloadToken += 1
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

private struct ControlsSheet: View {
    @ObservedObject var store: ConfigStore
    var reloadPage: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Restrictions", isOn: $store.rulesEnabled)
                } footer: {
                    Text("Turn this off to see Instagram's normal UI while you inspect it. Native redirects, feed hiding, and the reel lock pause until you turn it back on.")
                }
                Section("Rules") {
                    LabeledContent("Version", value: store.config.configVersion)
                    LabeledContent("Source", value: store.sourceDescription)
                    Text(store.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Reload rules") {
                        store.refreshFromRemote()
                    }
                }
                Section {
                    Button("Reload page") {
                        reloadPage()
                        dismiss()
                    }
                } footer: {
                    Text("DM uploads work only when Instagram's website offers them. This app does not add its own uploader.")
                }
            }
            .navigationTitle("Insta")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
