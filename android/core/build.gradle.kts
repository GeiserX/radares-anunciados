// SPDX-License-Identifier: GPL-3.0-or-later
// Pure Kotlin/JVM port of Sources/RadaresCore. No Android dependency, so the route vectors run on any JVM.

import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(libs.kotlinx.serialization.json)
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
}

tasks.test {
    useJUnitPlatform()
    // The Swift fixtures are the Android contract: read in place, never copied, so a vector added on main counts at once.
    val fixtures = rootDir.resolve("../Tests/RadaresCoreTests/Fixtures")
    inputs.dir(fixtures)
    systemProperty("radares.fixtures", fixtures.absolutePath)
    testLogging {
        events("passed", "skipped", "failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
        showStandardStreams = true
    }
    addTestListener(object : TestListener {
        override fun beforeSuite(suite: TestDescriptor) {}
        override fun beforeTest(testDescriptor: TestDescriptor) {}
        override fun afterTest(testDescriptor: TestDescriptor, result: TestResult) {}
        override fun afterSuite(suite: TestDescriptor, result: TestResult) {
            if (suite.parent == null) {
                println("Executed ${result.testCount} tests: ${result.successfulTestCount} passed, ${result.failedTestCount} failed, ${result.skippedTestCount} skipped")
                if (result.testCount == 0L) throw GradleException("no test was executed")
            }
        }
    })
}
