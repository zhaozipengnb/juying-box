package com.juying.proxy;

import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

/**
 * 下载 JAR → dex2jar 转换 → URLClassLoader 加载 → 反射调用爬虫方法。
 * 爬虫类实现 com.github.catvod.spider.Spider 接口：
 *   homeContent(boolean, JSONObject) → JSONObject
 *   categoryContent(String, int, boolean, JSONObject) → JSONObject
 *   detailContent(JSONObject) → JSONObject
 *   searchContent(String, boolean) → JSONObject
 *   playerContent(String, String) → JSONObject
 */
public class SpiderLoader {
    static URLClassLoader classLoader;
    static Map<String, Object> spiderInstances = new ConcurrentHashMap<>();
    static Map<String, String> siteJarUrls = new ConcurrentHashMap<>();

    static void init(String spiderJarUrl) throws Exception {
        // 下载主 spider JAR
        if (spiderJarUrl != null && !spiderJarUrl.isEmpty()) {
            downloadAndLoad(spiderJarUrl, "spider_main");
        }
        // 加载各站点的 jar
        for (JSONObject site : ConfigLoader.sites) {
            String jar = site.optString("jar", "");
            String api = site.optString("api", "");
            if (api.startsWith("csp_") && !jar.isEmpty() && !siteJarUrls.containsKey(jar)) {
                try {
                    downloadAndLoad(jar, "jar_" + siteJarUrls.size());
                    siteJarUrls.put(jar, jar);
                } catch (Exception e) {
                    System.err.println("[Spider] JAR加载失败: " + jar + " → " + e.getMessage());
                }
            }
        }
        System.out.println("[Spider] JAR加载完成, classLoader ready");
    }

    static void downloadAndLoad(String jarUrl, String name) throws Exception {
        System.out.println("[Spider] 下载 JAR: " + jarUrl);
        byte[] jarData = httpGetBytes(jarUrl);
        Path tmpDir = Paths.get(System.getProperty("java.io.tmpdir"), "juying_proxy");
        Files.createDirectories(tmpDir);

        // 保存原始 JAR (含 classes.dex)
        Path dexJar = tmpDir.resolve(name + "_dex.jar");
        Files.write(dexJar, jarData);

        // 提取 classes.dex
        Path dexFile = tmpDir.resolve(name + ".dex");
        extractDex(dexJar, dexFile);

        // dex2jar 转换
        Path stdJar = tmpDir.resolve(name + ".jar");
        dex2jar(dexFile, stdJar);

        // 加入 classloader
        addClassLoader(stdJar.toUri().toURL());
        System.out.println("[Spider] JAR已加载: " + name + " (" + jarData.length + " bytes)");
    }

    static void extractDex(Path jarPath, Path dexPath) throws Exception {
        java.util.jar.JarFile jar = new java.util.jar.JarFile(jarPath.toFile());
        java.util.jar.JarEntry entry = jar.getJarEntry("classes.dex");
        if (entry == null) throw new RuntimeException("JAR中无 classes.dex");
        try (InputStream is = jar.getInputStream(entry);
             OutputStream os = Files.newOutputStream(dexPath)) {
            byte[] buf = new byte[8192]; int n;
            while ((n = is.read(buf)) > 0) os.write(buf, 0, n);
        }
        jar.close();
    }

    static void dex2jar(Path dexPath, Path jarPath) throws Exception {
        // 使用 com.googlecode.dex2jar 库进行转换
        try {
            Class<?> d2j = Class.forName("com.googlecode.dex2jar.tools.Dex2jarCmd");
            java.lang.reflect.Method main = d2j.getMethod("main", String[].class);
            main.invoke(null, (Object) new String[]{
                    "-f", dexPath.toString(), "-o", jarPath.toString()
            });
        } catch (ClassNotFoundException e) {
            // 回退：直接用原始 JAR（某些 JAR 可能已是标准 Java 格式）
            System.err.println("[Spider] dex2jar未找到，尝试直接加载原始JAR");
            Files.copy(dexPath.getParent().resolve(
                    dexPath.getFileName().toString().replace(".dex", "_dex.jar")), jarPath,
                    StandardCopyOption.REPLACE_EXISTING);
        }
    }

