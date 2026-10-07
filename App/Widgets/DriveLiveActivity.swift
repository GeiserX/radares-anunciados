// Lane: surfaces
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The drive's Live Activity (design 4.2): Lock Screen, Dynamic Island and, through the small activity family,
// the CarPlay Dashboard on iOS 26. The small family shows the kind symbol, the title, the distance in large digits
// and the limit badge, no buttons (Live Activities in CarPlay are non-interactive). Shapes and weights carry the
// meaning, not colour alone, so the card stays legible under CarPlay's Night Mode red tint.

import ActivityKit
import SwiftUI
import WidgetKit

struct DriveLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DriveAttributes.self) { context in
            DriveActivityView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.8))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let card = CardModel(state: context.state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    KindBadge(model: card, size: 44)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let limit = card.limit {
                        LimitBadge(limit: limit, size: 44)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(card.headline)
                            .font(.headline)
                            .lineLimit(1)
                        Text(card.figure)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DetailLine(model: card)
                        .font(.footnote)
                }
            } compactLeading: {
                Image(systemName: card.symbol)
                    .foregroundStyle(card.tint)
            } compactTrailing: {
                Text(card.compactFigure)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(card.tint)
            } minimal: {
                Image(systemName: card.symbol)
                    .foregroundStyle(card.tint)
            }
            .keylineTint(card.tint)
        }
        .supplementalActivityFamilies([.small])
    }
}

/// The Lock Screen card, and the small family on CarPlay (and the Apple Watch Smart Stack).
struct DriveActivityView: View {
    @Environment(\.activityFamily) private var family

    let state: DriveAttributes.ContentState
    let isStale: Bool

    var body: some View {
        switch family {
        case .small:
            SmallDriveCard(state: state, isStale: isStale)
        case .medium:
            LockScreenCard(state: state, isStale: isStale)
        @unknown default:
            LockScreenCard(state: state, isStale: isStale)
        }
    }
}

