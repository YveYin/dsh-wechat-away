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
import android.graphics.drawable.GradientDrawable;
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
import android.view.Gravity;
import android.view.View;
import android.widget.ProgressBar;
import android.widget.ImageView;
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
    private static final long WATCHDOG_WINDOW_MS = 45000L;
    private final android.os.Handler watchdogHandler = new android.os.Handler();
    private final Runnable watchdogRunnable = new Runnable() {
        @Override
        public void run() {
            watchdogTick();
        }
    };

    private WebView web;
    private View loadingOverlay;
    private boolean mainFrameFailed = false;
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
            public void onPageStarted(WebView view, String url, android.graphics.Bitmap favicon) {
                mainFrameFailed = false;
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                // 加载失败时 Chromium 也会回调 onPageFinished，此时不能撤掉遮罩，
                // 否则会露出空白 WebView（那就是之前"黑屏"的原因）。
                boolean offline = url != null && url.endsWith("offline.html");
                boolean ok = !mainFrameFailed;
                if (loadingOverlay != null && url != null && !url.startsWith("about:") && (ok || offline)) {
                    loadingOverlay.animate().alpha(0f).setDuration(180).withEndAction(new Runnable() {
                        @Override
                        public void run() {
                            if (loadingOverlay != null) {
                                loadingOverlay.setVisibility(View.GONE);
                                loadingOverlay.setAlpha(1f);
                            }
                        }
                    }).start();
                }
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (!request.isForMainFrame()) {
                    return;
                }
                mainFrameFailed = true;
                // 隧道还没起来时 WebView 会画自己那张白底错误页，用我们的遮罩盖住它。
                showLoading();
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

        loadingOverlay = buildLoadingView();
        root.addView(loadingOverlay, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        setContentView(root);

        String saved = prefs().getString(KEY_URL, "").trim();
        if (saved.isEmpty()) {
            showSettings(true);
        } else {
            retryLeft = RETRY_DELAYS_MS.length;
            showLoading();
            web.loadUrl(saved);
        }
    }

    /** 连接期的遮罩：盖住 WebView 自己的白底错误页，同时告诉用户发生了什么。 */
    private void showLoading() {
        if (loadingOverlay == null) {
            return;
        }
        loadingOverlay.setAlpha(1f);
        loadingOverlay.setVisibility(View.VISIBLE);
    }

    private View buildLoadingView() {
        float d = getResources().getDisplayMetrics().density;

        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setGravity(Gravity.CENTER);
        box.setBackgroundColor(Color.parseColor("#0B0D11"));
        box.setPadding((int) (28 * d), (int) (28 * d), (int) (28 * d), (int) (28 * d));

        // 品牌图标：圆角方块 + 矢量气泡（不依赖 emoji 字体，避免某些机器上渲染成黑白方块）
        ImageView mark = new ImageView(this);
        mark.setImageResource(R.drawable.ic_bubble);
        mark.setScaleType(ImageView.ScaleType.CENTER);
        GradientDrawable markBg = new GradientDrawable();
        markBg.setColor(Color.parseColor("#1B2230"));
        markBg.setCornerRadius(20 * d);
        mark.setBackground(markBg);
        LinearLayout.LayoutParams markLp = new LinearLayout.LayoutParams((int) (72 * d), (int) (72 * d));
        markLp.bottomMargin = (int) (20 * d);
        mark.setLayoutParams(markLp);
        box.addView(mark);

        ProgressBar bar = new ProgressBar(this);
        bar.setIndeterminate(true);
        LinearLayout.LayoutParams barLp = new LinearLayout.LayoutParams((int) (28 * d), (int) (28 * d));
        barLp.bottomMargin = (int) (16 * d);
        bar.setLayoutParams(barLp);
        box.addView(bar);

        TextView title = new TextView(this);
        title.setText("正在连接电脑…");
        title.setTextSize(16f);
        title.setTextColor(Color.parseColor("#E8ECF3"));
        title.setGravity(Gravity.CENTER);
        box.addView(title);

        TextView sub = new TextView(this);
        sub.setText("首次连接要等十几秒，连上后会自动打开");
        sub.setTextSize(13f);
        sub.setTextColor(Color.parseColor("#8D99AB"));
        sub.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams subLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        subLp.topMargin = (int) (8 * d);
        sub.setLayoutParams(subLp);
        box.addView(sub);

        return box;
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
                        showLoading();
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
                    String saved = prefs().getString(KEY_URL, "").trim();
                    if (saved.isEmpty()) {
                        showSettings(false);
                        return;
                    }
                    retryLeft = RETRY_DELAYS_MS.length;
                    showLoading();
                    web.loadUrl(saved);
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
        // Tailscale 被系统杀掉后偶尔会拒收一次 CONNECT，心跳里补发，直到隧道真的起来。
        sendVpnCommand(ACTION_CONNECT);
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
