// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The sentences of design 2.7, es-ES and en, distance rounded to Thresholds.spokenDistanceStepM.
// Numbers are digits ("10 kilómetros"): the synthesizer reads them in the voice's language, and a vector
// expectation stays the same string on both platforms.

import Foundation

public enum Phrasing {
    public static func make(_ event: AlertEvent, locale: Locale) -> Phrase {
        make(event, locale: locale, alsoAt: nil)
    }

    /// `alsoAt` is the distance of a second radar firing on the same fix: one sentence for both (design 2.6).
    public static func make(_ event: AlertEvent, locale: Locale, alsoAt second: Double?) -> Phrase {
        let en = isEnglish(locale)
        guard let radar = event.radar else {
            return Phrase(spoken: "", title: "", body: "")
        }
        let title = kindTitle(radar, locale: locale)
        let distance = roundedDistance(event.distance ?? 0)
        let direction = radar.directionText.map { directionName($0, locale: locale) }
        let limit = radar.maxspeed

        switch event.kind {
        case .warn:
            var spoken = en ? "\(title) \(distance) metres ahead" : "\(title) a \(distance) metros"
            if let second {
                spoken += en ? ", and another at \(roundedDistance(second))" : ", y otro a \(roundedDistance(second))"
            }
            if let direction { spoken += en ? ", towards \(direction)" : ", sentido \(direction)" }
            spoken += "."
            if let limit { spoken += en ? " Limit \(limit)." : " Límite \(limit)." }
            return Phrase(spoken: spoken, title: "\(title) \(en ? "in" : "a") \(distance) m", body: body(radar, locale: locale))

        case .stretchEntered:
            let length = lengthText(radar.lengthMetres ?? 0, locale: locale)
            var spoken: String
            if radar.role == .mobileCorridor {
                let road = radar.road.map { "\($0), " } ?? ""
                spoken = en ? "Mobile radar stretch, \(road)\(length)." : "Tramo de radar móvil, \(road)\(length)."
            } else {
                spoken = en ? "\(title) \(distance) metres ahead, \(length)" : "\(title) a \(distance) metros, \(length)"
                if let direction { spoken += en ? ", towards \(direction)" : ", sentido \(direction)" }
                spoken += "."
                if let limit { spoken += en ? " Limit \(limit)." : " Límite \(limit)." }
            }
            return Phrase(spoken: spoken, title: "\(title) · \(length)", body: body(radar, locale: locale))

        case .stretchExited:
            return Phrase(spoken: en ? "End of section." : "Fin de tramo.", title: en ? "End of section" : "Fin de tramo", body: subtitle(radar, locale: locale))

        case .passed, .driveEnded:
            return Phrase(spoken: "", title: en ? "Radar passed" : "Radar superado", body: subtitle(radar, locale: locale))
        }
    }

    public static func isEnglish(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "en"
    }

    /// Distance rounded to the spoken step, never under one step.
    public static func roundedDistance(_ metres: Double) -> Int {
        let step = Thresholds.spokenDistanceStepM
        return max(Int(step), Int((metres / step).rounded()) * Int(step))
    }

    /// "Radar fijo", "Tramo de radar móvil"...; the card title and the first words of every sentence.
    public static func kindTitle(_ radar: Radar, locale: Locale) -> String {
        let en = isEnglish(locale)
        switch radar.kind {
        case .fixed: return en ? "Fixed speed camera" : "Radar fijo"
        case .section: return en ? "Average speed camera" : "Radar de tramo"
        case .stretch: return radar.role == .mobileCorridor ? (en ? "Mobile radar stretch" : "Tramo de radar móvil") : (en ? "Average speed section" : "Radar de tramo")
        case .mobileAnnounced: return en ? "Announced mobile speed camera" : "Radar móvil anunciado"
        case .mobileRecurring: return en ? "Usual mobile radar" : "Radar móvil habitual"
        case .trailer: return en ? "Trailer speed camera" : "Radar en remolque"
        case .reported: return en ? "Unconfirmed report" : "Radar sin confirmar"
        }
    }

    /// Road and km when the feed has them ("A-2 km 202,3"), else the name.
    public static func subtitle(_ radar: Radar, locale: Locale) -> String {
        if let road = radar.road, let km = radar.kmFrom {
            return "\(road) km \(formatKm(km, locale: locale))"
        }
        if let road = radar.road { return road }
        return radar.name
    }

    /// The notification body: subtitle plus the limit or the direction.
    public static func body(_ radar: Radar, locale: Locale) -> String {
        let en = isEnglish(locale)
        var parts = [subtitle(radar, locale: locale)]
        if let limit = radar.maxspeed { parts.append(en ? "limit \(limit) km/h" : "límite \(limit) km/h") }
        if let direction = radar.directionText { parts.append(en ? "towards \(directionName(direction, locale: locale))" : "sentido \(directionName(direction, locale: locale))") }
        return parts.joined(separator: " · ")
    }

    /// "ZARAGOZA" -> "Zaragoza", "DONOSTIA / SAN SEBASTIÁN" -> "Donostia / San Sebastián".
    public static func directionName(_ raw: String, locale: Locale) -> String {
        raw.lowercased(with: locale).capitalized(with: locale)
    }

    /// "10 kilómetros", "1 kilómetro", "800 metros".
    public static func lengthText(_ metres: Double, locale: Locale) -> String {
        let en = isEnglish(locale)
        if metres >= 950 {
            let km = max(1, Int((metres / 1000).rounded()))
            if km == 1 { return en ? "1 kilometre" : "1 kilómetro" }
            return en ? "\(km) kilometres" : "\(km) kilómetros"
        }
        return en ? "\(roundedDistance(metres)) metres" : "\(roundedDistance(metres)) metros"
    }

    static func formatKm(_ km: Double, locale: Locale) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 1
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: km)) ?? "\(km)"
    }
}
