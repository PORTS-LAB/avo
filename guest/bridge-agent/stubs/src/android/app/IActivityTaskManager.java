package android.app;

/** Compile-time stub of the hidden IActivityTaskManager. */
public interface IActivityTaskManager extends android.os.IInterface {
    void registerTaskStackListener(ITaskStackListener listener) throws android.os.RemoteException;
    void unregisterTaskStackListener(ITaskStackListener listener) throws android.os.RemoteException;
    boolean removeTask(int taskId) throws android.os.RemoteException;
}
