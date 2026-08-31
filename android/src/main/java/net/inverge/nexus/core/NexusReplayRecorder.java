package net.inverge.nexus.core;

import android.content.Context;

import java.util.List;

/**
 * Native session-replay recorder (Android). This is the seam the standalone Java
 * SDK (nexus-android) fills in: it should attach to the Activity's view hierarchy,
 * serialize an rrweb-compatible full snapshot, then emit incremental
 * snapshots/mutations + touch/scroll interactions, batching them to {@link BatchSink}.
 *
 * <p>For now this is a safe no-op so the plugin compiles and runs; wiring real
 * capture happens in the dedicated Java SDK.
 */
public class NexusReplayRecorder {

    /** Receives batches of rrweb-compatible events (as JSON-ish maps/lists). */
    public interface BatchSink {
        void onBatch(String recordingId, List<Object> events);
    }

    private final Context context;
    private final BatchSink sink;
    private String recordingId;
    private boolean recording;

    public NexusReplayRecorder(Context context, BatchSink sink) {
        this.context = context;
        this.sink = sink;
    }

    public void start(String recordingId) {
        this.recordingId = recordingId;
        this.recording = true;
        // TODO(nexus-android): begin capture — full snapshot + incremental events.
    }

    public void stop() {
        this.recording = false;
        // TODO(nexus-android): flush + detach capture.
    }

    public boolean isRecording() {
        return recording;
    }

    public String getRecordingId() {
        return recordingId;
    }
}
