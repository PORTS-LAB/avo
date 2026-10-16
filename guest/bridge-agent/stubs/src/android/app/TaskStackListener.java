package android.app;

import android.content.ComponentName;

/**
 * Compile-time stub of the hidden TaskStackListener (frameworks/base/core/java/
 * android/app/TaskStackListener.java). Only the callbacks the Bridge Agent
 * overrides are declared; their signatures match AOSP 14–16.
 */
public abstract class TaskStackListener extends ITaskStackListener.Stub {
    public TaskStackListener() {}
    public void onTaskCreated(int taskId, ComponentName componentName) {}
    public void onTaskRemoved(int taskId) {}
    public void onTaskMovedToFront(ActivityManager.RunningTaskInfo taskInfo) {}
    public void onTaskDescriptionChanged(ActivityManager.RunningTaskInfo taskInfo) {}
    public void onTaskRequestedOrientationChanged(int taskId, int requestedOrientation) {}
    public void onTaskDisplayChanged(int taskId, int newDisplayId) {}
}
