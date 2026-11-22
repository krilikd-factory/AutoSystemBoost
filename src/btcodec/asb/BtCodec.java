package asb;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothProfile;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;

import java.io.FileOutputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.List;

/*
 * LDAC playback quality helper, started by runtime/asb_bt_codec.sh through app_process.
 *
 * Android forgets the Developer options LDAC choice on every reconnect, because the stack only
 * keeps a codec preference for the current link. This helper asks the framework for the same
 * preference the Developer options screen sets (codecSpecific1 1000/1001/1002/1003) and reads the
 * codec status back. It only acts when the active A2DP codec is already LDAC, never changes the
 * codec type, sample rate, bit depth or channel mode, and never touches a non-LDAC headset.
 *
 * Modes:
 *   status            print the active codec and LDAC quality, then exit
 *   apply <q>         set the quality once on the active LDAC device, read it back, exit
 *   watch <q>         stay resident: re-apply after codec/active-device/connection events
 *
 * The watch uses broadcasts when the framework accepts the registration; otherwise it falls back
 * to an uptime-based check (Handler uses uptime, so nothing runs while the phone is suspended).
 */
public final class BtCodec {
    private static final int SOURCE_CODEC_TYPE_LDAC = 4;
    private static final long PRIORITY_HIGHEST = 1000000L;
    private static final String CODEC_CHANGED = "android.bluetooth.a2dp.profile.action.CODEC_CONFIG_CHANGED";
    private static final String ACTIVE_CHANGED = "android.bluetooth.a2dp.profile.action.ACTIVE_DEVICE_CHANGED";
    private static final String CONN_CHANGED = "android.bluetooth.a2dp.profile.action.CONNECTION_STATE_CHANGED";

    private static Object a2dp;
    private static Handler handler;
    private static String mode = "status";
    private static long want = -1;
    private static String stateFile = null;
    private static boolean events = false;
    private static long lastApply = 0;
    private static int retries = 0;

    public static void main(String[] args) {
        try {
            mode = args.length > 0 ? args[0] : "status";
            want = args.length > 1 ? quality(args[1]) : -1;
            stateFile = args.length > 2 ? args[2] : null;
            if (!"status".equals(mode) && want < 0) { out("result=bad_request"); System.exit(2); }
            Looper.prepareMainLooper();
            handler = new Handler(Looper.getMainLooper());
            final Context ctx = systemContext();
            BluetoothAdapter adapter = BluetoothAdapter.getDefaultAdapter();
            if (ctx == null || adapter == null) { out("result=unavailable\nreason=no_adapter"); System.exit(3); }
            Object listener = java.lang.reflect.Proxy.newProxyInstance(BtCodec.class.getClassLoader(),
                new Class<?>[] { BluetoothProfile.ServiceListener.class }, (p, m, a) -> {
                    if ("onServiceConnected".equals(m.getName())) { a2dp = a[1]; connected(ctx); }
                    else if ("onServiceDisconnected".equals(m.getName())) { a2dp = null; if (!"watch".equals(mode)) finish("result=unavailable\nreason=profile_lost", 3); }
                    return null;
                });
            if (!adapter.getProfileProxy(ctx, (BluetoothProfile.ServiceListener) listener, BluetoothProfile.A2DP)) {
                out("result=unavailable\nreason=no_profile"); System.exit(3);
            }
            if (!"watch".equals(mode)) handler.postDelayed(() -> finish("result=timeout", 4), 8000);
            Looper.loop();
        } catch (Throwable t) {
            out("result=failed\nreason=" + t.getClass().getSimpleName());
            System.exit(5);
        }
    }

    private static long quality(String s) {
        if ("990".equals(s) || "hq".equals(s) || "1000".equals(s)) return 1000;
        if ("660".equals(s) || "sq".equals(s) || "1001".equals(s)) return 1001;
        if ("330".equals(s) || "mq".equals(s) || "1002".equals(s)) return 1002;
        if ("abr".equals(s) || "adaptive".equals(s) || "1003".equals(s)) return 1003;
        return -1;
    }

