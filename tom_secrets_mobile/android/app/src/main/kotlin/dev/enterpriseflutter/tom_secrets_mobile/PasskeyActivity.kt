// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

package dev.enterpriseflutter.tom_secrets_mobile

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.RequiresApi
import androidx.biometric.BiometricManager.Authenticators
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.CreateCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.domerrors.DomError
import androidx.credentials.exceptions.domerrors.InvalidStateError
import androidx.credentials.exceptions.domerrors.NotAllowedError
import androidx.credentials.exceptions.domerrors.NotSupportedError
import androidx.credentials.exceptions.domerrors.UnknownError
import androidx.credentials.exceptions.publickeycredential.CreatePublicKeyCredentialDomException
import androidx.credentials.exceptions.publickeycredential.GetPublicKeyCredentialDomException
import androidx.credentials.provider.BeginGetCredentialResponse
import androidx.credentials.provider.BeginGetPublicKeyCredentialOption
import androidx.credentials.provider.CallingAppInfo
import androidx.credentials.provider.CredentialEntry
import androidx.credentials.provider.PendingIntentHandler
import androidx.credentials.provider.PublicKeyCredentialEntry
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.security.MessageDigest

/**
 * **[C]** The Credential Manager provider's answer (DP-120), a transparent
 * activity started by an entry of [TomSecretsCredentialService]:
 *
 * - **the app holds unlocked vaults**: BiometricPrompt, then the app's
 *   `passkey` answer from its memory;
 * - **otherwise**: [PasskeyUnlockActivity], the app's own unlock on an
 *   engine of its own, answers.
 *
 * It hands the app the request (WebAuthn's options, the caller's package and
 * signing certificates, the origin of a browser on the privileged-browser
 * allowlist with its client data hash) and returns the app's answer: a
 * signed sign-in, a new passkey, or the passkeys a sign-in may use. The
 * passkey identities in the answer are kept for the next listing.
 */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class PasskeyActivity : FragmentActivity() {
    private lateinit var kind: String
    private var request: Map<String, Any?> = emptyMap()
    private var beginOption: BeginGetPublicKeyCredentialOption? = null

    private val unlock =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            val answer = result.data?.getStringExtra(EXTRA_ANSWER)
            if (result.resultCode == Activity.RESULT_OK && answer != null) {
                finishWith(JSONObject(answer))
            } else {
                cancel()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) return
        kind = intent.getStringExtra(EXTRA_KIND) ?: return cancel()
        request = readRequest() ?: return cancel()
        val engine = FlutterEngineCache.getInstance().get(MainActivity.ENGINE)
        if (engine == null) return startUnlock()
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, AutofillAuthActivity.CHANNEL)
        channel.invokeMethod("state", null, object : MethodChannel.Result {
            override fun success(result: Any?) {
                if ((result as? Map<*, *>)?.get("unlocked") == true) prompt(channel) else startUnlock()
            }

            override fun error(code: String, message: String?, details: Any?) = startUnlock()
            override fun notImplemented() = startUnlock()
        })
    }

    /** The request as the app reads it (`TomSecretsPasskeyRequest.fromMap`). */
    private fun readRequest(): Map<String, Any?>? {
        val requestJson: String
        val clientDataHash: ByteArray?
        val info: CallingAppInfo
        when (kind) {
            KIND_GET -> {
                val r = PendingIntentHandler.retrieveProviderGetCredentialRequest(intent) ?: return null
                val option = r.credentialOptions.filterIsInstance<GetPublicKeyCredentialOption>()
                    .firstOrNull() ?: return null
                requestJson = option.requestJson
                clientDataHash = option.clientDataHash
                info = r.callingAppInfo
            }
            KIND_CREATE -> {
                val r = PendingIntentHandler.retrieveProviderCreateCredentialRequest(intent) ?: return null
                val create = r.callingRequest as? CreatePublicKeyCredentialRequest ?: return null
                requestJson = create.requestJson
                clientDataHash = create.clientDataHash
                info = r.callingAppInfo
            }
            KIND_ENTRIES -> {
                val r = PendingIntentHandler.retrieveBeginGetCredentialRequest(intent) ?: return null
                val option = r.beginGetCredentialOptions
                    .filterIsInstance<BeginGetPublicKeyCredentialOption>().firstOrNull() ?: return null
                beginOption = option
                requestJson = option.requestJson
                clientDataHash = null
                info = r.callingAppInfo ?: return null
            }
            else -> return null
        }
        val origin = originOf(info)
        return mapOf(
            "kind" to kind,
            "requestJson" to requestJson,
            "packageName" to info.packageName,
            "origin" to origin,
            // A browser's hash only: an app's client data is made by the app.
            "clientDataHash" to if (origin != null) clientDataHash else null,
            "certificates" to certificatesOf(info),
            "credentialId" to intent.getStringExtra(EXTRA_CREDENTIAL_ID),
        )
    }

    /**
     * The page's origin, when a browser on the privileged-browser allowlist
     * named it (res/raw/privileged_browsers.json, the list Google publishes
     * for passkey providers); null for an app, or a caller not on the list.
     */
    private fun originOf(info: CallingAppInfo): String? {
        if (!info.isOriginPopulated()) return null
        val allowlist = resources.openRawResource(R.raw.privileged_browsers)
            .bufferedReader().use { it.readText() }
        return try {
            info.getOrigin(allowlist)?.trimEnd('/')
        } catch (e: Exception) {
            null
        }
    }

    /** The caller's signing certificates, SHA-256 as Digital Asset Links write it. */
    private fun certificatesOf(info: CallingAppInfo): List<String> {
        val signing = info.signingInfo
        val signers = if (signing.hasMultipleSigners()) {
            signing.apkContentsSigners
        } else {
            signing.signingCertificateHistory
        } ?: return emptyList()
        return signers.map { s ->
            MessageDigest.getInstance("SHA-256").digest(s.toByteArray())
                .joinToString(":") { "%02X".format(it) }
        }
    }

    /** The app is unlocked: the user confirms, then the app answers. */
    private fun prompt(channel: MethodChannel) {
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(if (kind == KIND_CREATE) "Save a passkey in Tom Secrets" else "Sign in with Tom Secrets")
            .setSubtitle(PasskeyIdentities.siteOf(request["requestJson"] as String).first.ifEmpty { null })
            .setAllowedAuthenticators(Authenticators.BIOMETRIC_STRONG or Authenticators.DEVICE_CREDENTIAL)
            .build()
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                channel.invokeMethod("passkey", request, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        val answer = JSONObject(result as? Map<*, *> ?: emptyMap<String, Any?>())
                        if (answer.optBoolean("locked")) startUnlock() else finishWith(answer)
                    }

                    override fun error(code: String, message: String?, details: Any?) =
                        fail("unknown", message ?: code)

                    override fun notImplemented() = startUnlock()
                })
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) = cancel()
        }
        BiometricPrompt(this, ContextCompat.getMainExecutor(this), callback).authenticate(info)
    }

    /** The app's own unlock on an engine of its own. */
    private fun startUnlock() {
        unlock.launch(
            Intent(this, PasskeyUnlockActivity::class.java)
                .putExtra(PasskeyUnlockActivity.EXTRA_REQUEST, Bundle().apply {
                    putString("kind", kind)
                    putString("requestJson", request["requestJson"] as String?)
                    putString("packageName", request["packageName"] as String?)
                    putString("origin", request["origin"] as String?)
                    putByteArray("clientDataHash", request["clientDataHash"] as ByteArray?)
                    @Suppress("UNCHECKED_CAST")
                    putStringArrayList(
                        "certificates",
                        ArrayList(request["certificates"] as List<String>),
                    )
                    putString("credentialId", request["credentialId"] as String?)
                }),
        )
    }

    private fun finishWith(answer: JSONObject) {
        answer.optJSONArray("identities")?.let { array ->
            PasskeyIdentities.write(
                this,
                (0 until array.length()).map { i ->
                    val o = array.getJSONObject(i)
                    o.keys().asSequence().associateWith { o.opt(it) }
                },
            )
        }
        if (answer.has("error")) {
            return fail(answer.optString("error"), answer.optString("message"))
        }
        val result = Intent()
        when (kind) {
            KIND_GET -> PendingIntentHandler.setGetCredentialResponse(
                result,
                GetCredentialResponse(PublicKeyCredential(answer.getString("json"))),
            )
            KIND_CREATE -> PendingIntentHandler.setCreateCredentialResponse(
                result,
                CreatePublicKeyCredentialResponse(answer.getString("json")),
            )
            KIND_ENTRIES -> {
                val option = beginOption ?: return cancel()
                val list = answer.optJSONArray("entries")
                val entries = ArrayList<CredentialEntry>()
                for (i in 0 until (list?.length() ?: 0)) {
                    val e = list!!.getJSONObject(i)
                    val credentialId = e.optString("credentialId")
                    entries.add(
                        PublicKeyCredentialEntry.Builder(
                            this,
                            e.optString("userName").ifEmpty { e.optString("rpId") },
                            TomSecretsCredentialService.pending(
                                this,
                                credentialId.hashCode(),
                                intent(this, KIND_GET).putExtra(EXTRA_CREDENTIAL_ID, credentialId),
                            ),
                            option,
                        ).setDisplayName(e.optString("title").ifEmpty { null }).build(),
                    )
                }
                PendingIntentHandler.setBeginGetCredentialResponse(
                    result,
                    BeginGetCredentialResponse.Builder().setCredentialEntries(entries).build(),
                )
            }
        }
        setResult(Activity.RESULT_OK, result)
        finish()
    }

    /** A refusal, as WebAuthn's DOM errors name it. */
    private fun fail(error: String, message: String) {
        val dom: DomError = when (error) {
            "notAllowed" -> NotAllowedError()
            "invalidState" -> InvalidStateError()
            "notSupported" -> NotSupportedError()
            else -> UnknownError()
        }
        val result = Intent()
        if (kind == KIND_CREATE) {
            PendingIntentHandler.setCreateCredentialException(
                result,
                CreatePublicKeyCredentialDomException(dom, message),
            )
        } else {
            PendingIntentHandler.setGetCredentialException(
                result,
                GetPublicKeyCredentialDomException(dom, message),
            )
        }
        setResult(Activity.RESULT_OK, result)
        finish()
    }

    private fun cancel() {
        val result = Intent()
        when (if (::kind.isInitialized) kind else KIND_GET) {
            KIND_CREATE -> PendingIntentHandler.setCreateCredentialException(
                result,
                CreateCredentialCancellationException("cancelled"),
            )
            KIND_GET -> PendingIntentHandler.setGetCredentialException(
                result,
                GetCredentialCancellationException("cancelled"),
            )
        }
        setResult(Activity.RESULT_CANCELED, result)
        finish()
    }

    companion object {
        const val EXTRA_KIND = "dev.enterpriseflutter.tom_secrets_mobile.PASSKEY_KIND"
        const val EXTRA_CREDENTIAL_ID = "dev.enterpriseflutter.tom_secrets_mobile.CREDENTIAL_ID"
        const val EXTRA_ANSWER = "dev.enterpriseflutter.tom_secrets_mobile.PASSKEY_ANSWER"
        const val KIND_GET = "get"
        const val KIND_CREATE = "create"
        const val KIND_ENTRIES = "entries"

        fun intent(context: Context, kind: String): Intent =
            Intent(context, PasskeyActivity::class.java).putExtra(EXTRA_KIND, kind)
    }
}
