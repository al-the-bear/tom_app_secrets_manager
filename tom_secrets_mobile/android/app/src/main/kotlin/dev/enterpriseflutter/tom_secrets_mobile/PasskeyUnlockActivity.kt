// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

package dev.enterpriseflutter.tom_secrets_mobile

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * **[C]** The passkey provider's own unlock (DP-120): the app's activity on
 * the Dart entry point `passkeyMain` and an engine of its own, as
 * [AutofillUnlockActivity] is for the Autofill service. The app's unlock,
 * the vaults fetched and opened in memory, the request answered (a new
 * passkey kept in a vault first); the engine and its vaults end with the
 * activity.
 */
class PasskeyUnlockActivity : MainActivity() {
    override fun getDartEntrypointFunctionName(): String = "passkeyMain"

    override val isAutofillUnlock: Boolean get() = true

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "request" -> {
                        val r = intent.getBundleExtra(EXTRA_REQUEST) ?: Bundle()
                        result.success(
                            mapOf(
                                "kind" to r.getString("kind"),
                                "requestJson" to r.getString("requestJson"),
                                "packageName" to r.getString("packageName"),
                                "origin" to r.getString("origin"),
                                "clientDataHash" to r.getByteArray("clientDataHash"),
                                "certificates" to (r.getStringArrayList("certificates")
                                    ?: arrayListOf<String>()),
                                "credentialId" to r.getString("credentialId"),
                            ),
                        )
                    }
                    "done", "fail" -> {
                        val answer = JSONObject(call.arguments as? Map<*, *> ?: emptyMap<String, Any?>())
                        result.success(null)
                        setResult(
                            Activity.RESULT_OK,
                            Intent().putExtra(PasskeyActivity.EXTRA_ANSWER, answer.toString()),
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
        const val CHANNEL = "tom_secrets_mobile/passkey_unlock"
        const val EXTRA_REQUEST = "dev.enterpriseflutter.tom_secrets_mobile.PASSKEY_REQUEST"
    }
}
