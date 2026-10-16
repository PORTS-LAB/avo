package dev.avo.bridge;

import android.content.Context;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Process;
import android.util.Log;

import dev.avo.bridge.clip.ClipboardBridge;
import dev.avo.bridge.control.ControlServer;
import dev.avo.bridge.display.DisplayController;
import dev.avo.bridge.input.InputServer;
import dev.avo.bridge.io.Natives;
import dev.avo.bridge.notify.NotificationBridge;
import dev.avo.bridge.pkg.AppInfoFactory;
import dev.avo.bridge.pkg.PackageEvents;
import dev.avo.bridge.pkg.PackageOps;
import dev.avo.bridge.proto.Envelope;
import dev.avo.bridge.proto.Hello;

/**
 * The Bridge Agent: the single process inside Android that talks to the Mac.
 * Owns the Control and Input servers and every Android-side integration.
 */
public final class Bridge {
    public static final String TAG = "AvoBridge";
    private static volatile Bridge instance;

    public final Context context;
    /** Serial thread for framework calls that need a Looper. */
    public final Handler handler;
    public final DisplayController displays;
    public final AppInfoFactory apps;
    public final PackageOps packages;
    public final ClipboardBridge clipboard;
    private final ControlServer control;
    private final InputServer input;
    private PackageEvents packageEvents;

    private Bridge(Context context) {
        Natives.load();
        this.context = context.getApplicationContext();
        HandlerThread thread = new HandlerThread("avo-bridge", Process.THREAD_PRIORITY_FOREGROUND);
        thread.start();
        handler = new Handler(thread.getLooper());
        apps = new AppInfoFactory(this.context);
        packages = new PackageOps(this.context, handler);
        displays = new DisplayController(this);
        clipboard = new ClipboardBridge(this);
        control = new ControlServer(this);
        input = new InputServer(displays);
    }

    public static synchronized Bridge start(Context context) {
        if (instance == null) {
            instance = new Bridge(context);
            instance.startAll();
        }
        return instance;
    }

    public static Bridge get() {
        return instance;
    }

    private void startAll() {
        Log.i(TAG, "starting (protocol " + Protocol.VERSION + ", SDK " + Build.VERSION.SDK_INT + ")");
        control.start();
        input.start();
        handler.post(() -> {
            packageEvents = new PackageEvents(this);
            packageEvents.register();
            displays.watchTasks();
            clipboard.start();
            NotificationBridge.ensureEnabled(context);
        });
    }

    /** Sends a guest event to the host if a Control session is up. */
    public void send(Envelope.Builder event) {
        control.send(event);
    }

    public Hello hello() {
        return Hello.newBuilder()
                .setProtocolVersion(Protocol.VERSION)
                .setMinProtocolVersion(Protocol.MIN_VERSION)
                .setSoftwareVersion("avo-image " + Hidden.property("ro.avo.image.version", Build.DISPLAY))
                .addCapabilities("notifications")
                .addCapabilities("clipboard")
                .addCapabilities("permissions")
                .addCapabilities("share")
                .setAndroidSdk(Build.VERSION.SDK_INT)
                .setDeviceProfileId(Hidden.property("avo.boot.device_profile", "avo-virtual-device"))
                .setRooted("1".equals(Hidden.property("avo.boot.rooted", "0")))
                .build();
    }
}
