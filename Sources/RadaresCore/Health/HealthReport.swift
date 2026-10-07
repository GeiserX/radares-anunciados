// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Estado rules of design 6, one HealthItem per row, pure over HealthInputs. Titles are the row names of the
// design table; details say what is wrong and what to do, in Spanish, because Estado is the screen the driver
// reads when something failed.

import Foundation

public func healthReport(_ i: HealthInputs) -> [HealthItem] {
    [
        locationRow(i), sessionRow(i), launchesRow(i), fenceRow(i), slcRow(i), feedRow(i), refreshRow(i),
        notificationsRow(i), activityRow(i), motionRow(i), voiceRow(i), filesRow(i), lastDriveRow(i),
    ]
}

public enum HealthTitles {
    public static let location = "Ubicación"
    public static let session = "Sesión Siempre"
    public static let launches = "Arranques solos"
    public static let fence = "Valla de aparcamiento"
    public static let slc = "Cambio significativo"
    public static let feed = "Datos"
    public static let refresh = "Actualización en segundo plano"
    public static let notifications = "Notificaciones"
    public static let activity = "Pantalla del coche"
    public static let motion = "Movimiento"
    public static let voice = "Voz"
    public static let files = "Archivos"
    public static let lastDrive = "Último viaje"
}

private func days(_ from: Date?, _ now: Date) -> Double? {
    from.map { now.timeIntervalSince($0) / 86_400 }
}

private func ageText(_ from: Date, _ now: Date) -> String {
    let hours = now.timeIntervalSince(from) / 3600
    if hours < 1 { return "hace menos de una hora" }
    if hours < 48 { return "hace \(Int(hours)) h" }
    return "hace \(Int(hours / 24)) días"
}

private func locationRow(_ i: HealthInputs) -> HealthItem {
    let t = HealthTitles.location
    switch i.locationAuthorization {
    case .always:
        if !i.preciseLocation {
            return HealthItem(status: .fail, title: t, detail: "Ubicación precisa desactivada: sin ella no hay valla ni distancias fiables", action: .openSettings)
        }
        return HealthItem(status: .ok, title: t, detail: "Siempre, precisa")
    case .whenInUse:
        return HealthItem(status: .warn, title: t, detail: "Solo mientras se usa: abre la app antes de conducir, o concede Siempre", action: .openSettings)
    case .notDetermined:
        return HealthItem(status: .fail, title: t, detail: "Permiso no pedido todavía", action: .openOnboarding)
    case .denied, .restricted:
        return HealthItem(status: .fail, title: t, detail: "Sin permiso de ubicación: la app no puede avisar", action: .openSettings)
    }
}

private func sessionRow(_ i: HealthInputs) -> HealthItem {
    let t = HealthTitles.session
    let d = i.sessionDiagnostics
    var flags: [String] = []
    if d.alwaysAuthorizationDenied { flags.append("Permiso Siempre no concedido") }
    if d.fullAccuracyDenied { flags.append("Ubicación precisa desactivada") }
    if d.authorizationRestricted { flags.append("Ubicación restringida") }
    if d.authorizationDenied { flags.append("Ubicación denegada") }
    if d.authorizationDeniedGlobally { flags.append("Localización desactivada en el sistema") }
    if d.insufficientlyInUse { flags.append("Sesión sin uso suficiente") }
    if !flags.isEmpty {
        return HealthItem(status: .fail, title: t, detail: flags.joined(separator: "; "), action: .openSettings)
    }
    if !i.sessionTaken {
        return HealthItem(status: .warn, title: t, detail: "Sesión no tomada en este arranque", action: .openOnboarding)
    }
    return HealthItem(status: .ok, title: t, detail: "Sesión Siempre tomada")
}

