package dev.avo.clipboard;

import android.content.ComponentName;
import android.content.Context;
import android.service.notification.NotificationListenerService;
import java.lang.reflect.Method;

/**
 * Dismisses apps' notifications the way swiping them away in Android's shade
 * does (a notification listener's cancel: ongoing and no-clear ones stay, the
 * app hears of it as a dismissal):
 *
 * <pre>
 *   CLASSPATH=/data/local/tmp/avo-clipboard.jar app_process / dev.avo.clipboard.Main dismiss KEY...
 * </pre>
 *
 * It registers a listener the way {@code cmd notification snooze} does inside
 * the system server, without the user granting notification access: Android
 * allows that to the system and to holders of STATUS_BAR_SERVICE, which the
 * shell user (and root) are. Prints {@code dismissed N}.
 */
final class Dismiss {
    /** A listener that only cancels; what Android tells it is ignored. */
    public static final class Listener extends NotificationListenerService {}

    private Dismiss() {}

    static void run(String[] keys) throws Exception {
        Context context = AppInfo.systemContext();
        Listener listener = new Listener();
        Method register = NotificationListenerService.class.getMethod(
                "registerAsSystemService", Context.class, ComponentName.class, int.class);
        Method unregister = NotificationListenerService.class.getMethod("unregisterAsSystemService");
        register.invoke(listener, context, new ComponentName(context.getPackageName(), Listener.class.getName()), 0);
        try {
            listener.cancelNotifications(keys);
        } finally {
            unregister.invoke(listener);
        }
        System.out.println("dismissed " + keys.length);
    }
}
