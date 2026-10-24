// ===== Activity =====
package android.app;
public class Activity extends android.content.Context { public void finish() { } }

// ===== AlertDialog =====
package android.app;
public class AlertDialog {
    public void show() { } public void dismiss() { }
    public static class Builder {
        public Builder(android.content.Context c) { }
        public Builder setTitle(CharSequence t) { return this; }
        public Builder setMessage(CharSequence m) { return this; }
        public Builder setPositiveButton(CharSequence t, android.content.DialogInterface.OnClickListener l) { return this; }
        public Builder setOnDismissListener(android.content.DialogInterface.OnDismissListener l) { return this; }
        public AlertDialog create() { return new AlertDialog(); }
        public AlertDialog show() { return new AlertDialog(); }
    }
}

// ===== Application =====
package android.app;
public class Application { }

// ===== ApplicationInfo =====
package android.content.pm;
public class ApplicationInfo { public String sourceDir = ""; public String dataDir = ""; }

// ===== Base64 =====
package android.util;
public class Base64 {
    public static final int DEFAULT = 0, NO_WRAP = 2, NO_PADDING = 1, URL_SAFE = 8;
    public static byte[] encode(byte[] in, int f) { return java.util.Base64.getEncoder().encode(in); }
    public static String encodeToString(byte[] in, int f) { return java.util.Base64.getEncoder().encodeToString(in); }
    public static byte[] decode(String in, int f) { return java.util.Base64.getDecoder().decode(in); }
}

// ===== Bitmap =====
package android.graphics;
public class Bitmap {
    public static class Config { public static final Config ARGB_8888 = new Config(); }
    public static Bitmap createBitmap(int w, int h, Config c) { return new Bitmap(); }
    public void setPixels(int[] p, int o, int s, int x, int y, int w, int h) { }
}

// ===== Build =====
package android.os;
public class Build {
    public static class VERSION { public static final int SDK_INT = 34; public static final String RELEASE = "14"; }
    public static final String MODEL = "Pixel 8";
    public static final String MANUFACTURER = "Google";
}

// ===== ColorDrawable =====
package android.graphics.drawable;
public class ColorDrawable { public ColorDrawable(int color) { } }

// ===== Context =====
package android.content;
import java.io.File;
public class Context {
    public File getCacheDir() { return new File(System.getProperty("java.io.tmpdir")); }
    public File getFilesDir() { return new File(System.getProperty("user.home"), "okvideo_files"); }
    public ClassLoader getClassLoader() { return Context.class.getClassLoader(); }
    public String getPackageName() { return "com.github.tvbox.osc"; }
    public SharedPreferences getSharedPreferences(String name, int mode) { return new SharedPreferences(); }
    public android.content.pm.PackageManager getPackageManager() { return new android.content.pm.PackageManager(); }
    public android.content.pm.ApplicationInfo getApplicationInfo() { return new android.content.pm.ApplicationInfo(); }
}

// ===== CronetInterceptor =====
package com.google.net.cronet.okhttptransport;
/** cronet 传输桩：yq 为静态清理钩子，直通实现 */
public class CronetInterceptor implements okhttp3.Interceptor {
    public static void yq(CronetInterceptor ci) { }
    public okhttp3.Response intercept(Chain chain) throws java.io.IOException { return chain.proceed(chain.request()); }
}

// ===== DialogInterface =====
package android.content;
public class DialogInterface {
    public interface OnClickListener { void onClick(DialogInterface d, int which); }
    public interface OnDismissListener { void onDismiss(DialogInterface d); }
}

// ===== EditText =====
package android.widget;
public class EditText { public String getText() { return ""; } }

// ===== FrameLayout =====
package android.widget;
public class FrameLayout {
    public static class LayoutParams {
        public int gravity; public int topMargin;
        public LayoutParams(int w, int h) { }
    }
}

// ===== ImageView =====
package android.widget;
public class ImageView { public void setImageBitmap(android.graphics.Bitmap b) { } }

// ===== Log =====
package android.util;
public class Log {
    public static int d(String t, String m) { return 0; }
    public static int e(String t, String m) { System.err.println(t + ": " + m); return 0; }
    public static int i(String t, String m) { return 0; }
    public static int w(String t, String m) { return 0; }
}