private func launchesRow(_ i: HealthInputs) -> HealthItem {
    let t = HealthTitles.launches
    if i.lastEventWasWillTerminate {
        return HealthItem(status: .fail, title: t, detail: "Última sesión cerrada por ti: no cierres la app desde el selector")
    }
    if i.drives > 0, i.backgroundLaunches == 0, i.intentLaunches == 0 {
        return HealthItem(status: .warn, title: t, detail: "iOS no ha arrancado la app sola en \(Int(Thresholds.healthWindowDays)) días", action: .showAutomationRecipe)
    }
    return HealthItem(status: .ok, title: t, detail: "\(i.backgroundLaunches) en segundo plano, \(i.intentLaunches) por atajo, \(i.drives) viajes en \(Int(Thresholds.healthWindowDays)) días")
}

private func fenceRow(_ i: HealthInputs) -> HealthItem {
    let t = HealthTitles.fence
    let bad = ["conditionLimitExceeded", "persistenceUnavailable", "authorizationDenied"]
    let hit = i.parkedFenceFlags.filter { bad.contains($0) }
    if !hit.isEmpty {
        return HealthItem(status: .fail, title: t, detail: "La valla falló: \(hit.joined(separator: ", "))", action: .openSettings)
    }
    if !i.parkedFenceIdentifierPresent {
        return HealthItem(status: .warn, title: t, detail: "Valla no registrada tras el último arranque")
    }
    return HealthItem(status: .ok, title: t, detail: "Valla registrada")
}

private func slcRow(_ i: HealthInputs) -> HealthItem {
    let t = HealthTitles.slc
    if !i.slcStarted {
        return HealthItem(status: .fail, title: t, detail: "Cambio significativo no iniciado")
    }
    let recentDrive = days(i.lastDriveEnded, i.now).map { $0 <= Thresholds.slcSilentDays } ?? false
    let deliveryAge = days(i.lastSlcDelivery, i.now)
    if recentDrive, deliveryAge == nil || deliveryAge! > Thresholds.slcSilentDays {
        return HealthItem(status: .fail, title: t, detail: "Sin entregas en \(Int(Thresholds.slcSilentDays)) días con viajes")
    }
    if let last = i.lastSlcDelivery {
        return HealthItem(status: .ok, title: t, detail: "Última entrega \(ageText(last, i.now))")
    }
    return HealthItem(status: .ok, title: t, detail: "Iniciado, sin entregas todavía")
}

private func feedRow(_ i: HealthInputs) -> HealthItem {
    let t = HealthTitles.feed
    guard let fetchedAt = i.feedFetchedAt else {
        return HealthItem(status: .fail, title: t, detail: "Sin datos descargados", action: .refreshFeed)
    }
    let age = i.now.timeIntervalSince(fetchedAt) / 86_400
    if age > Thresholds.feedStaleFailDays {
        return HealthItem(status: .fail, title: t, detail: "Datos de hace \(Int(age)) días", action: .refreshFeed)
    }
    if i.feedFeatureCount < Thresholds.feedMinFeatures {
        return HealthItem(status: .fail, title: t, detail: "Solo \(i.feedFeatureCount) radares, se esperan al menos \(Thresholds.feedMinFeatures)", action: .refreshFeed)
    }
    if i.feedConsecutiveFailures >= Thresholds.feedFailStreak {
        return HealthItem(status: .fail, title: t, detail: "\(i.feedConsecutiveFailures) descargas seguidas fallidas", action: .refreshFeed)
    }
    if age > Thresholds.feedStaleWarnDays {
        return HealthItem(status: .warn, title: t, detail: "Datos de hace \(Int(age)) días", action: .refreshFeed)
    }
    return HealthItem(status: .ok, title: t, detail: "\(i.feedFeatureCount) radares, \(ageText(fetchedAt, i.now))")
}

private func refreshRow(_ i: HealthInputs) -> HealthItem {
    let t = HealthTitles.refresh
    switch i.backgroundRefresh {
    case .denied:
        return HealthItem(status: .fail, title: t, detail: "Actualización en segundo plano desactivada", action: .openSettings)
    case .restricted:
        return HealthItem(status: .warn, title: t, detail: "Actualización en segundo plano restringida")
    case .available:
        break
    }
    if i.lowPowerMode {
        return HealthItem(status: .warn, title: t, detail: "Modo de bajo consumo: no se actualiza en segundo plano")
    }
    let age = days(i.lastBgTaskRan, i.now)
    if age == nil || age! > Thresholds.bgRefreshSilentDays {
        return HealthItem(status: .warn, title: t, detail: "Sin ejecución en \(Int(Thresholds.bgRefreshSilentDays)) días (\(i.pendingRefreshRequests) pendientes)")
    }
    return HealthItem(status: .ok, title: t, detail: "Última ejecución \(ageText(i.lastBgTaskRan!, i.now))")
}

