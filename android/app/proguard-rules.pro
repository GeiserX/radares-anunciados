# SPDX-License-Identifier: GPL-3.0-or-later
#
# kotlinx-serialization: keep the generated serializers of the core's @Serializable types (Radar, PassLedger,
# FeedMeta, Coordinate, GeoJSON shapes), or R8 strips them and the feed and the ledger stop decoding in release.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt
-keepclassmembers class kotlinx.serialization.json.** { *** Companion; }
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class io.github.geiserx.radares.core.**$$serializer { *; }
-keepclassmembers class io.github.geiserx.radares.core.** {
    *** Companion;
}
-keepclasseswithmembers class io.github.geiserx.radares.core.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keepclassmembers enum io.github.geiserx.radares.core.** { *; }

# Car App Library: the host instantiates the CarAppService and its Session by reflection from the manifest.
-keep class * extends androidx.car.app.CarAppService { <init>(); }

# osmdroid reads its tile-source classes reflectively.
-dontwarn org.osmdroid.**
