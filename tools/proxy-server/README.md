# TVBox JAR 爬虫代理服务器

## 用途
执行 TVBox 订阅中的 `csp_*` Java JAR 爬虫，为鸿蒙 App 提供代理服务。

## 前置条件
- JDK 17+
- Gradle 7+ (或用 `./gradlew`)

## 构建 & 运行
```bash
cd tools/proxy-server
gradle jar
java -jar build/libs/proxy-server.jar <订阅地址> [端口]

# 示例
java -jar build/libs/proxy-server.jar https://700sjro44343.vicp.fun/eggp/0211/tv.json 9978
```

## 配置 App
1. 确保电脑和手机在同一局域网
2. 在 App 设置 → JAR代理 填入 `http://<电脑IP>:9978`
3. 首页 csp_* 源即可正常使用

## API
```
GET /api?site={key}&action=home
GET /api?site={key}&action=category&tid={tid}&page={pg}
GET /api?site={key}&action=search&wd={keyword}
GET /api?site={key}&action=detail&ids={id1,id2}
```
