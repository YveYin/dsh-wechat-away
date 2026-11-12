package com.yueyin.wechataway;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.os.Bundle;
import android.text.InputType;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.ViewGroup;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.webkit.CookieManager;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

/**
 * 微信值守 · 手机端外壳。
 *
 * 就干一件事：把一个 WebView 钉在 电脑上的 /away 页面上，外加一个"设置服务器地址"的入口。
 * 页面本身（开始/结束/汇总/称呼）全在手机页里，这里不重复实现业务逻辑。
 */
public class MainActivity extends Activity {

    private static final String PREFS = "away";
    private static final String KEY_URL = "pageUrl";

    private WebView web;
    private FrameLayout root;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        root = new FrameLayout(this);
        root.setBackgroundColor(Color.parseColor("#0F1115"));

        web = new WebView(this);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setLoadWithOverviewMode(true);
        s.setUseWideViewPort(true);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
        s.setMediaPlaybackRequiresUserGesture(false);
        web.setBackgroundColor(Color.parseColor("#0F1115"));
        CookieManager.getInstance().setAcceptCookie(true);

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                return false;
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) {
                    view.loadUrl("file:///android_asset/offline.html");
                }
            }
        });
        web.setWebChromeClient(new WebChromeClient());
        web.addJavascriptInterface(new Bridge(), "AndroidBridge");

        root.addView(web, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        setContentView(root);

        String saved = prefs().getString(KEY_URL, "").trim();
        if (saved.isEmpty()) {
            showSettings(true);
        } else {
            web.loadUrl(saved);
        }
    }

    private SharedPreferences prefs() {
        return getSharedPreferences(PREFS, MODE_PRIVATE);
    }

    /** 设置服务器地址（页面 URL，含 ?k= 配对码）。 */
    private void showSettings(final boolean firstRun) {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        int pad = (int) (16 * getResources().getDisplayMetrics().density);
        box.setPadding(pad, pad / 2, pad, 0);

        TextView tip = new TextView(this);
        tip.setText("填电脑上「微信值守 · 手机端」的地址，例如：\nhttp://100.x.x.x:4318/away?k=你的配对码");
        tip.setTextSize(13f);
        tip.setTextColor(Color.parseColor("#9AA4B2"));
        box.addView(tip);

        final EditText input = new EditText(this);
        input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        input.setSingleLine(false);
        input.setMinLines(2);
        input.setText(prefs().getString(KEY_URL, ""));
        input.setHint("http://127.0.0.1:4318/away?k=…");
        box.addView(input);

        AlertDialog.Builder b = new AlertDialog.Builder(this)
                .setTitle(firstRun ? "先设置服务器地址" : "设置服务器地址")
                .setView(box)
                .setCancelable(!firstRun)
                .setPositiveButton("保存并打开", (d, w) -> {
                    String url = input.getText().toString().trim();
                    if (url.isEmpty()) {
                        Toast.makeText(this, "地址不能为空", Toast.LENGTH_SHORT).show();
                        return;
                    }
                    if (!url.startsWith("http://") && !url.startsWith("https://")) {
                        url = "http://" + url;
                    }
                    prefs().edit().putString(KEY_URL, url).apply();
                    web.loadUrl(url);
                })
                .setNegativeButton("取消", null);

        if (!firstRun) {
            b.setNeutralButton("重新加载", (d, w) -> web.reload());
        }
        b.show();
    }

    /** 页面里的「设置」按钮/离线页可以调到这里。 */
    private class Bridge {
        @JavascriptInterface
        public void openSettings() {
            runOnUiThread(() -> showSettings(false));
        }

        @JavascriptInterface
        public void reload() {
            runOnUiThread(() -> web.reload());
        }

        @JavascriptInterface
        public String currentUrl() {
            String u = prefs().getString(KEY_URL, "");
            return u == null ? "" : u;
        }
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK && web != null && web.canGoBack()) {
            web.goBack();
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    @Override
    protected void onDestroy() {
        if (web != null) {
            web.destroy();
            web = null;
        }
        super.onDestroy();
    }
}
