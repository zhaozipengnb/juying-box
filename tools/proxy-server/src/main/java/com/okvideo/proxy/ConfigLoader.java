package com.okvideo.proxy;

import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.file.*;
import java.util.*;

/**
 * 加载 TVBox JSON 配置，提取 spider JAR URL 和站点列表。
 */
public class ConfigLoader {
    static String spiderUrl = "";
    static List<JSONObject> sites = new ArrayList<>();

    static String configUrl;
    static void load(String configUrl) throws Exception {
        ConfigLoader.configUrl = configUrl;
        String json = httpGet(configUrl);
        // 宽松处理 JSON5 尾逗号
        json = json.replaceAll(",(\\s*[}\\]])", "$1");
        JSONObject obj = new JSONObject(json);

        spiderUrl = obj.optString("spider", "");
        JSONArray arr = obj.optJSONArray("sites");
        if (arr != null) {
            for (int i = 0; i < arr.length(); i++) {
                sites.add(arr.getJSONObject(i));
            }
        }
        System.out.println("[Config] 站点数: " + sites.size());
        for (JSONObject s : sites) {
            String api = s.optString("api", "");
            if (api.startsWith("csp_")) {
                System.out.println("  csp: " + s.optString("key") + " → " + api +
                        " jar=" + s.optString("jar", "") +
                        " ext=" + s.optString("ext", "").substring(0, Math.min(60, s.optString("ext", "").length())));
            }
        }
    }

    static JSONObject findSite(String key) {
        for (JSONObject s : sites) {
            if (s.optString("key").equals(key)) return s;
        }
        return null;
    }

    static String httpGet(String url) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        conn.setRequestProperty("User-Agent", "okhttp/4.9.3");
        conn.setConnectTimeout(10000);
        conn.setReadTimeout(30000);
        try (InputStream is = conn.getInputStream();
             ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = is.read(buf)) > 0) bos.write(buf, 0, n);
            return new String(bos.toByteArray(), "UTF-8");
        }
    }
}