    private static Context systemContext() throws Exception {
        Class<?> at = Class.forName("android.app.ActivityThread");
        Object thread;
        try {
            Method sm = at.getDeclaredMethod("systemMain");
            thread = sm.invoke(null);
        } catch (Throwable t) {
            Constructor<?> c = at.getDeclaredConstructor();
            c.setAccessible(true);
            thread = c.newInstance();
            Field f = at.getDeclaredField("sCurrentActivityThread");
            f.setAccessible(true);
            f.set(null, thread);
        }
        Method gc = at.getDeclaredMethod("getSystemContext");
        gc.setAccessible(true);
        return (Context) gc.invoke(thread);
    }

    private static void connected(Context ctx) {
        if ("status".equals(mode)) { finish(describe(), 0); return; }
        if ("apply".equals(mode)) { applyOnce(true); return; }
        try {
            IntentFilter f = new IntentFilter();
            f.addAction(CODEC_CHANGED); f.addAction(ACTIVE_CHANGED); f.addAction(CONN_CHANGED);
            ctx.registerReceiver(new BroadcastReceiver() {
                @Override public void onReceive(Context c, Intent i) { schedule(1200); }
            }, f, null, handler);
            events = true;
        } catch (Throwable t) {
            events = false;
        }
        state("watch", "events=" + (events ? "broadcast" : "uptime"));
        schedule(500);
    }

    private static void schedule(long ms) {
        handler.removeCallbacksAndMessages(null);
        handler.postDelayed(BtCodec::tick, ms);
    }

    private static void tick() {
        applyOnce(false);
        long next = events ? 600000 : (activeLdac() != null ? 30000 : 90000);
        if (retries > 0 && retries < 4) next = 3000;
        handler.postDelayed(BtCodec::tick, next);
    }

    private static Object activeDevice() {
        try {
            Object d = call(a2dp, "getActiveDevice");
            if (d != null) return d;
        } catch (Throwable ignored) { }
        try {
            List<?> l = (List<?>) call(a2dp, "getConnectedDevices");
            return l != null && l.size() == 1 ? l.get(0) : null;
        } catch (Throwable t) { return null; }
    }

    private static Object codecConfig(Object dev) {
        try {
            Object st = a2dp.getClass().getMethod("getCodecStatus", BluetoothDevice.class).invoke(a2dp, dev);
            return st == null ? null : call(st, "getCodecConfig");
        } catch (Throwable t) { return null; }
    }

    private static Object activeLdac() {
        Object dev = activeDevice();
        if (dev == null) return null;
        Object cfg = codecConfig(dev);
        return cfg != null && num(cfg, "getCodecType") == SOURCE_CODEC_TYPE_LDAC ? cfg : null;
    }

    private static String describe() {
        Object dev = activeDevice();
        if (dev == null) return "result=no_device";
        Object cfg = codecConfig(dev);
        if (cfg == null) return "result=no_codec";
        long type = num(cfg, "getCodecType");
        return "result=ok\ncodec=" + (type == SOURCE_CODEC_TYPE_LDAC ? "ldac" : String.valueOf(type))
            + "\nquality=" + (type == SOURCE_CODEC_TYPE_LDAC ? String.valueOf(num(cfg, "getCodecSpecific1")) : "none");
    }

