package com.yueyin.wechataway;

import android.app.Activity;
import android.app.AlarmManager;
import android.app.AlertDialog;
import android.app.PendingIntent;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.os.Bundle;
import android.text.InputType;
import android.view.KeyEvent;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

/**
 * 微信值守 · 手机端外壳。
 *
 * 只做一件事：把一个 WebView 钉在电脑上的 /away 页面，外加一个"设置服务器地址"的入口。
 * 页面本身（开始 / 结束 / 汇总 / 称呼）全在手机页里，这里不重复实现业务逻辑。
 *
 * 注意：这里刻意不用 lambda —— 编译时用 -bootclasspath android.jar，android.jar 里没有
 * LambdaMetafactory，lambda 会直接编译失败。用匿名内部类最稳。
 */
public class MainActivity extends Activity {

    private static final String PREFS = "away";
    private static final String KEY_URL = "pageUrl";

    /** Tailscale 安卓端（com.tailscale.ipn）暴露的广播。 */
    private static final String TAILSCALE_PACKAGE = "com.tailscale.ipn";
    private static final String ACTION_CONNECT = "com.tailscale.ipn.CONNECT_VPN";
    private static final String ACTION_DISCONNECT = "com.tailscale.ipn.DISCONNECT_VPN";

    /** 看门狗节奏：每 5 秒续一次，闹钟本身设 15 秒后。 */
    private static final long WATCHDOG_TICK_MS = 5000L;
    private static final long WATCHDOG_WINDOW_MS = 15000L;
    private final android.os.Handler watchdogHandler = new android.os.Handler();
    private final Runnable watchdogRunnable = new Runnable() {
        @Override
        public void run() {
            watchdogTick();
        }
    };

    private WebView web;
    private int retryLeft = 0;

    /** 隧道建立要十几秒，页面加载失败时按退避重试几次，别一上来就甩错误页。 */
    private static final int[] RETRY_DELAYS_MS = {3000, 4000, 5000, 6000};

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        FrameLayout root = new FrameLayout(this);
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
                if (!request.isForMainFrame()) {
                    return;
                }
                int index = RETRY_DELAYS_MS.length - retryLeft;
                if (retryLeft > 0 && index >= 0 && index < RETRY_DELAYS_MS.length) {
                    retryLeft--;
                    final int delay = RETRY_DELAYS_MS[index];
                    view.postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            if (web != null) {
                                web.reload();
                            }
                        }
                    }, delay);
                    return;
                }
                view.loadUrl("file:///android_asset/offline.html");
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
                .setPositiveButton("保存并打开", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        String url = input.getText().toString().trim();
                        if (url.isEmpty()) {
                            Toast.makeText(MainActivity.this, "地址不能为空", Toast.LENGTH_SHORT).show();
                            return;
                        }
                        if (!url.startsWith("http://") && !url.startsWith("https://")) {
                            url = "http://" + url;
                        }
                        prefs().edit().putString(KEY_URL, url).apply();
                        web.loadUrl(url);
                    }
                })
                .setNegativeButton("取消", null);

        if (!firstRun) {
            b.setNeutralButton("重新加载", new DialogInterface.OnClickListener() {
                @Override
                public void onClick(DialogInterface dialog, int which) {
                    web.reload();
                }
            });
        }
        b.show();
    }

    /** 页面里的「设置」按钮 / 离线页可以调到这里。 */
    private class Bridge {
        @JavascriptInterface
        public void openSettings() {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    showSettings(false);
                }
            });
        }

        @JavascriptInterface
        public void reload() {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    web.reload();
                }
            });
        }

        @JavascriptInterface
        public String currentUrl() {
            String u = prefs().getString(KEY_URL, "");
            return u == null ? "" : u;
        }
    }

    @Override
    protected void onStart() {
        super.onStart();
        // 打开 App 才连 VPN：Tailscale 的 IPNReceiver 是 exported 的，允许外部广播。
        boolean started = sendVpnCommand(ACTION_CONNECT);
        if (started && web != null) {
            // 第一次加载可能赶上隧道还没起来，给几次重试机会。
            retryLeft = RETRY_DELAYS_MS.length;
            web.postDelayed(new Runnable() {
                @Override
                public void run() {
                    if (web != null) {
                        web.reload();
                    }
                }
            }, 2500);
        }
        startWatchdog();
    }

    @Override
    protected void onStop() {
        super.onStop();
        stopWatchdog();
        // 离开 App 就断开，避免 VPN 常驻耗电。
        sendVpnCommand(ACTION_DISCONNECT);
    }

    /**
     * 看门狗：只要 App 还活着就每 5 秒把"断连闹钟"推到 15 秒后。
     * 进程被划掉 / 被杀，最后一次闹钟到点就断开 VPN —— 这样即使 onStop 没跑，
     * VPN 最多也只多活十几秒。
     */
    private void startWatchdog() {
        stopWatchdog();
        watchdogTick();
    }

    private void watchdogTick() {
        alarmManager().cancel(disconnectIntent());
        alarmManager().set(AlarmManager.RTC_WAKEUP,
                System.currentTimeMillis() + WATCHDOG_WINDOW_MS, disconnectIntent());
        watchdogHandler.removeCallbacks(watchdogRunnable);
        watchdogHandler.postDelayed(watchdogRunnable, WATCHDOG_TICK_MS);
    }

    private void stopWatchdog() {
        watchdogHandler.removeCallbacks(watchdogRunnable);
        alarmManager().cancel(disconnectIntent());
    }

    private AlarmManager alarmManager() {
        return (AlarmManager) getSystemService(Context.ALARM_SERVICE);
    }

    private PendingIntent disconnectIntent() {
        Intent intent = new Intent(this, DisconnectReceiver.class);
        return PendingIntent.getBroadcast(this, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    /** 给 Tailscale 发连接/断开广播；没装就静默失败。 */
    private boolean sendVpnCommand(String action) {
        try {
            Intent intent = new Intent(action);
            intent.setPackage(TAILSCALE_PACKAGE);
            sendBroadcast(intent);
            return true;
        } catch (Throwable ignored) {
            return false;
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
