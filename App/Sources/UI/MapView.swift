// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The in-app map (design 4.4): radars within Thresholds.mapRadiusM of the map centre (points by kind, lines for
// stretches, unconfirmed reports in grey), the user's position, the Estado strip above, the nearest radar below.

import CoreLocation
import MapKit
import RadaresCore
import SwiftUI

struct MapView: View {
    @Environment(AppModel.self) private var model
    @State private var position: MapCameraPosition = Self.around(AppModel.lastKnown ?? Self.madrid)
    @State private var center = AppModel.lastKnown ?? Self.madrid
    @State private var me = AppModel.lastKnown

    var body: some View {
        VStack(spacing: 0) {
            EstadoStrip()
            Map(position: $position) {
                UserAnnotation()
                ForEach(nearby) { item in
                    let radar = item.radar
                    if let line = item.line {
                        MapPolyline(coordinates: line.map(\.cl))
                            .stroke(radar.kind.color, lineWidth: 4)
                    }
                    Marker(
                        radar.kind == .reported ? String(localized: "Sin confirmar") : radar.name,
                        systemImage: radar.kind.symbol,
                        coordinate: radar.start.cl
                    )
                        .tint(radar.kind.color)
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                center = Coordinate(context.region.center)
                me = AppModel.lastKnown
            }
            .safeAreaInset(edge: .bottom) {
                if let nearest {
                    NearestCard(radar: nearest.radar, metres: nearest.metres)
                        .padding()
                }
            }
        }
        .task {
            // While driving the card follows the engine; the snapshot is a cheap actor read.
            while !Task.isCancelled {
                await model.refreshDriveSnapshot()
                me = AppModel.lastKnown
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .navigationTitle("Mapa")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private static let madrid = Coordinate(latitude: 40.4168, longitude: -3.7038)

    /// The map opens on the radius the radars are shown for, not on street level.
    private static func around(_ point: Coordinate) -> MapCameraPosition {
        .region(MKCoordinateRegion(
            center: point.cl,
            latitudinalMeters: Thresholds.mapRadiusM * 2,
            longitudinalMeters: Thresholds.mapRadiusM * 2
        ))
    }

    /// What the map draws around its centre (`MapRules.nearby`).
    private var nearby: [MapRules.Item] {
        guard let store = model.store else { return [] }
        return MapRules.nearby(store: store, centre: center, on: Date())
    }

    /// Driving: the engine's next radar and its distance (design 4.4). Otherwise the nearest radar to the user that
    /// can warn today, within the map radius.
    private var nearest: (radar: Radar, metres: Double)? {
        if let snapshot = model.driveSnapshot, let next = snapshot.next, let metres = snapshot.distanceMetres {
            return (next, metres)
        }
        guard let me, let store = model.store else { return nil }
        return store.candidates(near: me, within: Thresholds.mapRadiusM, on: Date())
            .map { radar in (radar, [radar.start, radar.end].compactMap { $0 }.map { Geo.distance(me, $0) }.min() ?? .infinity) }
            .min { $0.1 < $1.1 }
            .map { (radar: $0.0, metres: $0.1) }
    }
}

/// The map's pure rules, testable without SwiftUI (design 4.4).
enum MapRules {
    /// One radar to draw, and for a stretch the coordinates of its line (the road when there is one, else the chord).
    struct Item: Identifiable, Equatable {
        let radar: Radar
        let line: [Coordinate]?
        var id: String { radar.id }
    }

    /// Drawn at all: a radar that can warn on `day`, or an unconfirmed report (grey). An announced mobile radar whose
    /// days are over, or an inactive one, would only be a stale marker.
    static func isShown(_ radar: Radar, on day: Date) -> Bool {
        radar.isAlertable(on: day) || radar.kind == .reported
    }

    /// Radars inside a box of `radius` around `centre` (a box, not a circle: cheaper, and the screen is a box). A point
    /// is kept when it is inside the box. A line is kept when an end is inside, or when its line passes within the box's
    /// half-diagonal of the centre: a corridor is often longer than the box, and a car in its middle must see it.
    /// `roadLine(id)` gives the road under a stretch when one is known; the map then draws it instead of the chord.
    static func nearby(
        store: RadarStore,
        centre: Coordinate,
        radius: Double = Thresholds.mapRadiusM,
        on day: Date,
        roadLine: (String) -> [Coordinate]? = { _ in nil }
    ) -> [Item] {
        let dLat = radius / 111_320
        let dLon = dLat / max(cos(centre.latitude * .pi / 180), 0.01)
        let halfDiagonal = radius * 2.0.squareRoot()
        func inBox(_ point: Coordinate) -> Bool {
            abs(point.latitude - centre.latitude) <= dLat && abs(point.longitude - centre.longitude) <= dLon
        }
        // The half-diagonal reach in degrees, for a cheap bounding-box test before any distance is computed.
        let reachLat = dLat * 2.0.squareRoot(), reachLon = dLon * 2.0.squareRoot()
        func mayReach(_ points: [Coordinate]) -> Bool {
            guard let first = points.first else { return false }
            var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
            for p in points.dropFirst() {
                minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
                minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
            }
            return maxLat >= centre.latitude - reachLat && minLat <= centre.latitude + reachLat
                && maxLon >= centre.longitude - reachLon && minLon <= centre.longitude + reachLon
        }
        func crosses(_ line: [Coordinate]) -> Bool {
            guard mayReach(line) else { return false }
            return zip(line, line.dropFirst()).contains { a, b in
                Geo.distanceToChord(point: centre, from: a, to: b) <= halfDiagonal
            }
        }
        return store.all.compactMap { radar in
            guard isShown(radar, on: day) else { return nil }
            guard let end = radar.end else {
                return inBox(radar.start) ? Item(radar: radar, line: nil) : nil
            }
            let road = roadLine(radar.id).flatMap { $0.count >= 2 ? $0 : nil }
            let line = road ?? [radar.start, end]
            guard inBox(radar.start) || inBox(end) || crosses([radar.start, end]) || (road.map(crosses) ?? false) else {
                return nil
            }
            return Item(radar: radar, line: line)
        }
    }
}

/// The worst Estado row, one line above the map; tapping it opens Estado.
struct EstadoStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.selectedTab = .estado
        } label: {
            HStack {
                Image(systemName: model.overall.symbol)
                switch model.overall {
                case .ok: Text("Todo listo para avisar")
                case .warn: Text("Avisa, con puntos por revisar")
                case .fail: Text("Hay un problema: toca para verlo")
                }
                Spacer()
                Image(systemName: "chevron.right")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(model.overall.color)
        }
    }
}

struct NearestCard: View {
    let radar: Radar
    let metres: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: radar.kind.symbol)
                .font(.title2)
                .foregroundStyle(radar.kind.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(radar.kind.label).font(.headline)
                Text(radar.road ?? radar.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Measurement(value: metres, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                if let limit = radar.maxspeed {
                    Text("Límite \(limit)").font(.caption)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
