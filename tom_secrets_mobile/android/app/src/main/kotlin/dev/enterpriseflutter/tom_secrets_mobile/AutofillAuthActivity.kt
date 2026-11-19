// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

package dev.enterpriseflutter.tom_secrets_mobile

import android.app.Activity
import android.app.assist.AssistStructure
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.autofill.AutofillManager
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.RequiresApi
import androidx.biometric.BiometricManager.Authenticators
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/**
 * The locked response's authentication (part-os-integration, DP-175), a
 * transparent activity:
 *
 * - **the app holds unlocked vaults** (its engine is running and answers
 *   `state` unlocked): BiometricPrompt (the fingerprint or the device's
 *   screen lock), then the app's `logins` for the request from its memory;
 * - **otherwise** (the process was started for this, or the app is
 *   locked): [AutofillUnlockActivity], the app's own unlock on an engine of
 *   its own, fetches the vaults and answers.
 *
 * The logins come back as the filled datasets
 * (`EXTRA_AUTHENTICATION_RESULT`); none, a refusal or a cancel fills
 * nothing.
 */
@RequiresApi(Build.VERSION_CODES.O)
class AutofillAuthActivity : FragmentActivity() {
    private val unlock =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            @Suppress("DEPRECATION")
            val logins = result.data?.getParcelableArrayListExtra<Bundle>(EXTRA_LOGINS)
            if (result.resultCode == Activity.RESULT_OK && logins != null) {
                finishWith(logins)
            } else {
                cancel()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) return
        val engine = FlutterEngineCache.getInstance().get(MainActivity.ENGINE)
        if (engine == null) {
            startUnlock()
            return
        }
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.invokeMethod("state", null, object : MethodChannel.Result {
            override fun success(result: Any?) {
                if ((result as? Map<*, *>)?.get("unlocked") == true) {
                    prompt(channel)
                } else {
                    startUnlock()
                }
            }

            override fun error(code: String, message: String?, details: Any?) = startUnlock()
            override fun notImplemented() = startUnlock()
        })
    }

    private fun request(): Map<String, Any?> {
        val extras = intent.extras ?: Bundle()
        return mapOf(
            AutofillFields.KEY_PACKAGE to extras.getString(AutofillFields.KEY_PACKAGE),
            AutofillFields.KEY_WEB_DOMAIN to extras.getString(AutofillFields.KEY_WEB_DOMAIN),
            AutofillFields.KEY_WEB_SCHEME to extras.getString(AutofillFields.KEY_WEB_SCHEME),
            AutofillFields.KEY_CERTIFICATES to
                (extras.getStringArrayList(AutofillFields.KEY_CERTIFICATES) ?: arrayListOf<String>()),
        )
    }

    /** The app is unlocked: the user confirms, then the app answers. */
    private fun prompt(channel: MethodChannel) {
        val authenticators = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Authenticators.BIOMETRIC_STRONG or Authenticators.DEVICE_CREDENTIAL
        } else {
            Authenticators.BIOMETRIC_WEAK or Authenticators.DEVICE_CREDENTIAL
        }
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Fill from Tom Secrets")
            .setSubtitle(request()[AutofillFields.KEY_WEB_DOMAIN] as String?
                ?: request()[AutofillFields.KEY_PACKAGE] as String?)
            .setAllowedAuthenticators(authenticators)
            .build()
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                channel.invokeMethod("logins", request(), object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        val logins = ArrayList<Bundle>()
                        for (item in result as? List<*> ?: emptyList<Any>()) {
                            val m = item as? Map<*, *> ?: continue
                            logins.add(Bundle().apply {
                                putString("label", m["label"] as String?)
                                putString("userName", m["userName"] as String?)
                                putString("password", m["password"] as String?)
                            })
                        }
                        finishWith(logins)
                    }

                    override fun error(code: String, message: String?, details: Any?) = cancel()
                    override fun notImplemented() = cancel()
                })
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) = cancel()
        }
        BiometricPrompt(this, ContextCompat.getMainExecutor(this), callback).authenticate(info)
    }

    /** The app's own unlock on an engine of its own. */
    private fun startUnlock() {
        unlock.launch(
            Intent(this, AutofillUnlockActivity::class.java).putExtras(intent.extras ?: Bundle()),
        )
    }

    private fun finishWith(logins: List<Bundle>) {
        @Suppress("DEPRECATION")
        val structure: AssistStructure? =
            intent.getParcelableExtra(AutofillManager.EXTRA_ASSIST_STRUCTURE)
        val response = structure?.let {
            AutofillFields.response(this, AutofillFields.of(it), logins)
        }
        if (response == null) {
            val target = intent.getStringExtra(AutofillFields.KEY_WEB_DOMAIN)
                ?: intent.getStringExtra(AutofillFields.KEY_PACKAGE)
            Toast.makeText(this, "No login for $target in Tom Secrets", Toast.LENGTH_SHORT).show()
            cancel()
            return
        }
        setResult(
            Activity.RESULT_OK,
            Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, response),
        )
        finish()
    }

    private fun cancel() {
        setResult(Activity.RESULT_CANCELED)
        finish()
    }

    companion object {
        /** The channel the running app answers on (`mobile_autofill.dart`). */
        const val CHANNEL = "tom_secrets_mobile/autofill"

        /** The unlock activity's answer: the logins as bundles. */
        const val EXTRA_LOGINS = "dev.enterpriseflutter.tom_secrets_mobile.LOGINS"
    }
}
