// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Feed/FeedValidator.swift.
// The five checks of design 5.1, in this order: parses, FeatureCollection, at least Thresholds.feedMinFeatures
// features, at least one fixed, every feature has id, kind and geometry. A failed validation keeps the old file.

package io.github.geiserx.radares.core.feed

import io.github.geiserx.radares.core.Thresholds
import io.github.geiserx.radares.core.model.Kind
import io.github.geiserx.radares.core.model.Radar

class ValidatedFeed(
    val data: ByteArray,
    val radars: List<Radar>,
    /// Radars per kind after decoding (section twins already folded into their stretch).
    val countsByKind: Map<Kind, Int>,
)

sealed class FeedError {
    data class NotJSON(val detail: String) : FeedError()
    data object NotFeatureCollection : FeedError()
    data class TooFewFeatures(val count: Int) : FeedError()
    data object NoFixedRadar : FeedError()
    data class FeatureMissingField(val id: String?, val field: String) : FeedError()
}

sealed class FeedValidation {
    data class Valid(val feed: ValidatedFeed) : FeedValidation()
    data class Invalid(val error: FeedError) : FeedValidation()
}

object FeedValidator {
    fun validate(data: ByteArray): FeedValidation {
        val collection = try {
            GeoJSONFeatureCollection.decode(data)
        } catch (e: GeoJSONDecodingException) {
            return FeedValidation.Invalid(FeedError.NotJSON((e.message ?: "").take(200)))
        }
        if (collection.type != "FeatureCollection") return FeedValidation.Invalid(FeedError.NotFeatureCollection)
        if (collection.features.size < Thresholds.feedMinFeatures) {
            return FeedValidation.Invalid(FeedError.TooFewFeatures(collection.features.size))
        }
        if (collection.features.none { it.properties?.kind == Kind.FIXED.raw }) {
            return FeedValidation.Invalid(FeedError.NoFixedRadar)
        }
        for (feature in collection.features) {
            val id = feature.id
            if (id.isNullOrEmpty()) return FeedValidation.Invalid(FeedError.FeatureMissingField(null, "id"))
            val kind = feature.properties?.kind
            if (kind.isNullOrEmpty()) return FeedValidation.Invalid(FeedError.FeatureMissingField(id, "kind"))
            if (feature.geometry == null) return FeedValidation.Invalid(FeedError.FeatureMissingField(id, "geometry"))
        }
        val radars = FeedDecoder.radars(collection)
        val counts = radars.groupingBy { it.kind }.eachCount()
        return FeedValidation.Valid(ValidatedFeed(data, radars, counts))
    }
}