    static void addClassLoader(URL url) {
        if (classLoader == null) {
            classLoader = new URLClassLoader(new URL[]{url});
        } else {
            // 合并到新的 classloader
            URL[] urls = new URL[classLoader.getURLs().length + 1];
            System.arraycopy(classLoader.getURLs(), 0, urls, 0, urls.length - 1);
            urls[urls.length - 1] = url;
            classLoader = new URLClassLoader(urls);
        }
    }

    @SuppressWarnings("unchecked")
    static String execute(String siteKey, String action, Map<String, String> params) throws Exception {
        JSONObject site = ConfigLoader.findSite(siteKey);
        if (site == null) throw new RuntimeException("站点不存在: " + siteKey);

        String api = site.optString("api", "");
        if (!api.startsWith("csp_")) throw new RuntimeException("非csp源: " + api);

        // 获取或创建爬虫实例
        Object spider = spiderInstances.get(siteKey);
        if (spider == null) {
            String className = "com.github.catvod.spider." + api.substring(4);
            Class<?> cls = classLoader.loadClass(className);
            spider = cls.getDeclaredConstructor().newInstance();
            spiderInstances.put(siteKey, spider);
            System.out.println("[Spider] 实例化: " + className);
            // init(ext)：按爬虫实际签名调用（String / JSONObject / Context,String）
            String extRaw = site.optString("ext", "");
            try {
                java.lang.reflect.Method im = null;
                try { im = cls.getMethod("init", String.class); }
                catch (NoSuchMethodException ignore) {
                    try { im = cls.getMethod("init", org.json.JSONObject.class); }
                    catch (NoSuchMethodException ignore2) {
                        try { im = cls.getMethod("init", android.content.Context.class, String.class); }
                        catch (NoSuchMethodException ignore3) { im = null; }
                    }
                }
                if (im != null) {
                    if (im.getParameterTypes().length == 2) { im.invoke(spider, null, extRaw); }
                    else if (im.getParameterTypes()[0] == org.json.JSONObject.class) {
                        im.invoke(spider, extRaw.startsWith("{") ? new org.json.JSONObject(extRaw) : new org.json.JSONObject());
                    } else { im.invoke(spider, extRaw); }
                    System.out.println("[Spider] init ok");
                }
            } catch (Exception ex) { System.err.println("[Spider] init 失败: " + ex); }
        }

        // 读取 ext 配置
        String extStr = site.optString("ext", "");
        JSONObject ext = null;
        if (extStr.startsWith("{")) {
            ext = new JSONObject(extStr);
        } else if (extStr.startsWith("http")) {
            ext = new JSONObject();
            ext.put("url", extStr);
        }

        Object result;
        Class<?> spiderClass = spider.getClass();

        switch (action) {
            case "home": {
                java.lang.reflect.Method m = findOverride(spiderClass, "homeContent",
                        new Class<?>[]{ boolean.class, JSONObject.class },
                        new Class<?>[]{ boolean.class });
                result = m.getParameterTypes().length == 2
                        ? m.invoke(spider, false, ext != null ? ext : new JSONObject())
                        : m.invoke(spider, false);
                break;
            }
            case "category": {
                String tid = params.getOrDefault("tid", "1");
                int page = Integer.parseInt(params.getOrDefault("page", "1"));
                java.lang.reflect.Method m = findOverride(spiderClass, "categoryContent",
                        new Class<?>[]{ String.class, int.class, boolean.class, JSONObject.class },
                        new Class<?>[]{ String.class, String.class, boolean.class, java.util.HashMap.class });
                Object[] args;
                if (m.getParameterTypes()[1] == int.class) {
                    args = new Object[]{ tid, page, false, ext != null ? ext : new JSONObject() };
                } else {
                    args = new Object[]{ tid, String.valueOf(page), false, new java.util.HashMap<String, String>() };
                }
                result = m.invoke(spider, args);
                break;
            }
            case "search": {
                String wd = params.getOrDefault("wd", "");
                java.lang.reflect.Method m = spiderClass.getMethod("searchContent", String.class, boolean.class);
                result = m.invoke(spider, wd, false);
                break;
            }
            case "detail": {
                String ids = params.getOrDefault("ids", "");
                java.lang.reflect.Method m = findOverride(spiderClass, "detailContent",
                        new Class<?>[]{ JSONObject.class },
                        new Class<?>[]{ java.util.List.class });
                Object arg;
                if (m.getParameterTypes()[0] == JSONObject.class) {
                    JSONObject idsObj = new JSONObject();
                    JSONArray idArr = new JSONArray();
                    for (String id : ids.split(",")) idArr.put(id.trim());
                    arg = idsObj;
                } else {
                    java.util.List<String> idList = new java.util.ArrayList<>();
                    for (String id : ids.split(",")) idList.add(id.trim());
                    arg = idList;
                }
                result = m.invoke(spider, arg);
                break;
            }
            /* 旧 detail 实现占位开始
                java.lang.reflect.Method m;
                Object arg;
                try {
                    m = spiderClass.getMethod("detailContent", JSONObject.class);
                    JSONObject idsObj = new JSONObject();
                    JSONArray idArr = new JSONArray();
                    for (String id : ids.split(",")) idArr.put(id.trim());
                    idsObj.put("ids", idArr);
                    arg = idsObj;
                } catch (NoSuchMethodException ignore) {
                }
                旧 detail 实现占位结束 */
            default:
                throw new RuntimeException("未知action: " + action);
        }

        if (result == null) return "{\"list\":[]}";
        return result.toString();
    }