private func notificationsRow(_ i: HealthInputs) -> HealthItem {
    let t = HealthTitles.notifications
    if i.notificationAuthorization != .authorized {
        return HealthItem(status: .fail, title: t, detail: "Notificaciones no autorizadas", action: .openSettings)
    }
    if i.timeSensitiveSetting == .disabled {
        return HealthItem(status: .warn, title: t, detail: "Notificaciones urgentes desactivadas", action: .openSettings)
    }
    return HealthItem(status: .ok, title: t, detail: "Autorizadas, urgentes permitidas")
}

private func activityRow(_ i: HealthInputs) -> HealthItem {
    let t = HealthTitles.activity
    if !i.activitiesEnabled {
        return HealthItem(status: .fail, title: t, detail: "Actividades en directo desactivadas", action: .openSettings)
    }
    if !i.intentStartedDriveLogged {
        return HealthItem(status: .warn, title: t, detail: "Automatización no probada", action: .showAutomationRecipe)
    }
    if let drive = i.lastDriveStarted, i.lastActivityStarted == nil || i.lastActivityStarted! < drive {
        return HealthItem(status: .warn, title: t, detail: "Pantalla del coche no iniciada en el último viaje", action: .showAutomationRecipe)
    }
    return HealthItem(status: .ok, title: t, detail: "Pantalla del coche lista")
}

private func motionRow(_ i: HealthInputs) -> HealthItem {
    let t = HealthTitles.motion
    switch i.motionAuthorization {
    case .authorized:
        return HealthItem(status: .ok, title: t, detail: "Movimiento permitido")
    case .notDetermined:
        return HealthItem(status: .warn, title: t, detail: "Sin permiso de movimiento: cada despertar gasta GPS", action: .openOnboarding)
    case .denied, .restricted:
        return HealthItem(status: .warn, title: t, detail: "Movimiento denegado: cada despertar gasta GPS", action: .openSettings)
    }
}

private func voiceRow(_ i: HealthInputs) -> HealthItem {
    let t = HealthTitles.voice
    if let error = i.lastSpeechSetActiveError {
        return HealthItem(status: .fail, title: t, detail: "El audio no se pudo activar: \(error)")
    }
    if !i.spanishVoiceAvailable {
        return HealthItem(status: .fail, title: t, detail: "Voz en español no instalada", action: .openSettings)
    }
    return HealthItem(status: .ok, title: t, detail: "Voz lista")
}

private func filesRow(_ i: HealthInputs) -> HealthItem {
    let t = HealthTitles.files
    switch i.protectionVerified {
    case .some(true):
        return HealthItem(status: .ok, title: t, detail: "Legibles tras el primer desbloqueo")
    case .some(false):
        return HealthItem(status: .fail, title: t, detail: "Protección de archivos distinta de la esperada")
    case .none:
        return HealthItem(status: .warn, title: t, detail: "Protección sin comprobar todavía")
    }
}

private func lastDriveRow(_ i: HealthInputs) -> HealthItem {
    let t = HealthTitles.lastDrive
    guard let gap = i.lastDriveMaxGapSeconds else {
        return HealthItem(status: .ok, title: t, detail: "Sin viajes todavía")
    }
    if gap > Thresholds.maxGapWarnSeconds {
        return HealthItem(status: .warn, title: t, detail: "Hueco de \(Int(gap)) s entre posiciones: iOS frenó la app")
    }
    if i.lastDriveHadLateAlert {
        return HealthItem(status: .warn, title: t, detail: "Un aviso llegó tarde (despertar tardío o GPS frío)")
    }
    return HealthItem(status: .ok, title: t, detail: "Posiciones cada \(Int(gap)) s como máximo, sin avisos tardíos")
}
