// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tabs: Estado (first), map, settings. Requests the Live Activity on appear while driving (design 4.2).

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            NavigationStack { HealthView() }
                .tabItem { Label("Estado", systemImage: "checklist") }
                .tag(AppModel.Tab.estado)
            NavigationStack { MapView() }
                .tabItem { Label("Mapa", systemImage: "map") }
                .tag(AppModel.Tab.mapa)
            NavigationStack { SettingsView() }
                .tabItem { Label("Ajustes", systemImage: "gearshape") }
                .tag(AppModel.Tab.ajustes)
        }
        .fullScreenCover(isPresented: $model.showOnboarding) {
            OnboardingFlow()
        }
        .onAppear {
            Task { await model.ensureActivityIfDriving() }
        }
    }
}
