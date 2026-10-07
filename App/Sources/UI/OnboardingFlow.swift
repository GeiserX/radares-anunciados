// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The four onboarding screens of design 7, each explaining before it asks, all skippable, re-openable from Estado:
// Ubicación (When In Use, then Always, then the Always session), Avisos (notifications and the Motion prompt, in
// the foreground), En el coche (the Live Activity and the automation recipe), Estado.

import CoreLocation
import CoreMotion
import RadaresCore
import SwiftUI
import UserNotifications

struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var permissions = Permissions()

    var body: some View {
        NavigationStack {
            TabView(selection: $step) {
                LocationStep(permissions: permissions).tag(0)
                AlertsStep(permissions: permissions).tag(1)
                CarStep().tag(2)
                HealthView().tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step < 3 {
                        Button("Saltar") { step += 1 }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if step < 3 {
                        Button("Siguiente") { withAnimation { step += 1 } }
                    } else {
                        Button("Empezar") { model.finishOnboarding() }.bold()
                    }
                }
            }
        }
        .task { await model.reload() }
        .onChange(of: step) { _, _ in Task { await model.reload() } }
    }

    private var title: LocalizedStringKey {
        switch step {
        case 0: "Ubicación"
        case 1: "Avisos"
        case 2: "En el coche"
        default: "Estado"
        }
    }
}

/// Screen 1 (design 7): When In Use first; once granted, Always (Core Location shows that prompt at once and
/// only once); then the Always session is taken here, in the foreground, through the "Avisos" switch.
private struct LocationStep: View {
    let permissions: Permissions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "location.circle.fill").font(.system(size: 56)).foregroundStyle(.tint)
                Text("Avisa de los radares anunciados por la DGT, las listas semanales de policías locales publicadas en prensa, y OpenStreetMap. Solo posiciones anunciadas, nunca detectadas. Sin cuenta, sin servidor, sin anuncios. No cierres la app desde el selector.")
                Text("Para avisarte en el coche sin abrirla, la app necesita la ubicación «Siempre» y la «Ubicación exacta». Solo usa el GPS mientras conduces, y la ubicación nunca sale del teléfono.")
                    .foregroundStyle(.secondary)
                switch permissions.location {
                case .always:
                    Label("Ubicación «Siempre» concedida", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .whenInUse:
                    Label("Solo «Mientras se usa»: tendrás que abrir la app antes de conducir.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Abrir Ajustes") { permissions.openSettings() }
                case .denied, .restricted:
                    Label("Ubicación denegada: sin ella la app no puede avisar.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Button("Abrir Ajustes") { permissions.openSettings() }
                case .notDetermined:
                    Button("Permitir ubicación") { permissions.requestLocation() }
                        .buttonStyle(.borderedProminent)
                }
                if permissions.location != .notDetermined, !permissions.precise {
                    Label("Activa «Ubicación exacta»: sin ella las distancias fallan en 1 o 2 km.", systemImage: "scope")
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
    }
}

/// Screen 2 (design 7): Time Sensitive notifications, and the Core Motion prompt, which must appear here in the
/// foreground rather than in a background probe.
private struct AlertsStep: View {
    let permissions: Permissions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "bell.badge.fill").font(.system(size: 56)).foregroundStyle(.tint)
                Text("Cuando no hay tarjeta en la pantalla del coche, el aviso llega como notificación urgente: pasa la mayoría de los modos de concentración. Con el modo Conducción el aviso llega por voz.")
                switch permissions.notifications {
                case .authorized, .provisional, .ephemeral:
                    Label("Notificaciones permitidas", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .denied:
                    Label("Notificaciones denegadas: el aviso solo llegará por voz.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Abrir Ajustes") { permissions.openSettings() }
                case .notDetermined:
                    Button("Permitir avisos") { Task { await permissions.requestNotifications() } }
                        .buttonStyle(.borderedProminent)
                }

                Divider()
                Text("Movimiento: para saber si vas en coche y no gastar batería cuando caminas. Sin él la app funciona igual, pero gasta algo más de GPS al despertarse.")
                switch permissions.motion {
                case .authorized:
                    Label("Movimiento permitido", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .denied, .restricted:
                    Label("Movimiento denegado", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Abrir Ajustes") { permissions.openSettings() }
                case .notDetermined:
                    Button("Permitir Movimiento") { permissions.requestMotion() }
                        .buttonStyle(.bordered)
                }
            }
            .padding()
        }
    }
}

