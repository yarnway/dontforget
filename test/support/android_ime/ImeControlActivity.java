package com.yarnway.dontforget;

import android.app.Activity;
import android.os.Bundle;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.view.inputmethod.InputMethodManager;

// Private acceptance control. Never copied to the application source tree.
public class ImeControlActivity extends Activity {
  @Override public void onCreate(Bundle state) {
    super.onCreate(state);
    LinearLayout layout = new LinearLayout(this);
    layout.setOrientation(LinearLayout.VERTICAL);
    layout.setPadding(32, 140, 32, 32);
    TextView title = new TextView(this);
    title.setText("原生输入对照 · 合成验收");
    title.setTextSize(20);
    layout.addView(title);
    EditText field = new EditText(this) {
      @Override public android.view.inputmethod.InputConnection onCreateInputConnection(
          android.view.inputmethod.EditorInfo info) {
        android.view.inputmethod.InputConnection result = super.onCreateInputConnection(info);
        info.inputType = 0x28001;
        info.imeOptions = 0x2000004;
        return result;
      }
    };
    field.setHint("输入对照");
    field.setInputType(0x28001);
    field.setImeOptions(0x2000004);
    field.setMaxLines(4);
    layout.addView(field);
    setContentView(layout);
    field.requestFocus();
    field.postDelayed(() -> ((InputMethodManager)getSystemService(INPUT_METHOD_SERVICE))
      .showSoftInput(field, InputMethodManager.SHOW_IMPLICIT), 400);
  }
}
