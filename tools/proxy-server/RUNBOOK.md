# proxy-server 运行手册（2026-10-24 实战记录）

## 已跑通链路（本机验证到 DNS+TLS 层）
1. 绿盾环境编译：`./rebuild.sh`（原理见脚本头注释）
2. 依赖 jar（放 libs/）：org.json、dex-tools-v2.4/lib/*（dex→jar 转换）、okhttp 4.12、okio-jvm、kotlin-stdlib、gson、jsoup
3. 宿主桩（shim-src/ALL_SHIMS.java）：catvod crawler Spider/SpiderDebug 新旧双签名、android.*（Context/SharedPreferences/pm 签名链/Bitmap/WebView/Toast/SystemProperties…）、cronet 直通桩
4. 反射兼容（SpiderLoader）：findOverride 跳过基类桩默认实现 + init(ext) 按爬虫实际签名调用
5. 运行：`java -cp "build/classes:libs/*" com.okvideo.proxy.ProxyServer <本地伺服的订阅> 9978`
   （订阅 JSON 若带 // 注释行需清洗；相对 jar 路径已支持绝对化+;md5 剥离）

## 诊断工具链（本机 /tmp/proxy-server 沉淀）
- Drive.java：绕过 HTTP 层直调爬虫类（定位 ClassNotFoundException/初始化炸点）
- DNS 探针：InetAddressResolver SPI 记录所有域名解析（抓到 v.rbotv.cn）
- org.json 日志版：JSONTokener.syntaxError 打印响应原文（抓到空响应）
- okhttp 遮蔽：OkHostnameVerifier trustAll + 全局 trustAll SSLContext
- jdb：catch java.lang.Exception 停抛出点（注意断点会冻结线程，resume 要及时）

## 壁垒结论（萌米系 fty.jar，如 csp_AppTT 热播/萌米）
链路全通：dex→jar ✓ 宿主桩 ✓ 反射调用 ✓ init ✓ DNS(v.rbotv.cn) ✓ TLS 信任 ✓
但响应恒为空串。javap 证据：爬虫读 android.content.pm.PackageInfo.signatures→Signature.toByteArray()
——APK 签名参与鉴权（本地派生 token 或服务端校验）。假签名（64 字节模式数据）无效。
裸 okhttp 直连该站 200 正常，排除服务端对 JVM 指纹的普遍拒绝。
→ 判定：此类加固源在 JVM 复刻成本≈逆向其鉴权协议，不值得；无加固的简单 csp_* 可用本服务跑。

## App 侧
设置 → Proxy → 填 http://<本机IP>:9978；未配置时纯 JAR 源自动跳过。
