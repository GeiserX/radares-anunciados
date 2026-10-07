// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The drive's Live Activity (design 4.2): Lock Screen, Dynamic Island and, through the small activity family,
// the CarPlay Dashboard on iOS 26 (kind symbol, title, distance in large digits, limit badge, no buttons).
// Skeleton: a minimal rendering of ContentState; the surfaces lane does the sizes and the Night Mode tint.

import ActivityKit
import SwiftUI
import WidgetKit

struct DriveLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DriveAttributes.self) { context in
            DriveCard(state: context.state)
                .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    DriveCard(state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.state.kindSymbol)
            } compactTrailing: {
                Text(DriveCard.distanceText(context.state))
                    .monospacedDigit()
            } minimal: {
                Image(systemName: context.state.kindSymbol)
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

struct DriveCard: View {
    @Environment(\.activityFamily) private var family

    let state: DriveAttributes.ContentState

    static func distanceText(_ state: DriveAttributes.ContentState) -> String {
        guard let metres = state.distanceMetres else { return "" }
        return metres >= 1000
            ? String(format: "%.1f km", locale: .current, Double(metres) / 1000)
            : "\(metres) m"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.kindSymbol)
                .font(family == .small ? .title3 : .title)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(.headline)
                if !state.subtitle.isEmpty {
                    Text(state.subtitle).font(.footnote).lineLimit(1)
                }
                if state.opposite {
                    Text("sentido contrario").font(.caption2)
                }
            }
            Spacer()
            Text(Self.distanceText(state))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            if let limit = state.limit {
                Text("\(limit)")
                    .font(.caption.weight(.bold))
                    .padding(6)
                    .overlay(Circle().stroke(lineWidth: 2))
            }
        }
    }
}
