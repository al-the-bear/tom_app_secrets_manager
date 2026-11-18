// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

package dev.enterpriseflutter.tom_secrets_mobile

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.PersistableBundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The app's activity: a FlutterFragmentActivity, which the BiometricPrompt of
 * tom_biometric_storage needs; FLAG_SECURE keeps the vaults out of
 * screenshots, screen recordings and the recent-apps thumbnail; the
 * clipboard channel marks a copied value sensitive (Android 13 hides it from
 * the clipboard preview and keyboard suggestions) and clears it only while
 * the clipboard still holds it.
 */
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                val clipboard =
                    getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                when (call.method) {
                    "place" -> {
                        val text = call.argument<String>("text") ?: ""
                        val clip = ClipData.newPlainText("Tom Secrets", text)
                        val extras = PersistableBundle()
                        extras.putBoolean(
                            if (Build.VERSION.SDK_INT >= 33) {
                                ClipDescription.EXTRA_IS_SENSITIVE
                            } else {
                                "android.content.extra.IS_SENSITIVE"
                            },
                            true,
                        )
                        clip.description.extras = extras
                        clipboard.setPrimaryClip(clip)
                        result.success(null)
                    }
                    "clear" -> {
                        val text = call.argument<String>("text") ?: ""
                        val held = clipboard.primaryClip
                            ?.takeIf { it.itemCount > 0 }
                            ?.getItemAt(0)?.coerceToText(this)?.toString()
                        if (held != text) {
                            result.success(false)
                        } else {
                            if (Build.VERSION.SDK_INT >= 28) {
                                clipboard.clearPrimaryClip()
                            } else {
                                clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
                            }
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private companion object {
        const val CHANNEL = "tom_secrets_mobile/clipboard"
    }
}
