#!/bin/bash
# 只读观测 CloudSync → WebDAV → 云盘 的上传状态（无需 root）
# 用法：bash watch.sh [同步目录] [分钟数，默认5]
#
# 输出说明：
#   外发≈持续数十 Mbit/s、loopback≈0  → 正在向云盘转传（客户端此时是静默的）
#   loopback 出现大尖峰、外发掉到 0   → 正在收 body，即正在读本地文件上传
DIR=${1:-}
MIN=${2:-5}

tx(){ awk '/eth0/{print $10}' /proc/net/dev; }
lo(){ awk '/ lo:/{print $2}' /proc/net/dev; }

echo "时间     外发M  loopbackM  说明"
ptx=$(tx); plo=$(lo)
for _ in $(seq 1 $((MIN*12))); do
    sleep 5
    t=$(tx); l=$(lo)
    txr=$(( (t-ptx)*8/5/1000000 )); lom=$(( (l-plo)/5/1024/1024 ))
    if [ "$lom" -ge 5 ]; then note="收 body（读本地文件中）"
    elif [ "$txr" -ge 5 ]; then note="向云盘转传（客户端静默期）"
    else note="无传输"; fi
    printf '%s  %5d  %8d  %s\n' "$(date +%T)" "$txr" "$lom" "$note"
    ptx=$t; plo=$l
done

echo
echo "=== 云端守护进程 ==="
ps -e -o pid,lstart,args | grep cloud-syncd | grep -v grep || echo "  未运行"

if [ -n "$DIR" ] && [ -d "$DIR" ]; then
    echo "=== $DIR 下文件的读取时间 ==="
    # 注意：relatime 下 24 小时内的重复读取不会刷新 atime，此列只能说明"至少读过一次"
    find "$DIR" -maxdepth 2 -type f -printf '  %A+  %p\n' | sed "s#$DIR/##" | head -20
fi

echo "=== history 写入时间（daemon 活动痕迹）==="
stat -c "  %y" /volume1/@cloudsync/db/history.sqlite 2>/dev/null || echo "  不存在"
