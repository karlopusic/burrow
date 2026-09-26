import SwiftUI

enum Tab: Hashable { case overview, versions, settings }

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab: Tab = .overview

    var body: some View {
        TabView(selection: $tab) {
            OverviewView(openSettings: { tab = .settings })
                .tabItem { Label("Overview", systemImage: "gauge.with.dots.needle.33percent") }.tag(Tab.overview)
            VersionsView()
                .tabItem { Label("Versions", systemImage: "clock.arrow.circlepath") }.tag(Tab.versions)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(Tab.settings)
        }
        .padding(12)
        .onAppear { if model.needsSetup { tab = .settings } }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if model.toast == t { model.toast = nil } }
                    }
            }
        }
    }
}

struct Banner: View {
    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    var actions: AnyView? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).bold()
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let actions { actions }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
