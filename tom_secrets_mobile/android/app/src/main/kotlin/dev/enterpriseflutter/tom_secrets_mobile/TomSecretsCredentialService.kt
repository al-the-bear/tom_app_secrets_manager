// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

package dev.enterpriseflutter.tom_secrets_mobile

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.CancellationSignal
import android.os.OutcomeReceiver
import androidx.annotation.RequiresApi
import androidx.credentials.exceptions.ClearCredentialException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.CreateCredentialUnsupportedException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.provider.AuthenticationAction
import androidx.credentials.provider.BeginCreateCredentialRequest
import androidx.credentials.provider.BeginCreateCredentialResponse
import androidx.credentials.provider.BeginCreatePublicKeyCredentialRequest
import androidx.credentials.provider.BeginGetCredentialRequest
import androidx.credentials.provider.BeginGetCredentialResponse
import androidx.credentials.provider.BeginGetPublicKeyCredentialOption
import androidx.credentials.provider.CreateEntry
import androidx.credentials.provider.CredentialEntry
import androidx.credentials.provider.CredentialProviderService
import androidx.credentials.provider.ProviderClearCredentialStateRequest
import androidx.credentials.provider.PublicKeyCredentialEntry
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * **[C]** The Credential Manager provider (part-os-integration, DP-120,
 * Android 14+): passkeys of the personal and shared vaults.
 *
 * - **A sign-in** is listed at once from the passkey identities the app
 *   hands over after every unlock and change ([PasskeyIdentities]: the
 *   relying party, user name and credential id, never a key); the entry
 *   picked opens [PasskeyActivity], which answers after BiometricPrompt from
 *   the running app or from the app's own unlock. A site with no identity
 *   here gets "Unlock Tom Secrets" instead (its passkeys listed after the
 *   unlock).
 * - **A new passkey** offers Tom Secrets as the place to keep it; the
 *   activity makes it and the app keeps it in a vault.
 *
 * The service itself holds nothing secret and answers nothing secret.
 */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class TomSecretsCredentialService : CredentialProviderService() {
    override fun onBeginGetCredentialRequest(
        request: BeginGetCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<BeginGetCredentialResponse, GetCredentialException>,
    ) {
        val identities = PasskeyIdentities.read(this)
        val entries = ArrayList<CredentialEntry>()
        var unknownSite = false
        for (option in request.beginGetCredentialOptions) {
            if (option !is BeginGetPublicKeyCredentialOption) continue
            val (rpId, allowed) = PasskeyIdentities.siteOf(option.requestJson)
            val matching = identities.filter {
                it.optString("rpId") == rpId &&
                    (allowed.isEmpty() || allowed.contains(it.optString("credentialId")))
            }
            if (matching.isEmpty()) unknownSite = true
            for (identity in matching) {
                val credentialId = identity.optString("credentialId")
                val intent = PasskeyActivity.intent(this, PasskeyActivity.KIND_GET)
                    .putExtra(PasskeyActivity.EXTRA_CREDENTIAL_ID, credentialId)
                entries.add(
                    PublicKeyCredentialEntry.Builder(
                        this,
                        identity.optString("userName").ifEmpty { rpId },
                        pending(this, credentialId.hashCode(), intent),
                        option,
                    ).setDisplayName(identity.optString("title").ifEmpty { null }).build(),
                )
            }
        }
        val response = BeginGetCredentialResponse.Builder().setCredentialEntries(entries)
        if (unknownSite) {
            // Passkeys made on another device since this one last unlocked.
            response.setAuthenticationActions(
                listOf(
                    AuthenticationAction(
                        "Unlock Tom Secrets",
                        pending(
                            this,
                            REQUEST_ENTRIES,
                            PasskeyActivity.intent(this, PasskeyActivity.KIND_ENTRIES),
                        ),
                    ),
                ),
            )
        }
        callback.onResult(response.build())
    }

    override fun onBeginCreateCredentialRequest(
        request: BeginCreateCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<BeginCreateCredentialResponse, CreateCredentialException>,
    ) {
        if (request !is BeginCreatePublicKeyCredentialRequest) {
            callback.onError(CreateCredentialUnsupportedException("passkeys only"))
            return
        }
        callback.onResult(
            BeginCreateCredentialResponse.Builder()
                .setCreateEntries(
                    listOf(
                        CreateEntry.Builder(
                            "Tom Secrets",
                            pending(
                                this,
                                REQUEST_CREATE,
                                PasskeyActivity.intent(this, PasskeyActivity.KIND_CREATE),
                            ),
                        ).setDescription("Saved in your Tom Secrets vaults").build(),
                    ),
                )
                .build(),
        )
    }

    override fun onClearCredentialStateRequest(
        request: ProviderClearCredentialStateRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<Void?, ClearCredentialException>,
    ) {
        // Nothing is remembered between requests.
        callback.onResult(null)
    }

    companion object {
        private const val REQUEST_CREATE = 1
        private const val REQUEST_ENTRIES = 2

        fun pending(context: Context, code: Int, intent: Intent): PendingIntent =
            PendingIntent.getActivity(
                context,
                code,
                intent,
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
    }
}

/**
 * The passkey identities the provider lists without unlocking, in the
 * app's no-backup files: the relying party, user name, title and
 * credential id of each passkey of the personal and shared vaults, written
 * by the app after every unlock and change, emptied when the device is set
 * up again.
 */
object PasskeyIdentities {
    private const val FILE = "passkey-identities.json"

    private fun file(context: Context) = File(context.noBackupFilesDir, FILE)

    fun write(context: Context, identities: List<Map<String, Any?>>) {
        val array = JSONArray()
        for (identity in identities) {
            val o = JSONObject()
            for (key in listOf("entryId", "title", "rpId", "credentialId", "userName")) {
                (identity[key] as? String)?.let { o.put(key, it) }
            }
            array.put(o)
        }
        file(context).writeText(array.toString())
    }

    fun read(context: Context): List<JSONObject> = try {
        val array = JSONArray(file(context).readText())
        (0 until array.length()).map { array.getJSONObject(it) }
    } catch (e: Exception) {
        emptyList()
    }

    /** The relying party and allowed credential ids (base64url) of a sign-in. */
    fun siteOf(requestJson: String): Pair<String, Set<String>> {
        val o = try {
            JSONObject(requestJson)
        } catch (e: Exception) {
            JSONObject()
        }
        val allowed = HashSet<String>()
        val list = o.optJSONArray("allowCredentials")
        if (list != null) {
            for (i in 0 until list.length()) {
                list.optJSONObject(i)?.optString("id")?.takeIf { it.isNotEmpty() }?.let {
                    allowed.add(it.trimEnd('=').replace('+', '-').replace('/', '_'))
                }
            }
        }
        return o.optString("rpId").lowercase() to allowed
    }
}
