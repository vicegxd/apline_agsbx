#!/bin/sh
# ============================================================
#  argosbx 容器首装一键脚本
#  适用：Alpine + 小内存 LXC/NAT 容器（128MB 级）
#  做三件事： ① 装 argosbx  ② 低内存加固  ③ 打印节点与常用命令
#
#  用法（Alpine 默认只有 ash，用 sh 执行即可，脚本会自动补 bash）：
#    wget -qO /tmp/init.sh <本脚本地址> && sh /tmp/init.sh
#
#    自定义协议（所有 argosbx 变量都会透传给主脚本）：
#      hypt="20088" anpt="20088" sh /tmp/init.sh
#
#    想要稳字优先（hy2 限速 100Mbps）而不是贴极限：
#      PERF=0 HY2_MBPS=100 sh /tmp/init.sh
# ============================================================
export LANG=en_US.UTF-8

REPO="vicegxd/apline_agsbx"
BRANCH="main"
RAW="https://raw.githubusercontent.com/$REPO/$BRANCH"
WORK="/root/.agsbx-init"
mkdir -p "$WORK" 2>/dev/null

hr(){ echo "──────────────────────────────────────────────"; }

# ---------- 下载：直连失败自动切镜像 ----------
fetch(){
  _f="$1"; _o="$2"; _rm=1
  for _b in "$RAW" "https://ghfast.top/$RAW" "https://cdn.jsdelivr.net/gh/$REPO@$BRANCH"; do
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --max-time 60 "$_b/$_f" -o "$_o" 2>/dev/null
    else
      wget -qO "$_o" -T 60 "$_b/$_f" 2>/dev/null
    fi
    if [ -s "$_o" ]; then
      echo "  ✓ 已获取 $_f（源：$(echo "$_b" | awk -F/ '{print $3}')）"
      rm -f "$_rm" 2>/dev/null
      return 0
    fi
  done
  return 1
}

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "  argosbx 容器首装一键脚本"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# ---------- 0. 前置检查 ----------
echo "[0/4] 环境检查"
[ "$(id -u)" -eq 0 ] || { echo "  ❌ 请用 root 身份运行"; exit 1; }

case "$(uname -m)" in
  x86_64|amd64)  arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "  ❌ 不支持的架构：$(uname -m)"; exit 1 ;;
esac

mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
cg=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
case "$cg" in
  ''|max|*[!0-9]*) ;;
  *) cm=$((cg/1048576)); [ "$cm" -lt "${mem_mb:-99999}" ] && mem_mb=$cm ;;
esac
osver=$(cat /etc/alpine-release 2>/dev/null || echo "非Alpine")
echo "  架构 $arch ｜ 系统 Alpine $osver ｜ 可用内存 ${mem_mb:-未知}MB"
if [ -n "$mem_mb" ] && [ "$mem_mb" -lt 256 ]; then
  echo "  ⚠️ 内存偏小，稍后会自动启用低内存加固"
fi

# ---------- 协议默认值（只导出新赋值的，避免污染已设置状态）----------
if [ -z "${hypt:-}${anpt:-}${vlpt:-}${vmpt:-}${tupt:-}${xhpt:-}${vxpt:-}${sspt:-}${arpt:-}${sopt:-}${nvpt:-}${xupt:-}${xcpt:-}" ]; then
  hypt=20088; anpt=20088
  export hypt anpt
  echo "  未指定协议变量，使用默认：hysteria2 + anytls（端口 20088，UDP/TCP 不冲突）"
else
  echo "  按你指定的协议变量安装"
fi

# ---------- 确保有 bash（Alpine 默认只有 ash，而 argosbx 主脚本是 bash 脚本）----------
if ! command -v bash >/dev/null 2>&1; then
  echo "  系统没有 bash（Alpine 默认只有 ash），正在安装……"
  command -v apk >/dev/null 2>&1 && apk add --no-cache bash >/dev/null 2>&1
  if ! command -v bash >/dev/null 2>&1; then
    echo "  ❌ bash 安装失败，请先手动执行： apk add --no-cache bash"
    exit 1
  fi
  echo "  ✓ bash 已就绪"
fi

# ---------- 1. 安装主脚本 ----------
hr
if [ -x /root/agsbx/sing-box ] && pgrep -f 'agsbx/s' >/dev/null 2>&1; then
  echo "[1/4] 检测到 argosbx 已在运行，跳过安装"
  echo "      要重装请先执行： agsbx del    然后重跑本脚本"
else
  echo "[1/4] 安装 argosbx（这一步最慢，约 1~3 分钟，请勿中断）"
  if fetch argosbx-opt.sh "$WORK/argosbx.sh"; then
    bash "$WORK/argosbx.sh"
    echo "  ✓ 安装流程结束"
  else
    echo "  ❌ 主脚本三个源都下载失败，请检查网络后重试"
    exit 1
  fi
fi

# ---------- 2. 低内存加固 ----------
hr
echo "[2/4] 应用低内存加固"
if fetch agsbx-128mb-tune.sh "$WORK/agsbx-128mb-tune.sh"; then
  cp "$WORK/agsbx-128mb-tune.sh" /root/agsbx.sh 2>/dev/null
  PERF=${PERF:-1} bash "$WORK/agsbx-128mb-tune.sh"
else
  echo "  ⚠️ 加固脚本下载失败，跳过（不影响节点可用性）"
fi

# ---------- 3. 运行状态 ----------
hr
echo "[3/4] 当前运行状态"
if command -v rc-service >/dev/null 2>&1; then
  for s in sing-box xray argo; do
    [ -f "/etc/init.d/$s" ] && printf "  %-10s %s\n" "$s" "$(rc-service "$s" status 2>&1)"
  done
else
  echo "  （非 OpenRC 系统，跳过服务状态检查）"
fi
if [ -f /root/agsbx.sh ]; then
  echo -n "  "
  bash /root/agsbx.sh peak 2>/dev/null
fi

# ---------- 4. 后续操作 ----------
hr
echo "[4/4] 接下来怎么用"
cat <<'TIP'
  ▸ 重连一次 SSH，让 agsbx 快捷命令生效（Alpine 的 .profile 需要重新加载）

  ▸ 查看节点：       agsbx list
  ▸ 查看内存峰值：   bash /root/agsbx.sh peak
  ▸ 重置峰值基线：   bash /root/agsbx.sh peak reset
  ▸ 重启全部进程：   agsbx res
  ▸ 换协议/重装：    agsbx del    然后重跑本脚本
  ▸ 彻底卸载：       agsbx del

  ⚠️ NAT 机务必注意：
     节点信息里的端口是容器【内网端口】，客户端要用控制面板上映射的
     【公网 IP + 公网端口】。若面板没做映射，外部连不上属正常现象。
TIP
echo