struct LockScreenCard: View {
    let state: DriveAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let card = CardModel(state: state, isStale: isStale)
        HStack(spacing: 12) {
            KindBadge(model: card, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.headline)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                DetailLine(model: card)
                    .font(.footnote)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                Text(card.figure)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if let caption = card.figureCaption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let limit = card.limit {
                LimitBadge(limit: limit, size: 44)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
    }
}

/// CarPlay Dashboard (240×78, 240×100 or 170×78 pt): symbol, title, distance in large digits, limit badge.
/// The title runs across the top so the digits and the badge share the full width of the narrowest size.
/// With nothing ahead it shows no figure (the car has its own speedometer), only the note when there is one.
struct SmallDriveCard: View {
    let state: DriveAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let card = CardModel(state: state, isStale: isStale)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: card.symbol)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(card.tint)
                Text(card.smallHeadline)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            HStack(spacing: 6) {
                if card.smallFigure.isEmpty, let note = card.note {
                    Text(note)
                        .font(.headline)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                } else {
                    Text(card.smallFigure)
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                Spacer(minLength: 0)
                if let limit = card.limit {
                    LimitBadge(limit: limit, size: 36)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// The kind symbol in a ring; the ring's colour follows the phase, the symbol carries the kind.
struct KindBadge: View {
    let model: CardModel
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(model.tint.opacity(0.25))
            Circle().strokeBorder(model.tint, lineWidth: 3)
            Image(systemName: model.symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// A speed-limit sign: white disc, red ring, black number.
struct LimitBadge: View {
    let limit: Int
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(.white)
            Circle().strokeBorder(Color.red, lineWidth: size * 0.12)
            Text("\(limit)")
                .font(.system(size: size * 0.4, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.black)
                .minimumScaleFactor(0.5)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text("Límite \(limit)"))
    }
}

/// Second line: the road and km, the average in a section; then "sentido contrario" and the note on their own
/// lines, so neither is cut off by a long road name.
struct DetailLine: View {
    let model: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            let parts = model.details
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.85))
            }
            if model.state.opposite {
                Text("sentido contrario")
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if let note = model.note {
                Text(note)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// What every presentation shows, derived once from the content state.
struct CardModel {
    let state: DriveAttributes.ContentState
    let isStale: Bool

    var symbol: String {
        switch state.phase {
        case .passed: "checkmark.circle.fill"
        case .paused: "pause.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        default: state.kindSymbol
        }
    }

    var tint: Color {
        if isStale { return .gray }
        switch state.phase {
        case .alert: return state.opposite ? .gray : .red
        case .approaching, .insideStretch: return state.opposite ? .gray : .orange
        case .passed: return .green
        case .degraded: return .yellow
        case .watching, .paused: return .gray
        }
    }

    var headline: String {
        switch state.phase {
        case .passed: String(localized: "Radar superado")
        default: state.title
        }
    }

    /// The large figure: the distance at milestones, the stretch remainder, or the speed when nothing is ahead.
    var figure: String {
        if state.phase == .insideStretch, let remaining = state.stretchRemainingMetres {
            return Self.distance(remaining)
        }
        if state.phase != .passed, let metres = state.distanceMetres {
            return Self.distance(metres)
        }
        if let speed = state.speedKmh, state.phase == .watching {
            return "\(speed) km/h"
        }
        return ""
    }

    /// The small family's title line: the title, and "sentido contrario" for an opposite-flow radar.
    var smallHeadline: String {
        state.opposite ? "\(headline) · \(String(localized: "sentido contrario"))" : headline
    }

    /// The small family's figure: as `figure`, without the speed.
    var smallFigure: String {
        state.phase == .watching ? "" : figure
    }

    var figureCaption: String? {
        if state.phase == .insideStretch, state.stretchRemainingMetres != nil {
            return String(localized: "restantes aprox.")
        }
        return nil
    }

    var compactFigure: String {
        if state.phase == .insideStretch, let remaining = state.stretchRemainingMetres {
            return Self.distance(remaining)
        }
        if state.phase != .passed, let metres = state.distanceMetres {
            return Self.distance(metres)
        }
        return ""
    }

    var limit: Int? {
        state.phase == .passed ? nil : state.limit
    }

    var details: [String] {
        var parts: [String] = []
        if !state.subtitle.isEmpty { parts.append(state.subtitle) }
        if state.phase == .insideStretch, let avg = state.avgKmh {
            parts.append(String(localized: "media \(avg) km/h"))
        }
        if state.phase == .paused { parts.append(String(localized: "En pausa")) }
        return parts
    }

    var note: String? {
        isStale ? String(localized: "Sin datos recientes") : state.note
    }

    /// "750 m", "1,0 km": metres below 1 km, one decimal in the phone's locale above.
    static func distance(_ metres: Int) -> String {
        if metres >= 1000 {
            let km = (Double(metres) / 1000).formatted(.number.precision(.fractionLength(1)))
            return "\(km) km"
        }
        return "\(metres) m"
    }
}

// MARK: Previews

#if DEBUG
extension DriveAttributes {
    static var preview: DriveAttributes { DriveAttributes(startedAt: .now) }
}

extension DriveAttributes.ContentState {
    static let previewApproaching = Self(
        phase: .approaching, kindSymbol: "camera.fill", title: "Radar fijo", subtitle: "A-2 km 202,3",
        distanceMetres: 1000, speedKmh: 120, updatedAt: .now
    )
    static let previewAlert = Self(
        phase: .alert, kindSymbol: "camera.fill", title: "Radar fijo", subtitle: "A-2 km 202,3",
        distanceMetres: 750, limit: 90, speedKmh: 118, updatedAt: .now
    )
    static let previewOpposite = Self(
        phase: .alert, kindSymbol: "camera.fill", title: "Radar fijo", subtitle: "N-II km 12",
        distanceMetres: 500, limit: 80, speedKmh: 76, opposite: true, updatedAt: .now
    )
    static let previewStretch = Self(
        phase: .insideStretch, kindSymbol: "road.lanes", title: "Tramo radar móvil", subtitle: "N-232",
        speedKmh: 90, stretchRemainingMetres: 8500, avgKmh: 87, updatedAt: .now
    )
    static let previewMobile = Self(
        phase: .alert, kindSymbol: "car.side.fill", title: "Radar móvil anunciado", subtitle: "Avenida de Europa",
        distanceMetres: 250, limit: 50, speedKmh: 50, updatedAt: .now
    )
    static let previewPassed = Self(
        phase: .passed, kindSymbol: "camera.fill", title: "Radar fijo", subtitle: "A-2 km 202,3", updatedAt: .now
    )
    static let previewWatching = Self(
        phase: .watching, kindSymbol: "car.fill", title: "Sin radares cerca", subtitle: "", speedKmh: 96,
        note: "Datos de hace 3 días", updatedAt: .now
    )
    static let previewDegraded = Self(
        phase: .degraded, kindSymbol: "car.fill", title: "Sin radares cerca", subtitle: "", note: "Abre la app",
        updatedAt: .now
    )
}

#Preview("Pantalla bloqueada", as: .content, using: DriveAttributes.preview) {
    DriveLiveActivity()
} contentStates: {
    DriveAttributes.ContentState.previewAlert
    DriveAttributes.ContentState.previewApproaching
    DriveAttributes.ContentState.previewOpposite
    DriveAttributes.ContentState.previewStretch
    DriveAttributes.ContentState.previewMobile
    DriveAttributes.ContentState.previewPassed
    DriveAttributes.ContentState.previewWatching
    DriveAttributes.ContentState.previewDegraded
}

#Preview("Isla compacta", as: .dynamicIsland(.compact), using: DriveAttributes.preview) {
    DriveLiveActivity()
} contentStates: {
    DriveAttributes.ContentState.previewAlert
    DriveAttributes.ContentState.previewStretch
    DriveAttributes.ContentState.previewWatching
}

#Preview("Isla expandida", as: .dynamicIsland(.expanded), using: DriveAttributes.preview) {
    DriveLiveActivity()
} contentStates: {
    DriveAttributes.ContentState.previewAlert
    DriveAttributes.ContentState.previewStretch
    DriveAttributes.ContentState.previewOpposite
}

#Preview("Isla mínima", as: .dynamicIsland(.minimal), using: DriveAttributes.preview) {
    DriveLiveActivity()
} contentStates: {
    DriveAttributes.ContentState.previewAlert
    DriveAttributes.ContentState.previewPassed
}

/// The three CarPlay sizes of the HIG, on black as the Dashboard draws them.
private struct CarPlaySizes: View {
    static let sizes = [CGSize(width: 240, height: 78), CGSize(width: 240, height: 100), CGSize(width: 170, height: 78)]

    let state: DriveAttributes.ContentState

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(Self.sizes.enumerated()), id: \.offset) { _, size in
                SmallDriveCard(state: state, isStale: false)
                    .frame(width: size.width, height: size.height)
                    .background(Color.black, in: .rect(cornerRadius: 12))
            }
        }
        .padding()
        .background(Color(white: 0.15))
    }
}

#Preview("CarPlay, pequeña") {
    CarPlaySizes(state: .previewAlert)
}

#Preview("CarPlay, tramo") {
    CarPlaySizes(state: .previewStretch)
}

#Preview("CarPlay, modo noche") {
    CarPlaySizes(state: .previewMobile)
        .colorMultiply(Color(red: 1, green: 0.25, blue: 0.2))
}
#endif
