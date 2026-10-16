package dev.avo.bridge.notify;

import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.ComponentName;
import android.content.Context;
import android.graphics.drawable.Icon;
import android.os.Bundle;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;
import android.util.Log;

import com.google.protobuf.ByteString;

import dev.avo.bridge.Bridge;
import dev.avo.bridge.Hidden;
import dev.avo.bridge.proto.Envelope;
import dev.avo.bridge.proto.NotificationRemoved;

/**
 * Mirrors Android notifications to macOS Notification Center (spec: "Fitur
 * native tambahan"). Clicking one on the Mac opens the app's window and fires
 * the notification's content intent on that display.
 */
public final class NotificationBridge extends NotificationListenerService {
    private static volatile NotificationBridge active;

    /** The agent grants itself listener access (it is a privileged app). */
    public static void ensureEnabled(Context context) {
        ComponentName component = new ComponentName(context, NotificationBridge.class);
        Hidden.call(context.getSystemService(NotificationManager.class), "setNotificationListenerAccessGranted",
                new Class<?>[]{ComponentName.class, boolean.class}, component, true);
    }

    @Override
    public void onListenerConnected() {
        active = this;
    }

    @Override
    public void onListenerDisconnected() {
        active = null;
    }

    @Override
    public void onNotificationPosted(StatusBarNotification sbn) {
        Notification notification = sbn.getNotification();
        if ((notification.flags & Notification.FLAG_GROUP_SUMMARY) != 0) return; // the Mac groups by app itself
        Bundle extras = notification.extras;
        CharSequence title = extras.getCharSequence(Notification.EXTRA_TITLE);
        CharSequence text = extras.getCharSequence(Notification.EXTRA_BIG_TEXT);
        if (text == null) text = extras.getCharSequence(Notification.EXTRA_TEXT);
        if (title == null && text == null) return;

        dev.avo.bridge.proto.Notification.Builder message = dev.avo.bridge.proto.Notification.newBuilder()
                .setPackage(sbn.getPackageName())
                .setKey(sbn.getKey())
                .setTitle(title == null ? "" : title.toString())
                .setBody(text == null ? "" : text.toString())
                .setPostedAtMs(sbn.getPostTime())
                .setOngoing(sbn.isOngoing())
                // Progress updates and the like ask to alert only once: keep them quiet on the Mac.
                .setSilent((notification.flags & Notification.FLAG_ONLY_ALERT_ONCE) != 0);
        if (notification.getGroup() != null) message.setGroup(notification.getGroup());
        Icon large = notification.getLargeIcon();
        if (large != null) {
            try {
                message.setLargeIconPng(png(large));
            } catch (RuntimeException e) {
                Log.d(Bridge.TAG, "large icon unavailable", e);
            }
        }
        Bridge bridge = Bridge.get();
        if (bridge != null) bridge.send(Envelope.newBuilder().setNotification(message));
    }

    @Override
    public void onNotificationRemoved(StatusBarNotification sbn) {
        Bridge bridge = Bridge.get();
        if (bridge != null) {
            bridge.send(Envelope.newBuilder().setNotificationRemoved(NotificationRemoved.newBuilder().setKey(sbn.getKey())));
        }
    }

    private ByteString png(Icon icon) {
        android.graphics.drawable.Drawable drawable = icon.loadDrawable(this);
        if (drawable == null) return ByteString.EMPTY;
        return dev.avo.bridge.pkg.AppInfoFactory.pngOf(drawable, 128);
    }

    /** The content intent of an active notification (for Launch with a notification key). */
    public static PendingIntent contentIntent(String key) {
        NotificationBridge listener = active;
        if (listener == null) return null;
        StatusBarNotification[] matches = listener.getActiveNotifications(new String[]{key});
        if (matches == null || matches.length == 0) return null;
        Notification notification = matches[0].getNotification();
        if ((notification.flags & Notification.FLAG_AUTO_CANCEL) != 0) listener.cancelNotification(key);
        return notification.contentIntent;
    }

    public static void open(String key, int displayId) throws PendingIntent.CanceledException {
        PendingIntent intent = contentIntent(key);
        if (intent == null) throw new IllegalArgumentException("notification is gone");
        intent.send();
    }

    public static void dismiss(String key) {
        NotificationBridge listener = active;
        if (listener != null) listener.cancelNotification(key);
    }
}