/// Screen 3 (design 7): the car card and its three starters, and a button that starts the Live Activity now.
private struct CarStep: View {
    @State private var tried: Bool?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "car.fill").font(.system(size: 56)).foregroundStyle(.tint)
                Text("Con iOS 26 la tarjeta del radar aparece en la pantalla de CarPlay y en la pantalla bloqueada. La tarjeta solo puede empezar si la app se abre o la inicia un atajo, así que conviene una de estas tres:")
                AutomationRecipeView()
                Button("Probar") { tried = start() }
                    .buttonStyle(.borderedProminent)
                switch tried {
                case true?:
                    Label("Bloquea el iPhone para ver la tarjeta.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case false?:
                    Label("No se pudo mostrar la tarjeta: revisa Actividades en directo en Ajustes.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                case nil:
                    EmptyView()
                }
            }
            .padding()
        }
    }

    /// A sample card for a minute, so the user sees it on the Lock Screen; ended unless a drive is running.
    private func start() -> Bool {
        guard DriveActivityController.shared.current == nil else { return true }
        let sample = DriveContent(
            phase: .approaching,
            kindSymbol: Kind.fixed.symbol,
            title: String(localized: "Radar fijo"),
            subtitle: String(localized: "Prueba"),
            distanceMetres: 600,
            updatedAt: Date()
        )
        do {
            try DriveActivityController.shared.start(content: sample)
        } catch {
            return false
        }
        Task {
            try? await Task.sleep(for: .seconds(60))
            if await LocationCoordinator.shared.state == .idle {
                await DriveActivityController.shared.end()
            }
        }
        return true
    }
}

/// The permission prompts of onboarding and their current answers.
@MainActor
@Observable
final class Permissions: NSObject, CLLocationManagerDelegate {
    private(set) var location: HealthInputs.LocationAuthorization = .notDetermined
    private(set) var precise = true
    private(set) var notifications: HealthInputs.NotificationAuthorization = .notDetermined
    private(set) var motion: HealthInputs.MotionAuthorization = .notDetermined

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let motionManager = CMMotionActivityManager()
    /// Set when the user tapped "Permitir ubicación", so a later authorization change asks for Always and takes the
    /// session; opening onboarding again never flips the "Avisos" switch on its own.
    @ObservationIgnored private var requested = false
    @ObservationIgnored private var askedAlways = false

    override init() {
        super.init()
        manager.delegate = self
        readLocation()
        motion = HealthMonitor.map(CMMotionActivityManager.authorizationStatus())
        Task { notifications = HealthMonitor.map(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus) }
    }

    func requestLocation() {
        requested = true
        manager.requestWhenInUseAuthorization()
    }

    func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        notifications = HealthMonitor.map(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }

    /// The first query shows the Core Motion prompt.
    func requestMotion() {
        let now = Date()
        motionManager.queryActivityStarting(from: now.addingTimeInterval(-Thresholds.motionWindowSeconds), to: now, to: .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.motion = HealthMonitor.map(CMMotionActivityManager.authorizationStatus())
            }
        }
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            readLocation()
            guard requested, location == .whenInUse || location == .always else { return }
            if location == .whenInUse, !askedAlways {
                // Granted While Using: ask for Always at once (Core Location shows that prompt only once).
                askedAlways = true
                self.manager.requestAlwaysAuthorization()
            }
            // Take the session now, in the foreground (design 3.2): Always, or the While-Using degraded mode.
            UserDefaults.standard.set(true, forKey: SettingsKey.warningsEnabled)
            Task { await LocationCoordinator.shared.setWarningsEnabled(true) }
        }
    }

    private func readLocation() {
        location = HealthMonitor.map(manager.authorizationStatus)
        precise = manager.accuracyAuthorization == .fullAccuracy
    }
}
