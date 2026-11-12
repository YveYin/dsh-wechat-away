package com.yueyin.wechataway;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * 兜底：App 如果被从最近任务里划掉 / 被系统杀掉，onStop 可能不执行，
 * VPN 就会一直挂着。MainActivity 在运行期间会不断把"断连闹钟"往后推，
 * 一旦进程没了，最后一次闹钟就会到点把 VPN 断掉。
 */
public class DisconnectReceiver extends BroadcastReceiver {

    static final String ACTION_DISCONNECT_VPN = "com.tailscale.ipn.DISCONNECT_VPN";
    static final String TAILSCALE_PACKAGE = "com.tailscale.ipn";

    @Override
    public void onReceive(Context context, Intent intent) {
        try {
            Intent out = new Intent(ACTION_DISCONNECT_VPN);
            out.setPackage(TAILSCALE_PACKAGE);
            context.sendBroadcast(out);
        } catch (Throwable ignored) {
            // Tailscale 不在就算了，别无谓崩溃。
        }
    }
}
