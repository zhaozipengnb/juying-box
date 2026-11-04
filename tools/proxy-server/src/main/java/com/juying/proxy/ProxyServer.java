package com.juying.proxy;

import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpExchange;

import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;

/**
 * 外部 JAR 爬虫代理服务器。
 * 用法: java -jar proxy-server.jar <configUrl> [port]
 * 示例: java -jar proxy-server.jar https://700sjro44343.vicp.fun/eggp/0211/tv.json 9978
 *
 * API: GET /api?site={key}&action={home|category|search|detail}&tid=&wd=&page=&ids=
 */
public class ProxyServer {
    static Map<String, Object> spiders = new ConcurrentHashMap<>();
    static String configUrl;
    static String spiderJarUrl;
    static int port = 9978;

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.err.println("用法: java -jar proxy-server.jar <configUrl> [port]");
            System.err.println("示例: java -jar proxy-server.jar https://example.com/tv.json 9978");
            System.exit(1);
        }
        configUrl = args[0];
        if (args.length >= 2) port = Integer.parseInt(args[1]);

        System.out.println("[Proxy] 加载配置: " + configUrl);
        ConfigLoader.load(configUrl);
        spiderJarUrl = ConfigLoader.spiderUrl;
        System.out.println("[Proxy] spider JAR: " + spiderJarUrl);

        // 下载并加载 JAR
        SpiderLoader.init(spiderJarUrl);

        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/api", new ApiHandler());
        server.setExecutor(Executors.newCachedThreadPool());
        server.start();
        System.out.println("[Proxy] 服务已启动: http://0.0.0.0:" + port);
        System.out.println("[Proxy] 在 App 设置 → JAR代理 填入: http://<本机IP>:" + port);
    }

    static class ApiHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            try {
                URI uri = exchange.getRequestURI();
                String query = uri.getQuery();
                Map<String, String> params = parseQuery(query);

                String site = params.getOrDefault("site", "");
                String action = params.getOrDefault("action", "");
                String result = SpiderLoader.execute(site, action, params);

                byte[] resp = result.getBytes("UTF-8");
                exchange.getResponseHeaders().set("Content-Type", "application/json; charset=UTF-8");
                exchange.sendResponseHeaders(200, resp.length);
                exchange.getResponseBody().write(resp);
            } catch (Exception e) {
                String err = "{\"error\":\"" + e.getMessage().replace("\"", "'") + "\"}";
                byte[] resp = err.getBytes("UTF-8");
                exchange.sendResponseHeaders(500, resp.length);
                exchange.getResponseBody().write(resp);
                e.printStackTrace();
            } finally {
                exchange.close();
            }
        }

        private Map<String, String> parseQuery(String query) {
            Map<String, String> map = new HashMap<>();
            if (query == null) return map;
            for (String pair : query.split("&")) {
                String[] kv = pair.split("=", 2);
                try {
                    map.put(URLDecoder.decode(kv[0], "UTF-8"),
                            kv.length > 1 ? URLDecoder.decode(kv[1], "UTF-8") : "");
                } catch (java.io.UnsupportedEncodingException e) {
                    map.put(kv[0], kv.length > 1 ? kv[1] : "");
                }
            }
            return map;
        }
    }
}
