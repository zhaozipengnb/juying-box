#!/bin/bash
# OKVideo 本地单测脚本（清增量测试缓存后全量跑，防陈旧诊断）
set -e
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node
export PATH="$NODE_HOME/bin:$PATH"
cd "$(dirname "$0")/../.."
rm -rf entry/.test
node /Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/bin/hvigor.js --mode module -p module=entry@default test "$@"
