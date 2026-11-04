#!/bin/bash
# 外部 JAR 爬虫代理服务器 启动脚本
# 用法: ./run.sh <configUrl> [port]
# 示例: ./run.sh https://700sjro44343.vicp.fun/eggp/0211/tv.json 9978

cd "$(dirname "$0")"

if [ ! -f build/libs/proxy-server.jar ]; then
    echo "构建中..."
    gradle shadowJar 2>/dev/null || gradle jar
fi

java -jar build/libs/proxy-server.jar "$@"
