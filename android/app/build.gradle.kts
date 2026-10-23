// SPDX-License-Identifier: GPL-3.0-or-later
//
// The phone app: driving detection, the foreground location service, voice and notifications, the feed, the
// map, Estado and Fuentes screens. The alert rules live in :core and are the same code the route vectors check.

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "io.github.geiserx.radares"
    compileSdk = 37

    defaultConfig {
        applicationId = "io.github.geiserx.radares"
        minSdk = 29
        targetSdk = 36
        versionCode = (findProperty("VERSION_CODE") as String).toInt()
        versionName = findProperty("VERSION_NAME") as String
    }

    dependenciesInfo {
        // No Google-encrypted dependency block in the APK or the bundle.
        includeInApk = false
        includeInBundle = false
    }

    signingConfigs {
        create("release") {
            fun value(name: String): String? = findProperty(name) as String? ?: System.getenv(name)
            val path = value("RADARES_KEYSTORE_PATH")
            val storePass = value("RADARES_KEYSTORE_PASSWORD")
            val alias = value("RADARES_KEY_ALIAS")
            val keyPass = value("RADARES_KEY_PASSWORD")
            // Signed only when all four are present; otherwise the release build stays unsigned.
            if (path != null && storePass != null && alias != null && keyPass != null) {
                storeFile = file(path)
                storePassword = storePass
                keyAlias = alias
                keyPassword = keyPass
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            val release = signingConfigs.findByName("release")
            if (release?.storeFile != null) signingConfig = release
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    lint {
        // An orphaned string or drawable is an error, not a warning nobody reads.
        error += "UnusedResources"
        abortOnError = true
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    testOptions {
        unitTests {
            // Robolectric needs the merged manifest and resources.
            isIncludeAndroidResources = true
        }
    }

    sourceSets {
        // The bundled feed snapshot is the iOS app's file, copied at build time: one snapshot in git.
        getByName("main").assets.directories.add(layout.buildDirectory.dir("generated/snapshot").get().asFile.path)
    }
}

val copyFeedSnapshot by tasks.registering(Sync::class) {
    from(rootDir.resolve("../App/Sources/Resources")) {
        include("feed-snapshot.geojson", "feed-snapshot.date")
    }
    into(layout.buildDirectory.dir("generated/snapshot"))
}
tasks.named("preBuild") { dependsOn(copyFeedSnapshot) }

dependencies {
    implementation(project(":core"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.service)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.work.runtime.ktx)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.material3)
    implementation(libs.play.services.location)
    implementation(libs.androidx.car.app)
    implementation(libs.osmdroid.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)

    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
    // Robolectric and the Compose test rule are JUnit 4: the vintage engine runs them on the JUnit 5 platform.
    // Without it the JUnit 4 tests are silently not run, which looks exactly like passing.
    testImplementation(libs.junit4)
    testRuntimeOnly(libs.junit.vintage.engine)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.androidx.work.testing)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(platform(libs.androidx.compose.bom))
    testImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}

tasks.withType<Test>().configureEach {
    useJUnitPlatform()
    // ReleaseManifestTest reads the release variant's merged manifest.
    dependsOn("processReleaseMainManifest")
    // The route vectors and the feed sample the core tests read, shared with the iOS tests.
    val fixtures = rootDir.resolve("../Tests/RadaresCoreTests/Fixtures")
    inputs.dir(fixtures).withPropertyName("fixtures").withPathSensitivity(PathSensitivity.RELATIVE)
    systemProperty("radares.fixtures", fixtures.absolutePath)
    // The bundled snapshot (a real, full-size feed) for the feed store tests.
    val snapshot = rootDir.resolve("../App/Sources/Resources")
    inputs.dir(snapshot).withPropertyName("snapshot").withPathSensitivity(PathSensitivity.RELATIVE)
    systemProperty("radares.snapshotDir", snapshot.absolutePath)
    // The app's own resources, for the forbidden-sentence check.
    systemProperty("radares.resDir", layout.projectDirectory.dir("src/main/res").asFile.absolutePath)
    // The release manifest test reads the merged manifest of the release variant.
    systemProperty("radares.appBuildDir", layout.buildDirectory.get().asFile.absolutePath)
    testLogging {
        events("failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
    addTestListener(object : TestListener {
        override fun beforeSuite(suite: TestDescriptor) {}
        override fun beforeTest(testDescriptor: TestDescriptor) {}
        override fun afterTest(testDescriptor: TestDescriptor, result: TestResult) {}
        override fun afterSuite(suite: TestDescriptor, result: TestResult) {
            if (suite.parent == null) {
                println("app tests: ${result.testCount} executed, ${result.successfulTestCount} passed, ${result.failedTestCount} failed, ${result.skippedTestCount} skipped")
                if (result.testCount == 0L) throw GradleException("no app test was executed")
            }
        }
    })
}
