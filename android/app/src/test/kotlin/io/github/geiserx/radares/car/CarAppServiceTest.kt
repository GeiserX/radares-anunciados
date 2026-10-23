// SPDX-License-Identifier: GPL-3.0-or-later
//
// The manifest pieces Android Auto needs before it lists the app and draws its banners (docs/ANDROID-AUTO.md):
// the POI CarAppService, the template descriptor, minCarApiLevel, MAP_TEMPLATES, and a host check that accepts any
// host only in debug builds.

package io.github.geiserx.radares.car

import android.content.Intent
import android.content.pm.PackageManager
import androidx.car.app.validation.HostValidator
import androidx.test.core.app.ApplicationProvider
import io.github.geiserx.radares.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.xmlpull.v1.XmlPullParser

@RunWith(RobolectricTestRunner::class)
class CarAppServiceTest {
    private val context = ApplicationProvider.getApplicationContext<android.app.Application>()
    private val pm = context.packageManager

    @Test
    fun serviceIsDeclaredInThePoiCategory() {
        val intent = Intent("androidx.car.app.CarAppService")
            .addCategory("androidx.car.app.category.POI")
            .setPackage(context.packageName)
        val services = pm.queryIntentServices(intent, 0).map { it.serviceInfo.name }
        assertTrue("POI CarAppService missing: $services", RadaresCarAppService::class.java.name in services)
        val info = pm.queryIntentServices(intent, 0).first().serviceInfo
        assertTrue("Android Auto binds from another process, so the service must be exported", info.exported)
    }

    @Test
    fun templateDescriptorAndMinApiLevelAreDeclared() {
        val meta = pm.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA).metaData
        assertNotNull(meta)
        assertEquals(R.xml.automotive_app_desc, meta.getInt("com.google.android.gms.car.application"))
        assertEquals(1, meta.getInt("androidx.car.app.minCarApiLevel"))
        val parser = context.resources.getXml(R.xml.automotive_app_desc)
        val uses = mutableListOf<String>()
        while (parser.next() != XmlPullParser.END_DOCUMENT) {
            if (parser.eventType == XmlPullParser.START_TAG && parser.name == "uses") {
                uses += parser.getAttributeValue(null, "name")
            }
        }
        assertEquals(listOf("template"), uses)
    }

    @Test
    fun mapTemplatesPermissionIsRequested() {
        val requested = pm.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS).requestedPermissions
        assertTrue(requested.orEmpty().contains("androidx.car.app.MAP_TEMPLATES"))
    }

    @Test
    fun anyHostOnlyInDebug() {
        assertSame(HostValidator.ALLOW_ALL_HOSTS_VALIDATOR, RadaresCarAppService.hostValidator(context, debug = true))
        val release = RadaresCarAppService.hostValidator(context, debug = false)
        assertNotSame(HostValidator.ALLOW_ALL_HOSTS_VALIDATOR, release)
        assertTrue(release.allowedHosts.keys.contains("com.google.android.projection.gearhead"))
    }
}