// ===== PackageInfo =====
package android.content.pm;
public class PackageInfo { public Signature[] signatures = new Signature[]{ new Signature() }; }

// ===== PackageManager =====
package android.content.pm;
public class PackageManager {
    public PackageInfo getPackageInfo(String pkg, int flags) throws NameNotFoundException {
        if (!"com.github.tvbox.osc".equals(pkg)) throw new NameNotFoundException(pkg);
        return new PackageInfo();
    }
    public static class NameNotFoundException extends Exception { public NameNotFoundException(String m) { super(m); } }
}

// ===== SharedPreferences =====
package android.content;
public class SharedPreferences {
    public long getLong(String k, long def) { return def; }
    public String getString(String k, String def) { return def; }
    public Editor edit() { return new Editor(); }
    public static class Editor {
        public Editor putLong(String k, long v) { return this; }
        public Editor putString(String k, String v) { return this; }
        public void apply() { }
    }
}

// ===== Signature =====
package android.content.pm;
public class Signature {
    private static final byte[] FAKE = new byte[64];
    static { for (int i = 0; i < FAKE.length; i++) { FAKE[i] = (byte) (i * 7 + 3); } }
    public byte[] toByteArray() { return FAKE.clone(); }
    public char[] toChars() { return new char[0]; }
    public int hashCode() { return 1; }
}

// ===== Spider =====
package com.github.catvod.crawler;
import org.json.JSONObject;
import java.util.HashMap;
import java.util.List;
public abstract class Spider {
    public void init(String extend) { }
    public void init(android.content.Context context, String extend) { }
    public void init(JSONObject extend) { }
    public String homeContent(boolean filter) { return ""; }
    public String homeContent(boolean filter, JSONObject extend) { return ""; }
    public String homeVideoContent() { return ""; }
    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) { return ""; }
    public String categoryContent(String tid, int pg, boolean filter, JSONObject extend) { return ""; }
    public String detailContent(List<String> ids) { return ""; }
    public String detailContent(JSONObject ids) { return ""; }
    public String searchContent(String key, boolean quick) { return ""; }
    public String searchContent(String key, boolean quick, String pg) { return ""; }
    public String playerContent(String flag, String id, List<String> vipFlags) { return ""; }
    public boolean manualVideoCheck() { return false; }
    public boolean isVideoFormat(String url) { return false; }
    public void destroy() { }
}

// ===== SpiderDebug =====
package com.github.catvod.crawler;
public class SpiderDebug {
    public static void log(String msg) { System.out.println("[SpiderDebug] " + msg); }
    public static void log(Throwable e) { e.printStackTrace(); }
}

// ===== SystemProperties =====
package android.os;
/** Android 隐藏 API 桩：爬虫常经反射调用（http.proxyHost 等），返回默认值 */
public class SystemProperties {
    public static String get(String key) { return ""; }
    public static String get(String key, String def) { return def; }
    public static int getInt(String key, int def) { return def; }
    public static boolean getBoolean(String key, boolean def) { return def; }
    public static void set(String key, String value) { }
}

// ===== TextUtils =====
package android.text;
public class TextUtils {
    public static boolean isEmpty(CharSequence s) { return s == null || s.length() == 0; }
    public static String join(CharSequence sep, Iterable<?> items) {
        StringBuilder sb = new StringBuilder(); boolean f = true;
        for (Object o : items) { if (!f) sb.append(sep); sb.append(o); f = false; }
        return sb.toString();
    }
}

// ===== TextView =====
package android.widget;
public class TextView { public void setText(CharSequence t) { } }

// ===== Toast =====
package android.widget;
public class Toast { public static Toast makeText(android.content.Context c, CharSequence m, int d) { return new Toast(); } public void show() { } }

// ===== Uri =====
package android.net;
public class Uri { }

// ===== UrlQuerySanitizer =====
package android.net;
public class UrlQuerySanitizer {
    public UrlQuerySanitizer(String url) { }
    public void parseUrl(String url) { }
    public String getValue(String param) { return null; }
}

// ===== WebSettings =====
package android.webkit;
public class WebSettings {
    public String getUserAgentString() { return "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"; }
}

// ===== WebView =====
package android.webkit;
public class WebView {
    public WebSettings getSettings() { return new WebSettings(); }
}
