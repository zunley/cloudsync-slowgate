#!/bin/bash
# 变参转发自测：
#  - 不注入时，假 curl 收到调用方原始值（证明测试框架本身有效）
#  - 注入时，19/20 被改写为 0，LONG / 指针 / OFF_T 三类其余选项原样通过
set -e
cd "$(dirname "$0")"
ROOT=..
[ -f "$ROOT/slowgate.so" ] || { echo "先 make 生成 slowgate.so"; exit 1; }

gcc -O1 -fPIC -shared -o libfakecurl.so fake_curl.c
gcc -o caller caller.c -L. -Wl,-rpath,. -lfakecurl

# 2>&1：shim 的自报行写 stderr
plain=$(./caller 2>&1)
pre=$(LD_PRELOAD=../slowgate.so ./caller 2>&1)

echo "--- 不注入 ---";  echo "$plain"
echo "--- 注入 shim ---"; echo "$pre"
echo

fail=0
need() { grep -qF "$1" <<<"$pre" || { echo "FAIL: 注入后缺少 [$1]"; fail=1; }; }

grep -qF "opt=19 LONG  value=1" <<<"$plain" || { echo "FAIL: 测试框架未收到原始值"; fail=1; }
need "slowgate: low-speed guard disabled"
need "opt=19 LONG  value=0"
need "opt=20 LONG  value=0"
need "opt=13 LONG  value=300"
need "opt=10002 PTR"
need "opt=30115 OFF_T value=7213216146"

if [ "$fail" -eq 0 ]; then echo "PASS"; else exit 1; fi
