// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

package dev.enterpriseflutter.tom_secrets_mobile

import android.app.Instrumentation
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.regex.Pattern

/**
 * The Autofill service on a device (part-os-integration, DP-175), against a
 * login form in the test APK's package: the locked response offered at once;
 * choosing it starts the app's own unlock on its own engine (this install is
 * not set up, so it says so; Close fills nothing); a login signed in with
 * reaches the app as a proposal (the save request opens it with the login).
 * Demo data only.
 *
 * `cd android && ./gradlew app:connectedDebugAndroidTest` with an emulator
 * or a device attached.
 */
@RunWith(AndroidJUnit4::class)
class AutofillServiceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(instrumentation)
    private val app = "dev.enterpriseflutter.tom_secrets_mobile"
    private var previous = ""

    @Before
    fun turnOn() {
        previous = device.executeShellCommand("settings get secure autofill_service").trim()
        device.executeShellCommand(
            "settings put secure autofill_service $app/.TomSecretsAutofillService",
        )
    }

    @After
    fun restore() {
        if (previous.isEmpty() || previous == "null") {
            device.executeShellCommand("settings delete secure autofill_service")
        } else {
            device.executeShellCommand("settings put secure autofill_service $previous")
        }
    }

    private fun openLoginForm() {
        // A slow emulator may show "… isn't responding" over the form.
        if (device.hasObject(By.textContains("isn't responding"))) {
            device.findObject(By.text("Wait"))?.click()
        }
        device.executeShellCommand("am start -W -n $app.test/$app.LoginActivity")
        assertNotNull(
            "the login form is shown",
            device.wait(Until.findObject(By.desc("demo-user-field")), 15000),
        )
    }

    /**
     * A label on screen: a platform view's text, or a Flutter widget's,
     * which reaches the accessibility tree as its content description.
     */
    private fun waitForLabel(label: String, timeoutMs: Long): UiObject2? {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            val found = device.findObject(By.textContains(label))
                ?: device.findObject(By.descContains(label))
            if (found != null) return found
            device.waitForIdle(500)
        }
        return null
    }

    /** Focuses the user field and waits for the locked response. */
    private fun lockedResponse(): UiObject2? {
        device.findObject(By.desc("demo-user-field")).click()
        return device.wait(Until.findObject(By.text("Unlock Tom Secrets Manager")), 15000)
    }

    @Test
    fun theLockedResponseOpensTheAppsOwnUnlock() {
        openLoginForm()
        val locked = lockedResponse()
        assertNotNull("the locked response is offered", locked)
        locked!!.click()
        // The unlock on its own engine: this install is not set up.
        val message = waitForLabel("Set Tom Secrets Manager up first", 60000)
        assertNotNull("the app's own unlock says it is not set up", message)
        val close = waitForLabel("Close", 5000)
        assertNotNull("the unlock offers Close", close)
        close!!.click()
        val user = device.wait(Until.findObject(By.desc("demo-user-field")), 15000)
        assertNotNull("back at the form", user)
        assertTrue("nothing filled", user.text.isNullOrEmpty())
    }

    @Test
    fun aLoginSignedInWithBecomesAProposal() {
        val monitor: Instrumentation.ActivityMonitor =
            instrumentation.addMonitor(MainActivity::class.java.name, null, false)
        openLoginForm()
        // The session holds the response (and its SaveInfo) before typing.
        assertNotNull("the locked response is offered", lockedResponse())
        device.findObject(By.desc("demo-user-field")).text = "demo-user"
        device.findObject(By.desc("demo-password-field")).text = "demo-new-pw"
        device.findObject(By.text(Pattern.compile("sign in", Pattern.CASE_INSENSITIVE))).click()
        val save = device.wait(Until.findObject(By.res("android:id/autofill_save_yes")), 15000)
        assertNotNull("the system offers to save", save)
        save.click()
        val opened = instrumentation.waitForMonitorWithTimeout(monitor, 30000)
        assertNotNull("the app opens with the login", opened)
        val intent = opened.intent
        assertEquals(MainActivity.ACTION_PROPOSE, intent.action)
        assertEquals("androidapp://$app.test", intent.getStringExtra("url"))
        assertEquals("demo-user", intent.getStringExtra("userName"))
        assertEquals("demo-new-pw", intent.getStringExtra("password"))
        opened.finish()
    }
}
