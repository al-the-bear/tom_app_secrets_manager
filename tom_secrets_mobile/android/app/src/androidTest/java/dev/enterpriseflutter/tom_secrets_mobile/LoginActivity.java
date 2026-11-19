// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

package dev.enterpriseflutter.tom_secrets_mobile;

import android.app.Activity;
import android.os.Bundle;
import android.text.InputType;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;

/**
 * A login form in the test APK's package, which runs in a process of its
 * own (no Kotlin runtime there, so Java). "Sign in" ends the activity, which
 * commits the autofill session (the save request).
 */
public class LoginActivity extends Activity {
  @Override
  protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    EditText user = new EditText(this);
    user.setAutofillHints(View.AUTOFILL_HINT_USERNAME);
    user.setContentDescription("demo-user-field");
    EditText password = new EditText(this);
    password.setAutofillHints(View.AUTOFILL_HINT_PASSWORD);
    password.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
    password.setContentDescription("demo-password-field");
    Button signIn = new Button(this);
    signIn.setText("Sign in");
    signIn.setOnClickListener(v -> finish());
    LinearLayout layout = new LinearLayout(this);
    layout.setOrientation(LinearLayout.VERTICAL);
    layout.addView(user);
    layout.addView(password);
    layout.addView(signIn);
    setContentView(layout);
  }
}
