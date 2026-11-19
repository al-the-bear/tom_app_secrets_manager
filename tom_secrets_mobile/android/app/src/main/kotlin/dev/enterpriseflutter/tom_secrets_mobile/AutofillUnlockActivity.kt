// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

package dev.enterpriseflutter.tom_secrets_mobile

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The Autofill service's own unlock (DP-175): the app's activity with its
 * channels and FLAG_SECURE, on the Dart entry point `autofillMain` and an
 * engine of its own. The app's unlock (the fingerprint, else the master
 * password), the vaults fetched through GitHub's REST API and opened in
 * memory, the request's logins handed back; the engine and its vaults end
 * with the activity. Without network it says so and fills nothing.
 */
class AutofillUnlockActivity : MainActivity() {
    override fun getDartEntrypointFunctionName(): String = "autofillMain"

    override val isAutofillUnlock: Boolean get() = true

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "request" -> {
                        val extras = intent.extras ?: Bundle()
                        result.success(
                            mapOf(
                                AutofillFields.KEY_PACKAGE to
                                    extras.getString(AutofillFields.KEY_PACKAGE),
                                AutofillFields.KEY_WEB_DOMAIN to
                                    extras.getString(AutofillFields.KEY_WEB_DOMAIN),
                                AutofillFields.KEY_WEB_SCHEME to
                                    extras.getString(AutofillFields.KEY_WEB_SCHEME),
                                AutofillFields.KEY_CERTIFICATES to
                                    (extras.getStringArrayList(AutofillFields.KEY_CERTIFICATES)
                                        ?: arrayListOf<String>()),
                            ),
                        )
                    }
                    "done" -> {
                        val logins = ArrayList<Bundle>()
                        for (item in call.argument<List<Map<String, Any?>>>("logins") ?: emptyList()) {
                            logins.add(Bundle().apply {
                                putString("label", item["label"] as String?)
                                putString("userName", item["userName"] as String?)
                                putString("password", item["password"] as String?)
                            })
                        }
                        result.success(null)
                        setResult(
                            Activity.RESULT_OK,
                            Intent().putParcelableArrayListExtra(
                                AutofillAuthActivity.EXTRA_LOGINS,
                                logins,
                            ),
                        )
                        finish()
                    }
                    "cancel" -> {
                        result.success(null)
                        setResult(Activity.RESULT_CANCELED)
                        finish()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        const val CHANNEL = "tom_secrets_mobile/autofill_unlock"
    }
}
