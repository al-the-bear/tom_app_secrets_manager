// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

package dev.enterpriseflutter.tom_secrets_mobile

import android.app.PendingIntent
import android.app.slice.Slice
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.os.CancellationSignal
import android.service.autofill.AutofillService
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.InlinePresentation
import android.service.autofill.SaveCallback
import android.service.autofill.SaveInfo
import android.service.autofill.SaveRequest
import androidx.annotation.RequiresApi
import androidx.autofill.inline.UiVersions
import androidx.autofill.inline.v1.InlineSuggestionUi

/**
 * The Android Autofill service (part-os-integration, DP-175). Nothing is
 * stored unencrypted (DP-50), so a request is answered at once with one
 * locked response, "Unlock Tom Secrets Manager" (also as an inline
 * suggestion in the keyboard on Android 11+). Choosing it starts
 * [AutofillAuthActivity], which answers from the running app's memory after
 * BiometricPrompt, or has the app fetch and unlock the vaults itself. A
 * submitted login is handed to the app as a proposal ([onSaveRequest]).
 */
@RequiresApi(Build.VERSION_CODES.O)
class TomSecretsAutofillService : AutofillService() {
    override fun onFillRequest(
        request: FillRequest,
        cancellationSignal: CancellationSignal,
        callback: FillCallback,
    ) {
        val structure = request.fillContexts.last().structure
        val fields = AutofillFields.of(structure)
        // Its own screens are never filled.
        if (fields.ids.isEmpty() || fields.packageName == packageName) {
            callback.onSuccess(null)
            return
        }
        val certificates = if (fields.webDomain == null) {
            AutofillFields.certificates(this, fields.packageName)
        } else {
            emptyList()
        }
        val intent = Intent(this, AutofillAuthActivity::class.java)
            .putExtras(fields.requestBundle(certificates))
        val sender = PendingIntent.getActivity(
            this,
            REQUEST_UNLOCK,
            intent,
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_MUTABLE,
        ).intentSender
        val presentation = AutofillFields.line(this, "Unlock Tom Secrets Manager")
        val response = FillResponse.Builder()
        val inline = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            inlinePresentation(request, sender)
        } else {
            null
        }
        if (inline != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            response.setAuthentication(fields.ids.toTypedArray(), sender, presentation, inline)
        } else {
            response.setAuthentication(fields.ids.toTypedArray(), sender, presentation)
        }
        saveInfo(fields)?.let { response.setSaveInfo(it) }
        callback.onSuccess(response.build())
    }

    /** The keyboard's chip (Android 11+), when the keyboard asks for one. */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun inlinePresentation(
        request: FillRequest,
        sender: android.content.IntentSender,
    ): InlinePresentation? {
        val specs = request.inlineSuggestionsRequest?.inlinePresentationSpecs
        val spec = specs?.firstOrNull() ?: return null
        if (!UiVersions.getVersions(spec.style).contains(UiVersions.INLINE_UI_VERSION_1)) return null
        val attribution = PendingIntent.getActivity(
            this,
            REQUEST_ATTRIBUTION,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val slice: Slice = InlineSuggestionUi.newContentBuilder(attribution)
            .setTitle("Unlock Tom Secrets Manager")
            .setStartIcon(Icon.createWithResource(this, R.mipmap.ic_launcher))
            .build()
            .slice
        return InlinePresentation(slice, spec, false)
    }

    private fun saveInfo(fields: AutofillFields): SaveInfo? {
        val password = fields.password ?: return null
        return if (fields.user != null) {
            SaveInfo.Builder(
                SaveInfo.SAVE_DATA_TYPE_USERNAME or SaveInfo.SAVE_DATA_TYPE_PASSWORD,
                arrayOf(fields.user, password),
            ).build()
        } else {
            SaveInfo.Builder(SaveInfo.SAVE_DATA_TYPE_PASSWORD, arrayOf(password)).build()
        }
    }

    /**
     * A submitted login: the app opens with it as a proposal (the Proposals
     * screen saves it into a personal or shared vault once the user
     * confirms, BP-28). Nothing is kept here.
     */
    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        val fields = AutofillFields.of(request.fillContexts.last().structure)
        val password = fields.passwordText
        if (password.isNullOrEmpty()) {
            callback.onSuccess()
            return
        }
        val url = fields.webDomain?.let { "${fields.webScheme ?: "https"}://$it/" }
            ?: "androidapp://${fields.packageName}"
        val title = fields.webDomain ?: appLabel(fields.packageName)
        val intent = Intent(this, MainActivity::class.java)
            .setAction(MainActivity.ACTION_PROPOSE)
            .putExtra("url", url)
            .putExtra("title", title)
            .putExtra("userName", fields.userText ?: "")
            .putExtra("password", password)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val sender = PendingIntent.getActivity(
                this,
                REQUEST_PROPOSE,
                intent,
                PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ).intentSender
            callback.onSuccess(sender)
        } else {
            startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            callback.onSuccess()
        }
    }

    private fun appLabel(packageName: String): String = try {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(packageName, 0))
            .toString()
    } catch (e: Exception) {
        packageName
    }

    companion object {
        private const val REQUEST_UNLOCK = 4101
        private const val REQUEST_ATTRIBUTION = 4102
        private const val REQUEST_PROPOSE = 4103
    }
}
