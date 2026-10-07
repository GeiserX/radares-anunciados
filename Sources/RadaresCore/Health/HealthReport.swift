// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Estado rules of design 6, one HealthItem per row, pure over HealthInputs. Titles are the row names of the
// design table; details say what is wrong and what to do, in plain words, because Estado is the screen the driver
// reads when something failed. Spanish by default; English when the locale is English, like Phrasing.

import Foundation

public func healthReport(_ i: HealthInputs, locale: Locale = Locale(identifier: "es_ES")) -> [HealthItem] {
    let l = HealthText(en: Phrasing.isEnglish(locale))
    return [
        locationRow(i, l), sessionRow(i, l), launchesRow(i, l), fenceRow(i, l), slcRow(i, l), feedRow(i, l), refreshRow(i, l),
        notificationsRow(i, l), activityRow(i, l), motionRow(i, l), voiceRow(i, l), filesRow(i, l), lastDriveRow(i, l),
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

    /// The row title in the locale's language; the Spanish names above are the ids.
    public static func localized(_ title: String, locale: Locale) -> String {
        guard Phrasing.isEnglish(locale) else { return title }
        switch title {
        case location: return "Location"
        case session: return "Always session"
        case launches: return "Background launches"
        case fence: return "Parked fence"
        case slc: return "Significant change"
        case feed: return "Data"
        case refresh: return "Background refresh"
        case notifications: return "Notifications"
        case activity: return "Car screen"
        case motion: return "Motion"
        case voice: return "Voice"
        case files: return "Files"
        case lastDrive: return "Last drive"
        default: return title
        }
    }
}

/// Picks the Spanish or the English wording of a detail.
private struct HealthText {
    let en: Bool

    func callAsFunction(_ es: String, _ en: String) -> String {
        self.en ? en : es
    }

    func title(_ t: String) -> String {
        HealthTitles.localized(t, locale: en ? Locale(identifier: "en") : Locale(identifier: "es_ES"))
    }

    func age(_ from: Date, _ now: Date) -> String {
        let hours = now.timeIntervalSince(from) / 3600
        if hours < 1 { return en ? "less than an hour ago" : "hace menos de una hora" }
        if hours < 48 { return en ? "\(Int(hours)) h ago" : "hace \(Int(hours)) h" }
        return en ? "\(Int(hours / 24)) days ago" : "hace \(Int(hours / 24)) días"
    }
}

private func days(_ from: Date?, _ now: Date) -> Double? {
    from.map { now.timeIntervalSince($0) / 86_400 }
}

private func locationRow(_ i: HealthInputs, _ l: HealthText) -> HealthItem {
    let t = l.title(HealthTitles.location)
    switch i.locationAuthorization {
    case .always:
        if !i.preciseLocation {
            return HealthItem(status: .fail, title: t, detail: l("Ubicación precisa desactivada: sin ella no hay valla ni distancias fiables", "Precise Location off: without it there is no fence and no reliable distance"), action: .openSettings)
        }
        return HealthItem(status: .ok, title: t, detail: l("Siempre, precisa", "Always, precise"))
    case .whenInUse:
        return HealthItem(status: .warn, title: t, detail: l("Solo mientras se usa: abre la app antes de conducir, o concede Siempre", "While Using only: open the app before you drive, or grant Always"), action: .openSettings)
    case .notDetermined:
        return HealthItem(status: .fail, title: t, detail: l("Permiso no pedido todavía", "Permission not asked yet"), action: .openOnboarding)
    case .denied, .restricted:
        return HealthItem(status: .fail, title: t, detail: l("Sin permiso de ubicación: la app no puede avisar", "No location permission: the app cannot warn"), action: .openSettings)
    }
}

private func sessionRow(_ i: HealthInputs, _ l: HealthText) -> HealthItem {
    let t = l.title(HealthTitles.session)
    let d = i.sessionDiagnostics
    var flags: [String] = []
    if d.alwaysAuthorizationDenied { flags.append(l("Permiso Siempre no concedido", "Always permission not granted")) }
    if d.fullAccuracyDenied { flags.append(l("Ubicación precisa desactivada", "Precise Location off")) }
    if d.authorizationRestricted { flags.append(l("Ubicación restringida", "Location restricted")) }
    if d.authorizationDenied { flags.append(l("Ubicación denegada", "Location denied")) }
    if d.authorizationDeniedGlobally { flags.append(l("Localización desactivada en el sistema", "Location Services off in the system")) }
    if d.insufficientlyInUse { flags.append(l("Sesión sin uso suficiente", "Session insufficiently in use")) }
    if !flags.isEmpty {
        return HealthItem(status: .fail, title: t, detail: flags.joined(separator: "; "), action: .openSettings)
    }
    if !i.sessionTaken {
        return HealthItem(status: .warn, title: t, detail: l("Sesión no tomada en este arranque", "Session not taken at this launch"), action: .openOnboarding)
    }
    return HealthItem(status: .ok, title: t, detail: l("Sesión Siempre tomada", "Always session taken"))
}

private func launchesRow(_ i: HealthInputs, _ l: HealthText) -> HealthItem {
    let t = l.title(HealthTitles.launches)
    let window = Int(Thresholds.healthWindowDays)
    if i.lastEventWasWillTerminate {
        return HealthItem(status: .fail, title: t, detail: l("Última sesión cerrada por ti: no cierres la app desde el selector", "Last session closed by you: do not close the app from the app switcher"))
    }
    if i.drives > 0, i.backgroundLaunches == 0 {
        return HealthItem(status: .warn, title: t, detail: l("iOS no ha arrancado la app sola en \(window) días", "iOS has not launched the app on its own in \(window) days"))
    }
    return HealthItem(status: .ok, title: t, detail: l(
        "\(i.backgroundLaunches) en segundo plano, \(i.drives) viajes en \(window) días",
        "\(i.backgroundLaunches) in the background, \(i.drives) drives in \(window) days"
    ))
}

private func fenceRow(_ i: HealthInputs, _ l: HealthText) -> HealthItem {
    let t = l.title(HealthTitles.fence)
    let bad = ["conditionLimitExceeded", "persistenceUnavailable", "authorizationDenied"]
    let hit = i.parkedFenceFlags.filter { bad.contains($0) }
    if !hit.isEmpty {
        return HealthItem(status: .fail, title: t, detail: l("La valla falló: \(hit.joined(separator: ", "))", "The fence failed: \(hit.joined(separator: ", "))"), action: .openSettings)
    }
    if !i.parkedFenceIdentifierPresent {
        return HealthItem(status: .warn, title: t, detail: l("Valla no registrada tras el último arranque", "Fence not registered after the last launch"))
    }
    return HealthItem(status: .ok, title: t, detail: l("Valla registrada", "Fence registered"))
}

private func slcRow(_ i: HealthInputs, _ l: HealthText) -> HealthItem {
    let t = l.title(HealthTitles.slc)
    if !i.slcStarted {
        return HealthItem(status: .fail, title: t, detail: l("Cambio significativo no iniciado", "Significant change not started"))
    }
    let recentDrive = days(i.lastDriveEnded, i.now).map { $0 <= Thresholds.slcSilentDays } ?? false
    let deliveryAge = days(i.lastSlcDelivery, i.now)
    if recentDrive, deliveryAge == nil || deliveryAge! > Thresholds.slcSilentDays {
        let silent = Int(Thresholds.slcSilentDays)
        return HealthItem(status: .fail, title: t, detail: l("Sin entregas en \(silent) días con viajes", "No deliveries in \(silent) days with drives"))
    }
    if let last = i.lastSlcDelivery {
        return HealthItem(status: .ok, title: t, detail: l("Última entrega \(l.age(last, i.now))", "Last delivery \(l.age(last, i.now))"))
    }
    return HealthItem(status: .ok, title: t, detail: l("Iniciado, sin entregas todavía", "Started, no deliveries yet"))
}

private func feedRow(_ i: HealthInputs, _ l: HealthText) -> HealthItem {
    let t = l.title(HealthTitles.feed)
    guard let fetchedAt = i.feedFetchedAt else {
        return HealthItem(status: .fail, title: t, detail: l("Sin datos descargados", "No data downloaded"), action: .refreshFeed)
    }
    let age = i.now.timeIntervalSince(fetchedAt) / 86_400
    if age > Thresholds.feedStaleFailDays {
        return HealthItem(status: .fail, title: t, detail: l("Datos de hace \(Int(age)) días", "Data from \(Int(age)) days ago"), action: .refreshFeed)
    }
    if i.feedFeatureCount < Thresholds.feedMinFeatures {
        return HealthItem(status: .fail, title: t, detail: l("Solo \(i.feedFeatureCount) radares, se esperan al menos \(Thresholds.feedMinFeatures)", "Only \(i.feedFeatureCount) radars, at least \(Thresholds.feedMinFeatures) expected"), action: .refreshFeed)
    }
    if i.feedConsecutiveFailures >= Thresholds.feedFailStreak {
        return HealthItem(status: .fail, title: t, detail: l("\(i.feedConsecutiveFailures) descargas seguidas fallidas", "\(i.feedConsecutiveFailures) downloads failed in a row"), action: .refreshFeed)
    }
    if age > Thresholds.feedStaleWarnDays {
        return HealthItem(status: .warn, title: t, detail: l("Datos de hace \(Int(age)) días", "Data from \(Int(age)) days ago"), action: .refreshFeed)
    }
    return HealthItem(status: .ok, title: t, detail: l("\(i.feedFeatureCount) radares, \(l.age(fetchedAt, i.now))", "\(i.feedFeatureCount) radars, \(l.age(fetchedAt, i.now))"))
}

private func refreshRow(_ i: HealthInputs, _ l: HealthText) -> HealthItem {
    let t = l.title(HealthTitles.refresh)
    switch i.backgroundRefresh {
    case .denied:
        return HealthItem(status: .fail, title: t, detail: l("Actualización en segundo plano desactivada", "Background App Refresh off"), action: .openSettings)
    case .restricted:
        return HealthItem(status: .warn, title: t, detail: l("Actualización en segundo plano restringida", "Background App Refresh restricted"))
    case .available:
        break
    }
    if i.lowPowerMode {
        return HealthItem(status: .warn, title: t, detail: l("Modo de bajo consumo: no se actualiza en segundo plano", "Low Power Mode: no background refresh"))
    }
    let age = days(i.lastBgTaskRan, i.now)
    if age == nil || age! > Thresholds.bgRefreshSilentDays {
        let silent = Int(Thresholds.bgRefreshSilentDays)
        return HealthItem(status: .warn, title: t, detail: l("Sin ejecución en \(silent) días (\(i.pendingRefreshRequests) pendientes)", "No run in \(silent) days (\(i.pendingRefreshRequests) pending)"))
    }
    return HealthItem(status: .ok, title: t, detail: l("Última ejecución \(l.age(i.lastBgTaskRan!, i.now))", "Last run \(l.age(i.lastBgTaskRan!, i.now))"))
}

private func notificationsRow(_ i: HealthInputs, _ l: HealthText) -> HealthItem {
    let t = l.title(HealthTitles.notifications)
    if i.notificationAuthorization != .authorized {
        return HealthItem(status: .fail, title: t, detail: l("Notificaciones no autorizadas", "Notifications not allowed"), action: .openSettings)
    }
    if i.timeSensitiveSetting == .disabled {
        return HealthItem(status: .warn, title: t, detail: l("Notificaciones urgentes desactivadas", "Time Sensitive notifications off"), action: .openSettings)
    }
    return HealthItem(status: .ok, title: t, detail: l("Autorizadas, urgentes permitidas", "Allowed, Time Sensitive on"))
}

private func activityRow(_ i: HealthInputs, _ l: HealthText) -> HealthItem {
    let t = l.title(HealthTitles.activity)
    if !i.activitiesEnabled {
        return HealthItem(status: .fail, title: t, detail: l("Actividades en directo desactivadas", "Live Activities off"), action: .openSettings)
    }
    // The card can only begin while the app is on screen (design 4.2): a drive that began with the app in the
    // background had voice and the notification, not the card. The row says so; the fix is leaving the app open.
    if let drive = i.lastDriveStarted, i.lastActivityStarted == nil || i.lastActivityStarted! < drive {
        return HealthItem(status: .warn, title: t, detail: l("Pantalla del coche no iniciada en el último viaje: deja la app en pantalla al salir", "Car screen not started on the last drive: leave the app on screen when you set off"))
    }
    return HealthItem(status: .ok, title: t, detail: l("Pantalla del coche lista", "Car screen ready"))
}

private func motionRow(_ i: HealthInputs, _ l: HealthText) -> HealthItem {
    let t = l.title(HealthTitles.motion)
    switch i.motionAuthorization {
    case .authorized:
        return HealthItem(status: .ok, title: t, detail: l("Movimiento permitido", "Motion allowed"))
    case .notDetermined:
        return HealthItem(status: .warn, title: t, detail: l("Sin permiso de movimiento: cada despertar gasta GPS", "No Motion permission: every wake-up spends GPS"), action: .openOnboarding)
    case .denied, .restricted:
        return HealthItem(status: .warn, title: t, detail: l("Movimiento denegado: cada despertar gasta GPS", "Motion denied: every wake-up spends GPS"), action: .openSettings)
    }
}

private func voiceRow(_ i: HealthInputs, _ l: HealthText) -> HealthItem {
    let t = l.title(HealthTitles.voice)
    if let error = i.lastSpeechSetActiveError {
        return HealthItem(status: .fail, title: t, detail: l("El audio no se pudo activar: \(error)", "The audio session could not be activated: \(error)"))
    }
    if !i.spanishVoiceAvailable {
        return HealthItem(status: .fail, title: t, detail: l("Voz en español no instalada", "Spanish voice not installed"), action: .openSettings)
    }
    return HealthItem(status: .ok, title: t, detail: l("Voz lista", "Voice ready"))
}

private func filesRow(_ i: HealthInputs, _ l: HealthText) -> HealthItem {
    let t = l.title(HealthTitles.files)
    switch i.protectionVerified {
    case .some(true):
        return HealthItem(status: .ok, title: t, detail: l("Legibles tras el primer desbloqueo", "Readable after the first unlock"))
    case .some(false):
        return HealthItem(status: .fail, title: t, detail: l("Protección de archivos distinta de la esperada", "File protection is not the expected one"))
    case .none:
        return HealthItem(status: .warn, title: t, detail: l("Protección sin comprobar todavía", "File protection not checked yet"))
    }
}

private func lastDriveRow(_ i: HealthInputs, _ l: HealthText) -> HealthItem {
    let t = l.title(HealthTitles.lastDrive)
    guard let gap = i.lastDriveMaxGapSeconds else {
        return HealthItem(status: .ok, title: t, detail: l("Sin viajes todavía", "No drives yet"))
    }
    if gap > Thresholds.maxGapWarnSeconds {
        return HealthItem(status: .warn, title: t, detail: l("Hueco de \(Int(gap)) s entre posiciones: iOS frenó la app", "A \(Int(gap)) s gap between positions: iOS held the app back"))
    }
    if i.lastDriveHadLateAlert {
        return HealthItem(status: .warn, title: t, detail: l("Un aviso llegó tarde (despertar tardío o GPS frío)", "A warning came late (late wake-up or cold GPS)"))
    }
    return HealthItem(status: .ok, title: t, detail: l("Posiciones cada \(Int(gap)) s como máximo, sin avisos tardíos", "Positions at most \(Int(gap)) s apart, no late warnings"))
}