    /** 按签名组查找方法：优先子类自身 override（跳过 Spider 基类桩默认实现），都无则回退基类 */
    static java.lang.reflect.Method findOverride(Class<?> cls, String name, Class<?>[]... sigs) throws NoSuchMethodException {
        for (Class<?>[] sig : sigs) {
            try {
                java.lang.reflect.Method m = cls.getMethod(name, sig);
                if (m.getDeclaringClass() != com.github.catvod.crawler.Spider.class) return m;
            } catch (NoSuchMethodException ignore) { }
        }
        for (Class<?>[] sig : sigs) {
            try { return cls.getMethod(name, sig); } catch (NoSuchMethodException ignore) { }
        }
        throw new NoSuchMethodException(name);
    }

    static byte[] httpGetBytes(String url) throws Exception {
        // 聚合协议生态 jar 引用常带 ;md5;xxx 校验后缀与 ./ 相对路径：剥后缀、对配置 URL 绝对化
        String u = url;
        int semi = u.indexOf(';');
        if (semi > 0) { u = u.substring(0, semi); }
        if (!u.startsWith("http")) {
            String base = ConfigLoader.configUrl;
            if (base != null) {
                try {
                    java.net.URL bu = new java.net.URL(base);
                    u = new java.net.URL(bu, u).toString();
                } catch (Exception ignore) { }
            }
        }
        System.out.println("[Spider] GET " + u);
        HttpURLConnection conn = (HttpURLConnection) new URL(u).openConnection();
        conn.setRequestProperty("User-Agent", "okhttp/4.9.3");
        conn.setConnectTimeout(15000);
        conn.setReadTimeout(60000);
        try (InputStream is = conn.getInputStream();
             ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
            byte[] buf = new byte[8192]; int n;
            while ((n = is.read(buf)) > 0) bos.write(buf, 0, n);
            return bos.toByteArray();
        }
    }
}
