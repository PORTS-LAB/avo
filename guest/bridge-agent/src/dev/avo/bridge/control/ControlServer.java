package dev.avo.bridge.control;

import android.os.ParcelFileDescriptor;
import android.util.Log;

import dev.avo.bridge.Bridge;
import dev.avo.bridge.Protocol;
import dev.avo.bridge.io.Vsock;
import dev.avo.bridge.proto.Envelope;

/**
 * Accepts the daemon's Control connections on vsock 6000. A new connection
 * replaces the old one (the daemon reconnects after restarts and snapshot
 * restores).
 */
public final class ControlServer {
    private final Bridge bridge;
    private volatile ControlConnection current;

    public ControlServer(Bridge bridge) {
        this.bridge = bridge;
    }

    public void start() {
        Thread thread = new Thread(this::acceptLoop, "avo-control-accept");
        thread.setDaemon(true);
        thread.start();
    }

    private void acceptLoop() {
        while (true) {
            try (ParcelFileDescriptor listener = Vsock.listen(Protocol.PORT_CONTROL)) {
                while (true) {
                    ParcelFileDescriptor socket = Vsock.accept(listener);
                    ControlConnection connection = new ControlConnection(bridge, socket);
                    ControlConnection previous = current;
                    current = connection;
                    if (previous != null) previous.close();
                    connection.start();
                }
            } catch (Exception e) {
                Log.e(Bridge.TAG, "control server error; retrying", e);
                try {
                    Thread.sleep(1000);
                } catch (InterruptedException ignored) {
                    return;
                }
            }
        }
    }

    /** Sends an event on the current session, if any. */
    public void send(Envelope.Builder event) {
        ControlConnection connection = current;
        if (connection != null) connection.sendEvent(event);
    }
}
