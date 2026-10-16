package dev.avo.bridge.input;

import android.os.ParcelFileDescriptor;
import android.os.Process;
import android.util.Log;

import dev.avo.bridge.Bridge;
import dev.avo.bridge.Protocol;
import dev.avo.bridge.display.DisplayController;
import dev.avo.bridge.io.Vsock;

import java.io.DataInputStream;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * Input channel (vsock 6001): fixed-layout records decoded into a reused
 * buffer, so a 1000 Hz mouse never allocates on this thread.
 */
public final class InputServer {
    private static final byte[] MAGIC = {'A', 'V', 'O', 'I'};
    private final InputInjector injector;

    public InputServer(DisplayController displays) {
        injector = new InputInjector(displays);
    }

    public void start() {
        Thread thread = new Thread(this::acceptLoop, "avo-input");
        thread.setDaemon(true);
        thread.start();
    }

    private void acceptLoop() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_DISPLAY);
        while (true) {
            try (ParcelFileDescriptor listener = Vsock.listen(Protocol.PORT_INPUT)) {
                while (true) {
                    try (ParcelFileDescriptor socket = Vsock.accept(listener)) {
                        Vsock.setLowLatency(socket);
                        serve(socket);
                    } catch (IOException e) {
                        Log.i(Bridge.TAG, "input session ended: " + e.getMessage());
                    }
                    injector.cancelAll();
                }
            } catch (IOException e) {
                Log.e(Bridge.TAG, "input server error; retrying", e);
                try {
                    Thread.sleep(1000);
                } catch (InterruptedException ignored) {
                    return;
                }
            }
        }
    }

    private void serve(ParcelFileDescriptor socket) throws IOException {
        // The streams borrow the descriptor; the caller's try-with-resources closes the socket.
        DataInputStream in = new DataInputStream(new FileInputStream(socket.getFileDescriptor()));
        OutputStream out = new FileOutputStream(socket.getFileDescriptor());
        byte[] preamble = new byte[8];
        in.readFully(preamble);
        for (int i = 0; i < 4; i++) if (preamble[i] != MAGIC[i]) throw new IOException("bad input preamble");
        ByteBuffer reply = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN);
        reply.put(MAGIC).putShort((short) Protocol.INPUT_VERSION).putShort((short) 0);
        out.write(reply.array());
        out.flush();

        byte[] bytes = new byte[Protocol.INPUT_MAX_RECORD];
        ByteBuffer record = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        while (true) {
            in.readFully(bytes, 0, 8);
            int length = InputRecords.length(record);
            if (length < 8 || length > bytes.length) throw new IOException("bad input record length " + length);
            in.readFully(bytes, 8, length - 8);
            int type = InputRecords.type(record);
            if (type == InputRecords.PING) {
                out.write(bytes, 0, length); // echo for latency measurement
                out.flush();
                continue;
            }
            injector.inject(type, record, length);
        }
    }
}
