package net.inverge.nexus.core;

import android.content.Context;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Bridge to the native (NDK) crash handler ({@code libnexus_ndk.so}). Installs
 * POSIX signal handlers that capture native C/C++ crashes (SIGSEGV/SIGABRT/…),
 * and reads the persisted backtrace on the next launch. Addresses are
 * symbolicated server-side against the .so's build-id (ndk-stack / addr2line),
 * aided by the dumped /proc/self/maps.
 */
public class NexusNdk {

    private static final String CRASH_FILE = "nexus_native_crash.txt";
    private static final String MAPS_FILE = "nexus_native_maps.txt";
    private static final String IMAGES_FILE = "nexus_native_images.txt";
    private static boolean available;

    static {
        try {
            System.loadLibrary("nexus_ndk");
            available = true;
        } catch (Throwable t) {
            available = false; // NDK layer not bundled on this build
        }
    }

    private final Context context;

    public NexusNdk(Context context) {
        this.context = context.getApplicationContext();
    }

    public boolean isAvailable() {
        return available;
    }

    public void install() {
        if (!available) return;
        try {
            nativeInstall(new File(context.getFilesDir(), CRASH_FILE).getAbsolutePath());
            nativeDumpMaps(new File(context.getFilesDir(), MAPS_FILE).getAbsolutePath());
            nativeDumpImages(new File(context.getFilesDir(), IMAGES_FILE).getAbsolutePath());
        } catch (Throwable ignore) {
        }
    }

    /** Read the persisted native crash (if any) as a single report; clears it. */
    public List<Map<String, Object>> takePending() {
        final List<Map<String, Object>> out = new ArrayList<>();
        final File file = new File(context.getFilesDir(), CRASH_FILE);
        if (!file.exists()) return out;
        int signal = 0;
        String fault = null;
        final List<Object> frames = new ArrayList<>();
        try (BufferedReader r = new BufferedReader(new FileReader(file))) {
            String line;
            while ((line = r.readLine()) != null) {
                if (line.startsWith("signal=")) {
                    signal = Integer.parseInt(line.substring(7).trim());
                } else if (line.startsWith("fault=")) {
                    fault = line.substring(6).trim();
                } else if (line.startsWith("frame=")) {
                    final Map<String, Object> f = new HashMap<>();
                    f.put("address", line.substring(6).trim());
                    frames.add(f);
                }
            }
        } catch (Exception ignore) {
        }
        file.delete();

        final Map<String, Object> crash = new HashMap<>();
        crash.put("type", "NativeCrash (" + signalName(signal) + ")");
        crash.put("message", "Native (NDK) crash — " + signalName(signal)
                + (fault != null ? " at " + fault : ""));
        crash.put("platform", "android-ndk");
        crash.put("stack", frames);
        crash.put("maps", readMaps());
        final List<Map<String, Object>> images = readImages();
        if (!images.isEmpty()) crash.put("binaryImages", images);
        out.add(crash);
        return out;
    }

    /** Loaded ELF images with build-id + base — the backend matches these exactly. */
    private List<Map<String, Object>> readImages() {
        final List<Map<String, Object>> out = new ArrayList<>();
        final File file = new File(context.getFilesDir(), IMAGES_FILE);
        if (!file.exists()) return out;
        try (BufferedReader r = new BufferedReader(new FileReader(file))) {
            String line;
            while ((line = r.readLine()) != null) {
                if (!line.startsWith("image=")) continue;
                // image=<buildid> <base_hex> <name>
                final String[] parts = line.substring(6).trim().split(" ", 3);
                if (parts.length < 3) continue;
                final Map<String, Object> img = new HashMap<>();
                img.put("uuid", parts[0]);         // ELF build-id → matches DebugFile.identifier
                img.put("loadAddress", parts[1]);  // hex
                final String path = parts[2];
                final int slash = path.lastIndexOf('/');
                img.put("name", slash >= 0 ? path.substring(slash + 1) : path);
                img.put("path", path);
                out.add(img);
            }
        } catch (Exception ignore) {
        }
        file.delete();
        return out;
    }

    private String readMaps() {
        final File maps = new File(context.getFilesDir(), MAPS_FILE);
        if (!maps.exists()) return null;
        final StringBuilder sb = new StringBuilder();
        try (BufferedReader r = new BufferedReader(new FileReader(maps))) {
            String line;
            int lines = 0;
            while ((line = r.readLine()) != null && lines++ < 400) {
                sb.append(line).append('\n');
            }
        } catch (Exception ignore) {
        }
        return sb.length() == 0 ? null : sb.toString();
    }

    private static String signalName(int s) {
        switch (s) {
            case 4: return "SIGILL";
            case 6: return "SIGABRT";
            case 7: return "SIGBUS";
            case 8: return "SIGFPE";
            case 11: return "SIGSEGV";
            case 5: return "SIGTRAP";
            default: return "signal " + s;
        }
    }

    private static native void nativeInstall(String crashFilePath);

    private static native void nativeDumpMaps(String destPath);

    private static native void nativeDumpImages(String destPath);
}
