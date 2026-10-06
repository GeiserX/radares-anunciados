// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tabs: Estado (first), map, settings. Requests the Live Activity on appear while driving (design 4.2).

import SwiftUI

struct RootView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Radares Anunciados").font(.title2)
            Text("lane: app").foregroundStyle(.secondary)
        }
    }
}
