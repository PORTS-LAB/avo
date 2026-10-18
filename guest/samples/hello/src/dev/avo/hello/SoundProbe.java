package dev.avo.hello;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * Plays the test tone without a window, for checking sound from adb:
 * {@code adb shell am broadcast -n dev.avo.hello/.SoundProbe}.
 */
public final class SoundProbe extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        AudioCheck.playTone();
    }
}
