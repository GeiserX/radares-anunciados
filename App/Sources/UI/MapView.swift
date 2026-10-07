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
    @State private var position: MapCameraPosition = Self.around(Self.lastKnown ?? Self.madrid)
    @State private var center = Self.lastKnown ?? Self.madrid
    @State private var me = Self.lastKnown

    var body: some View {
        VStack(spacing: 0) {
            EstadoStrip()
            Map(position: $position) {
                UserAnnotation()
                ForEach(nearby) { radar in
                    if let end = radar.end {
                        MapPolyline(coordinates: [radar.start.cl, end.cl])
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
                me = CLLocationManager().location.map { Coordinate($0.coordinate) }
            }
            .safeAreaInset(edge: .bottom) {
                if let nearest {
                    NearestCard(radar: nearest.radar, metres: nearest.metres)
                        .padding()
                }
            }
        }
        .navigationTitle("Mapa")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private static let madrid = Coordinate(latitude: 40.4168, longitude: -3.7038)

    private static var lastKnown: Coordinate? {
        CLLocationManager().location.map { Coordinate($0.coordinate) }
    }

    /// The map opens on the radius the radars are shown for, not on street level.
    private static func around(_ point: Coordinate) -> MapCameraPosition {
        .region(MKCoordinateRegion(
            center: point.cl,
            latitudinalMeters: Thresholds.mapRadiusM * 2,
            longitudinalMeters: Thresholds.mapRadiusM * 2
        ))
    }

    /// Radars inside a box of Thresholds.mapRadiusM around the map centre. A box, not a circle: cheaper, and the
    /// screen is a box anyway.
    private var nearby: [Radar] {
        guard let store = model.store else { return [] }
        let dLat = Thresholds.mapRadiusM / 111_320
        let dLon = dLat / max(cos(center.latitude * .pi / 180), 0.01)
        return store.all.filter { radar in
            [radar.start, radar.end].compactMap { $0 }.contains { point in
                abs(point.latitude - center.latitude) <= dLat && abs(point.longitude - center.longitude) <= dLon
            }
        }
    }

    /// The nearest radar to the user that can warn today, within the map radius.
    private var nearest: (radar: Radar, metres: Double)? {
        guard let me, let store = model.store else { return nil }
        return store.candidates(near: me, within: Thresholds.mapRadiusM, on: Date())
            .map { radar in (radar, [radar.start, radar.end].compactMap { $0 }.map { Geo.distance(me, $0) }.min() ?? .infinity) }
            .min { $0.1 < $1.1 }
            .map { (radar: $0.0, metres: $0.1) }
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