    private static void applyOnce(boolean exit) {
        Object dev = activeDevice();
        Object cfg = dev == null ? null : codecConfig(dev);
        if (dev == null || cfg == null) { retries = 0; done(exit, "result=no_device", 0); return; }
        if (num(cfg, "getCodecType") != SOURCE_CODEC_TYPE_LDAC) { retries = 0; done(exit, "result=not_ldac", 0); return; }
        if (num(cfg, "getCodecSpecific1") == want) { retries = 0; done(exit, "result=applied\nquality=" + want, 0); return; }
        long now = SystemClock.uptimeMillis();
        if (!exit && now - lastApply < 2500) return;
        lastApply = now;
        try {
            Object next = build(cfg, want);
            a2dp.getClass().getMethod("setCodecConfigPreference", BluetoothDevice.class, next.getClass()).invoke(a2dp, dev, next);
        } catch (Throwable t) {
            retries = 0;
            done(exit, "result=refused\nreason=" + t.getClass().getSimpleName(), 6);
            return;
        }
        handler.postDelayed(() -> {
            Object after = codecConfig(dev);
            long got = after == null ? -1 : num(after, "getCodecSpecific1");
            if (got == want) { retries = 0; done(exit, "result=applied\nquality=" + want, 0); }
            else if (exit) done(true, "result=not_kept\nquality=" + got, 7);
            else { retries++; state("pending", "quality=" + got); }
        }, 1500);
    }

    private static Object build(Object cfg, long cs1) throws Exception {
        Class<?> cc = cfg.getClass();
        int type = (int) num(cfg, "getCodecType");
        int rate = (int) num(cfg, "getSampleRate");
        int bits = (int) num(cfg, "getBitsPerSample");
        int ch = (int) num(cfg, "getChannelMode");
        long c2 = num(cfg, "getCodecSpecific2"), c3 = num(cfg, "getCodecSpecific3"), c4 = num(cfg, "getCodecSpecific4");
        try {
            Class<?> bc = Class.forName("android.bluetooth.BluetoothCodecConfig$Builder");
            Object b = bc.getConstructor().newInstance();
            bc.getMethod("setCodecType", int.class).invoke(b, type);
            bc.getMethod("setCodecPriority", int.class).invoke(b, (int) PRIORITY_HIGHEST);
            bc.getMethod("setSampleRate", int.class).invoke(b, rate);
            bc.getMethod("setBitsPerSample", int.class).invoke(b, bits);
            bc.getMethod("setChannelMode", int.class).invoke(b, ch);
            bc.getMethod("setCodecSpecific1", long.class).invoke(b, cs1);
            bc.getMethod("setCodecSpecific2", long.class).invoke(b, c2);
            bc.getMethod("setCodecSpecific3", long.class).invoke(b, c3);
            bc.getMethod("setCodecSpecific4", long.class).invoke(b, c4);
            return bc.getMethod("build").invoke(b);
        } catch (ClassNotFoundException | NoSuchMethodException e) {
            Constructor<?> k = cc.getDeclaredConstructor(int.class, int.class, int.class, int.class, int.class,
                long.class, long.class, long.class, long.class);
            k.setAccessible(true);
            return k.newInstance(type, (int) PRIORITY_HIGHEST, rate, bits, ch, cs1, c2, c3, c4);
        }
    }

    private static Object call(Object o, String name) throws Exception {
        Method m = o.getClass().getMethod(name);
        return m.invoke(o);
    }

    private static long num(Object o, String name) {
        try { return ((Number) call(o, name)).longValue(); } catch (Throwable t) { return -1; }
    }

    private static void done(boolean exit, String msg, int rc) {
        if (exit) { finish(msg, rc); return; }
        int nl = msg.indexOf('\n');
        state(msg.substring(7, nl < 0 ? msg.length() : nl), nl < 0 ? "" : msg.substring(nl + 1));
    }

    private static void state(String s, String extra) {
        if (stateFile == null) return;
        try (FileOutputStream f = new FileOutputStream(stateFile)) {
            f.write(("state=" + s + "\nwant=" + want + "\nevents=" + (events ? "broadcast" : "uptime")
                + (extra.isEmpty() ? "" : "\n" + extra) + "\nts=" + (System.currentTimeMillis() / 1000) + "\n").getBytes("UTF-8"));
        } catch (Throwable ignored) { }
    }

    private static void finish(String msg, int rc) {
        out(msg);
        System.exit(rc);
    }

    private static void out(String s) {
        System.out.println(s);
        System.out.flush();
    }
}
