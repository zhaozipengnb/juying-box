#!/bin/bash
# OKVideo 统一构建脚本（全量编译，规避 hvigor 增量缓存幽灵报错）
set -e
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node
export PATH="$NODE_HOME/bin:$PATH"
cd "$(dirname "$0")/../.."
rm -rf entry/build
node /Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/bin/hvigor.js --mode module -p product=default -p buildMode=debug assembleHap "$@"
