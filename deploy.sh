#!/bin/bash
# cloudsync-lowspeed 部署脚本（需 root）
# 做三件事：装库 → 用 wrapper 占位真二进制并在 exec 时注入 LD_PRELOAD → 重启并验证
# 前置：把 cs_lowspeed.so 放到 /tmp
set -e

BIN=/var/packages/CloudSync/target/sbin/syno-cloud-syncd
REAL=${BIN}.real
SO_SRC=/tmp/cs_lowspeed.so
SO_DST=/var/packages/CloudSync/target/lib/cs_lowspeed.so
LOG=/tmp/cs_lowspeed.log

[ "$(id -u)" = "0" ] || { echo "请用 sudo 运行"; exit 1; }
[ -f "$SO_SRC" ] || { echo "缺少 $SO_SRC（先 scp 上来）"; exit 1; }

echo "--- 装库 ---"
install -m 755 -o root -g root "$SO_SRC" "$SO_DST"

if [ ! -f "$REAL" ]; then
    echo "--- 真二进制改名 .real，腾出 wrapper 位置 ---"
    mv "$BIN" "$REAL"
fi

echo "--- 写 wrapper ---"
cat > "$BIN" <<'WRAP'
#!/bin/sh
# cloudsync-lowspeed wrapper（勿删：真二进制在同目录 syno-cloud-syncd.real）
export LD_PRELOAD="/var/packages/CloudSync/target/lib/cs_lowspeed.so"
exec /var/packages/CloudSync/target/sbin/syno-cloud-syncd.real "$@" 2>>/tmp/cs_lowspeed.log
WRAP
chmod 755 "$BIN"
: > "$LOG"
ls -l "$BIN" "$REAL" "$SO_DST"

echo "--- 重启 CloudSync ---"
/usr/syno/bin/synopkg restart CloudSync
sleep 8

PID=$(cat /var/run/syno-cloud-syncd.pid 2>/dev/null)
echo "--- daemon pid = ${PID:-未启动} ---"
[ -n "$PID" ] && ps -p "$PID" -o pid,lstart,args

if [ -n "$PID" ] && grep -q "cs_lowspeed" "/proc/$PID/maps"; then
    echo "OK: shim 已注入 daemon（maps 里能看到 cs_lowspeed.so）"
    exit 0
fi

echo "FAIL: maps 未见 shim。排查："
if [ -n "$PID" ]; then
    echo "--- daemon environ 里的 LD_* ---"
    tr '\0' '\n' < "/proc/$PID/environ" | grep "^LD_" || echo "（没有：wrapper 的 export 没生效）"
    echo "--- 是否 AT_SECURE（文件能力/setuid 会让加载器忽略 LD_PRELOAD）---"
    grep -E "^Cap|^Uid|^Gid" "/proc/$PID/status" || true
fi
echo "--- daemon stderr（wrapper 引出来的）---"
cat "$LOG" 2>/dev/null || true
echo "--- 回滚 ---"
echo "  sudo mv ${REAL} ${BIN} && sudo synopkg restart CloudSync"
exit 1
