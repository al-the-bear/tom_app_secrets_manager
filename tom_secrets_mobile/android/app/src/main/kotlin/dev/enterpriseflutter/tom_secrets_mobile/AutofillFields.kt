// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

package dev.enterpriseflutter.tom_secrets_mobile

import android.annotation.SuppressLint
import android.app.assist.AssistStructure
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.service.autofill.Dataset
import android.service.autofill.FillResponse
import android.text.InputType
import android.view.View
import android.view.autofill.AutofillId
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import androidx.annotation.RequiresApi
import java.security.MessageDigest

/**
 * The login fields of an autofill request (part-os-integration): the user
 * name and the password (from their autofill hints, else their input types,
 * else their ids), the requesting app's package, and a browser page's web
 * domain and scheme.
 */
@RequiresApi(Build.VERSION_CODES.O)
data class AutofillFields(
    val user: AutofillId?,
    val password: AutofillId?,
    val packageName: String,
    val webDomain: String?,
    val webScheme: String?,
    val userText: String?,
    val passwordText: String?,
) {
    val ids: List<AutofillId> get() = listOfNotNull(user, password)

    /** The request as the Dart side reads it (`TomSecretsAutofillRequest`). */
    fun requestBundle(certificates: List<String>): Bundle = Bundle().apply {
        putString(KEY_PACKAGE, packageName)
        putString(KEY_WEB_DOMAIN, webDomain)
        putString(KEY_WEB_SCHEME, webScheme)
        putStringArrayList(KEY_CERTIFICATES, ArrayList(certificates))
    }

    companion object {
        const val KEY_PACKAGE = "packageName"
        const val KEY_WEB_DOMAIN = "webDomain"
        const val KEY_WEB_SCHEME = "webScheme"
        const val KEY_CERTIFICATES = "certificates"

        private val userHints = setOf(
            View.AUTOFILL_HINT_USERNAME,
            View.AUTOFILL_HINT_EMAIL_ADDRESS,
            "email",
            "user",
        )
        private val userIds = Regex("user|login|email|e-mail|account|ident", RegexOption.IGNORE_CASE)

        fun of(structure: AssistStructure): AutofillFields {
            var user: AssistStructure.ViewNode? = null
            var password: AssistStructure.ViewNode? = null
            var guessedUser: AssistStructure.ViewNode? = null
            var webDomain: String? = null
            var webScheme: String? = null
            fun walk(node: AssistStructure.ViewNode) {
                if (webDomain == null && !node.webDomain.isNullOrEmpty()) {
                    webDomain = node.webDomain
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) webScheme = node.webScheme
                }
                val hints = node.autofillHints?.map { it.lowercase() } ?: emptyList()
                val variation = node.inputType and InputType.TYPE_MASK_VARIATION
                val isPassword = hints.contains(View.AUTOFILL_HINT_PASSWORD.lowercase()) ||
                    (node.inputType and InputType.TYPE_MASK_CLASS) == InputType.TYPE_CLASS_TEXT &&
                    (variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                        variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ||
                        variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD) ||
                    node.htmlInfo?.attributes?.any { it.first == "type" && it.second == "password" } == true
                val newPassword = hints.any { it.contains("new") && it.contains("password") }
                if (node.autofillId != null) {
                    when {
                        isPassword && !newPassword -> if (password == null) password = node
                        hints.any { it in userHints } -> if (user == null) user = node
                        guessedUser == null && password == null &&
                            (variation == InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS ||
                                userIds.containsMatchIn(node.idEntry ?: "") ||
                                userIds.containsMatchIn(node.hint ?: "")) -> guessedUser = node
                    }
                }
                for (i in 0 until node.childCount) walk(node.getChildAt(i))
            }
            for (i in 0 until structure.windowNodeCount) walk(structure.getWindowNodeAt(i).rootViewNode)
            val userNode = user ?: guessedUser
            return AutofillFields(
                user = userNode?.autofillId,
                password = password?.autofillId,
                packageName = structure.activityComponent.packageName,
                webDomain = webDomain,
                webScheme = webScheme,
                userText = userNode?.autofillValue?.takeIf { it.isText }?.textValue?.toString(),
                passwordText = password?.autofillValue?.takeIf { it.isText }?.textValue?.toString(),
            )
        }

        /**
         * The SHA-256 fingerprints of [packageName]'s signing certificates,
         * upper-case hex with colons (as Digital Asset Links write them);
         * empty when the package cannot be seen.
         */
        @SuppressLint("PackageManagerGetSignatures")
        @Suppress("DEPRECATION")
        fun certificates(context: Context, packageName: String): List<String> = try {
            val pm = context.packageManager
            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val info = pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                info.signingInfo?.apkContentsSigners?.toList() ?: emptyList()
            } else {
                pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES).signatures?.toList()
                    ?: emptyList()
            }
            signatures.map { sig ->
                MessageDigest.getInstance("SHA-256").digest(sig.toByteArray())
                    .joinToString(":") { "%02X".format(it) }
            }
        } catch (e: Exception) {
            emptyList()
        }

        /** One line of the dataset list. */
        fun line(context: Context, text: String): RemoteViews =
            RemoteViews(context.packageName, android.R.layout.simple_list_item_1).apply {
                setTextViewText(android.R.id.text1, text)
            }

        /**
         * The logins (`label`, `userName`, `password` bundles) as the filled
         * datasets of [fields]; null when there are none.
         */
        fun response(context: Context, fields: AutofillFields, logins: List<Bundle>): FillResponse? {
            if (logins.isEmpty() || fields.ids.isEmpty()) return null
            val builder = FillResponse.Builder()
            for (login in logins) {
                val dataset = Dataset.Builder(line(context, login.getString("label") ?: ""))
                fields.user?.let {
                    dataset.setValue(it, AutofillValue.forText(login.getString("userName") ?: ""))
                }
                fields.password?.let {
                    dataset.setValue(it, AutofillValue.forText(login.getString("password") ?: ""))
                }
                builder.addDataset(dataset.build())
            }
            return builder.build()
        }
    }
}
