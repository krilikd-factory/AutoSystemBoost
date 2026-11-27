package org.asb.capturefixture;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.view.SurfaceView;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.VideoView;
import java.lang.reflect.Method;

/** Manual test fixture. It never collects screenshots or protected media. */
public class MainActivity extends Activity {
    private TextView state;
    private VideoView video;
    private boolean secureWindow;
    private boolean secureLayer;
    private boolean skipLayer;

    private void button(LinearLayout layout, String label, Runnable action) {
        Button b = new Button(this); b.setText(label); b.setOnClickListener(v -> action.run()); layout.addView(b);
    }

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        LinearLayout root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL);
        state = new TextView(this); state.setText("Negative control: normal window and layer"); root.addView(state);
        video = new VideoView(this);
        // SurfaceView.setSecure must be set before attachment; use the button below to
        // recreate the activity with a secure video surface rather than claim a late call applies.
        video.setSecure(getIntent().getBooleanExtra("secure_surface", false));
        root.addView(video, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 240));
        button(root, "Toggle FLAG_SECURE", () -> {
            secureWindow = !secureWindow;
            if (secureWindow) getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
            else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_SECURE);
            state.setText("FLAG_SECURE requested: " + secureWindow);
        });
        button(root, "Choose local unprotected video", () -> {
            Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT); i.setType("video/*");
            i.addCategory(Intent.CATEGORY_OPENABLE); startActivityForResult(i, 1);
        });
        button(root, "Recreate with secure SurfaceView", () -> {
            Intent i = new Intent(this, getClass()); i.putExtra("secure_surface", true); startActivity(i); finish();
        });
        button(root, "Recreate with ordinary SurfaceView", () -> {
            Intent i = new Intent(this, getClass()); i.putExtra("secure_surface", false); startActivity(i); finish();
        });
        button(root, "Reassert SurfaceControl secure", () -> { secureLayer = !secureLayer; layerFlag("setSecure", secureLayer); });
        button(root, "Reassert SurfaceControl skip screenshot", () -> { skipLayer = !skipLayer; layerFlag("setSkipScreenshot", skipLayer); });
        button(root, "Open secondary player process", () -> startActivity(new Intent(this, PlayerActivity.class)));
        ScrollView scroll = new ScrollView(this); scroll.addView(root); setContentView(scroll);
    }

    private void layerFlag(String name, boolean value) {
        try {
            Method getter = SurfaceView.class.getDeclaredMethod("getSurfaceControl"); getter.setAccessible(true);
            Object surface = getter.invoke(video);
            if (surface == null) throw new IllegalStateException("Surface unavailable; start video first");
            Class<?> sc = Class.forName("android.view.SurfaceControl");
            Class<?> tx = Class.forName("android.view.SurfaceControl$Transaction");
            Object transaction = tx.getConstructor().newInstance();
            Method setter = tx.getDeclaredMethod(name, sc, boolean.class); setter.setAccessible(true);
            setter.invoke(transaction, surface, value); tx.getMethod("apply").invoke(transaction);
            state.setText(name + " requested: " + value + " (capture result must be checked separately)");
        } catch (ReflectiveOperationException | RuntimeException e) {
            state.setText(name + " unavailable on this build: " + e.getClass().getSimpleName());
        }
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == 1 && result == RESULT_OK && data != null) {
            Uri uri = data.getData(); if (uri != null) { video.setVideoURI(uri); video.start(); }
        }
    }
}
