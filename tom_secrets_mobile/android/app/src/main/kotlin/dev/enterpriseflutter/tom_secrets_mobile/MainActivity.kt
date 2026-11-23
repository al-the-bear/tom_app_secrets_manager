// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

package dev.enterpriseflutter.tom_secrets_mobile

import android.app.ActivityManager
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PersistableBundle
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.autofill.AutofillManager
import android.view.WindowManager
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The app's activity: a FlutterFragmentActivity, which the BiometricPrompt of
 * tom_biometric_storage needs; FLAG_SECURE keeps the vaults out of
 * screenshots, screen recordings and the recent-apps thumbnail.
 *
 * Its channels:
 * - `clipboard`: a copied value marked sensitive (Android 13 hides it from
 *   the clipboard preview and keyboard suggestions), cleared only while the
 *   clipboard still holds it;
 * - `documents`: a vault file picked through the Storage Access Framework,
 *   its permission persisted, read and written whole; a file picked to
 *   attach; an attachment handed to the share sheet through a FileProvider
 *   (the copy in the cache is removed at the next share and the next start);
 * - `app`: the device's physical memory (the limit a vault's Argon2 may
 *   take);
 * - `autofill` (part-os-integration, DP-175): its engine is kept in
 *   [FlutterEngineCache] while it runs, so the Autofill service's
 *   [AutofillAuthActivity] can ask the unlocked app for logins; a login the
 *   service saw submitted ([ACTION_PROPOSE]) is handed to Dart as a
 *   proposal (`takeProposal`, or pushed as `proposal`); whether the service
 *   is on, and the system's choice of the service opened; the passkey
 *   identities the Credential Manager provider lists without unlocking
 *   (`passkeyIdentities`, [PasskeyIdentities]).
 */
open class MainActivity : FlutterFragmentActivity() {
    /** The Autofill service's unlock: its own engine, no cache, no proposals. */
    protected open val isAutofillUnlock: Boolean get() = false

    private var proposal: Map<String, String>? = null
    private var autofillChannel: MethodChannel? = null
    private var pendingVault: MethodChannel.Result? = null
    private var pendingFile: MethodChannel.Result? = null

    private val openVault =
        registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            val result = pendingVault ?: return@registerForActivityResult
            pendingVault = null
            if (uri == null) {
                result.success(null)
                return@registerForActivityResult
            }
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
                result.success(mapOf("id" to uri.toString(), "name" to nameOf(uri)))
            } catch (e: SecurityException) {
                result.error("denied", "the file cannot be kept writable: ${e.message}", null)
            }
        }

    private val openFile =
        registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            val result = pendingFile ?: return@registerForActivityResult
            pendingFile = null
            if (uri == null) {
                result.success(null)
                return@registerForActivityResult
            }
            inBackground(result) {
                val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    ?: throw IllegalStateException("the file cannot be read")
                mapOf("name" to nameOf(uri), "bytes" to bytes)
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
        if (!isAutofillUnlock) {
            sharedFolder().deleteRecursively()
            proposal = proposalOf(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val p = proposalOf(intent) ?: return
        val channel = autofillChannel
        if (channel == null) {
            proposal = p
        } else {
            channel.invokeMethod("proposal", p)
        }
    }

    /** The login of an [ACTION_PROPOSE] intent (the service's onSaveRequest). */
    private fun proposalOf(intent: Intent?): Map<String, String>? {
        if (intent?.action != ACTION_PROPOSE) return null
        val password = intent.getStringExtra("password") ?: return null
        return mapOf(
            "url" to (intent.getStringExtra("url") ?: return null),
            "title" to (intent.getStringExtra("title") ?: ""),
            "userName" to (intent.getStringExtra("userName") ?: ""),
            "password" to password,
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (!isAutofillUnlock) FlutterEngineCache.getInstance().remove(ENGINE)
        autofillChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        if (!isAutofillUnlock) {
            FlutterEngineCache.getInstance().put(ENGINE, flutterEngine)
            autofillChannel = MethodChannel(messenger, AutofillAuthActivity.CHANNEL).also {
                it.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "takeProposal" -> {
                            result.success(proposal)
                            proposal = null
                        }
                        "serviceEnabled" -> result.success(
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                getSystemService(AutofillManager::class.java)
                                    ?.hasEnabledAutofillServices() == true
                            } else {
                                null
                            },
                        )
                        "openSettings" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startActivity(
                                    Intent(Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE)
                                        .setData(Uri.parse("package:$packageName")),
                                )
                            }
                            result.success(null)
                        }
                        "passkeyIdentities" -> {
                            // What the passkey provider lists without
                            // unlocking (TomSecretsCredentialService).
                            @Suppress("UNCHECKED_CAST")
                            PasskeyIdentities.write(
                                this,
                                (call.arguments as? List<Map<String, Any?>>) ?: emptyList(),
                            )
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
            }
        }
        MethodChannel(messenger, "tom_secrets_mobile/clipboard")
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
        MethodChannel(messenger, "tom_secrets_mobile/documents")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickVault" -> {
                        pendingVault = result
                        openVault.launch(arrayOf("*/*"))
                    }
                    "pickFile" -> {
                        pendingFile = result
                        openFile.launch(arrayOf("*/*"))
                    }
                    "read" -> {
                        val uri = Uri.parse(call.argument<String>("id"))
                        inBackground(result) {
                            contentResolver.openInputStream(uri)?.use { it.readBytes() }
                                ?: throw IllegalStateException("the file is gone")
                        }
                    }
                    "write" -> {
                        val uri = Uri.parse(call.argument<String>("id"))
                        val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                        inBackground(result) {
                            contentResolver.openOutputStream(uri, "wt")?.use { it.write(bytes) }
                                ?: throw IllegalStateException("the file cannot be written")
                            null
                        }
                    }
                    "share" -> {
                        val name = (call.argument<String>("name") ?: "attachment")
                            .replace(Regex("[/\\\\]"), "_")
                        val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                        val folder = sharedFolder()
                        folder.deleteRecursively()
                        folder.mkdirs()
                        val file = File(folder, name)
                        file.writeBytes(bytes)
                        val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = contentResolver.getType(uri) ?: "application/octet-stream"
                            putExtra(Intent.EXTRA_STREAM, uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(Intent.createChooser(send, name))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(messenger, "tom_secrets_mobile/app")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "physicalMemory" -> {
                        val info = ActivityManager.MemoryInfo()
                        (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager)
                            .getMemoryInfo(info)
                        result.success(info.totalMem)
                    }
                    "profileExpiry" -> result.success(null)
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        /** The cache id of the running app's engine. */
        const val ENGINE = "tom_secrets_main"

        /** The service's onSaveRequest: the app opens with the login. */
        const val ACTION_PROPOSE = "dev.enterpriseflutter.tom_secrets_mobile.PROPOSE"
    }

    /** Where an attachment waits for the app it is shared with. */
    private fun sharedFolder() = File(cacheDir, "shared")

    private fun nameOf(uri: Uri): String =
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }
            ?: uri.lastPathSegment ?: "document"

    /** Runs [work] off the main thread and answers [result] on it. */
    private fun inBackground(result: MethodChannel.Result, work: () -> Any?) {
        Thread {
            try {
                val value = work()
                runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                runOnUiThread { result.error("document", e.message, null) }
            }
        }.start()
    }
}
