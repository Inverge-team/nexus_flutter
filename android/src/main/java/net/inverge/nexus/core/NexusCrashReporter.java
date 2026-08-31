package net.inverge.nexus.core;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;

/**
 * Catches uncaught JVM exceptions (main + background threads), persists them to
 * disk, and returns them on the next launch — because a crashing process can't
 * reliably make a network call. The Flutter SDK forwards them to Nexus on start.
 */
public class NexusCrashReporter {

    private static final String FILE = "nexus_crashes.log"; // one JSON object per line

    private final Context context;
    private Thread.UncaughtExceptionHandler previous;
    private boolean installed;

    public NexusCrashReporter(Context context) {
        this.context = context.getApplicationContext();
    }

    public synchronized void install() {
        if (installed) return;
        installed = true;
        previous = Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler((thread, throwable) -> {
            try {
                persist(throwable);
            } catch (Throwable ignore) {
                // never let the reporter mask the original crash
            }
            if (previous != null) previous.uncaughtException(thread, throwable);
        });
    }

    private void persist(Throwable t) throws Exception {
        final JSONObject o = new JSONObject();
        o.put("type", t.getClass().getName());
        o.put("message", String.valueOf(t.getMessage()));
        o.put("platform", "android");
        o.put("timestamp", System.currentTimeMillis());

        final JSONArray frames = new JSONArray();
        Throwable cur = t;
        while (cur != null) {
            if (cur != t) frames.put("Caused by: " + cur.getClass().getName() + ": " + cur.getMessage());
            for (StackTraceElement el : cur.getStackTrace()) {
                final JSONObject f = new JSONObject();
                f.put("function", el.getClassName() + "." + el.getMethodName());
                f.put("filename", el.getFileName());
                f.put("lineno", el.getLineNumber());
                frames.put(f);
            }
            cur = cur.getCause();
        }
        o.put("stack", frames);

        final File file = new File(context.getFilesDir(), FILE);
        try (FileWriter w = new FileWriter(file, true)) {
            w.write(o.toString());
            w.write("\n");
        }
    }

    public synchronized List<Map<String, Object>> takePending() {
        final List<Map<String, Object>> out = new ArrayList<>();
        final File file = new File(context.getFilesDir(), FILE);
        if (!file.exists()) return out;
        try (BufferedReader r = new BufferedReader(new FileReader(file))) {
            String line;
            while ((line = r.readLine()) != null) {
                if (line.trim().isEmpty()) continue;
                try {
                    out.add(toMap(new JSONObject(line)));
                } catch (Exception ignore) {
                }
            }
        } catch (Exception ignore) {
        }
        file.delete();
        return out;
    }

    private Map<String, Object> toMap(JSONObject o) throws Exception {
        final Map<String, Object> m = new HashMap<>();
        final Iterator<String> keys = o.keys();
        while (keys.hasNext()) {
            final String k = keys.next();
            m.put(k, unwrap(o.get(k)));
        }
        return m;
    }

    private Object unwrap(Object v) throws Exception {
        if (v instanceof JSONObject) return toMap((JSONObject) v);
        if (v instanceof JSONArray) {
            final JSONArray a = (JSONArray) v;
            final List<Object> l = new ArrayList<>();
            for (int i = 0; i < a.length(); i++) l.add(unwrap(a.get(i)));
            return l;
        }
        return v;
    }
}
