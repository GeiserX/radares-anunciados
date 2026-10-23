// SPDX-License-Identifier: GPL-3.0-or-later
// The Android build of Radares Anunciados. :core is the pure Kotlin port of Sources/RadaresCore; the app lane adds :app.

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "radares-anunciados"

include(":core")
include(":app")
