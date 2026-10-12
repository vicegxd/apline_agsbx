#!/bin/bash
# ============================================================
#  argosbx 低内存加固脚本（针对 ≤256MB 内存的 Alpine / OpenRC VPS）
#  作用：对【已经安装好】的 argosbx 现场加固，无需重装、无需改配置
#  用法：bash agsbx-128mb-tune.sh
#  卸载：把三个 service 文件还原为普通守护即可，或直接重跑原版 argosbx rep
# ============================================================
export LANG=en_US.UTF-8
[ "$(id -u)" -eq 0 ] || { echo "❌ 请用 root 身份运行"; exit 1; }
AGS="$HOME/agsbx"
[ -d "$AGS" ] || AGS="/root/agsbx"

# PERF=1 → 贴极限模式：不节流、不限速、不动窗口，只保证容器不崩 + 进程自动恢复
PERF=${PERF:-0}

# ---------- 内置小工具：测速前后观察内存峰值 ----------
# 用法：bash agsbx-128mb-tune.sh peak          查看峰值 / 当前 / 上限
#       bash agsbx-128mb-tune.sh peak reset   重置峰值基线（测速前先跑这个）
if [ "${1:-}" = "peak" ]; then
  CG=/sys/fs/cgroup
  f="$CG/memory.peak"
  [ -f "$f" ] || { echo "本环境没有 memory.peak（需要 cgroup v2），无法统计峰值"; exit 0; }
  c=$(cat "$CG/memory.current" 2>/dev/null); c=${c:-0}
  if [ "${2:-}" = "reset" ]; then
    if echo reset > "$f" 2>/dev/null; then
      echo "已重置峰值基线（基线 = 当前用量 $((c/1048576))MB）"
      echo "现在去测速，完事后再执行：bash $0 peak"
    else
      echo "memory.peak 不可写，无法重置"
    fi
    exit 0
  fi
  p=$(cat "$f" 2>/dev/null); p=${p:-0}
  mx=$(cat "$CG/memory.max" 2>/dev/null)
  case "$mx" in ''|max) mx="无限制" ;; *) mx="$((mx/1048576))MB" ;; esac
  echo "内存峰值：$((p/1048576))MB   当前：$((c/1048576))MB   硬上限：$mx"
  exit 0
fi

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo " argosbx 低内存加固（128MB 级 VPS 专用）"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# ---------- 0. 环境探测（容器内 meminfo 显示宿主机内存，必须读 cgroup 配额） ----------
inc=no
[ -f /.dockerenv ] && inc=yes
[ "$inc" = no ] && tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -q '^container=' && inc=yes
[ "$inc" = no ] && grep -qaE 'lxc|docker|containerd|podman' /proc/1/cgroup 2>/dev/null && inc=yes
[ "$inc" = no ] && grep -qa 'lxcfs' /proc/self/mountinfo 2>/dev/null && inc=yes

mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
host_mb=$mem_mb
cgmem=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
[ -z "$cgmem" ] && cgmem=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
case "$cgmem" in
  ''|*[!0-9]*) ;;
  *) if [ "$cgmem" -lt 1000000000000 ]; then
       cgm=$((cgmem/1048576))
       [ "$cgm" -lt "${mem_mb:-999999}" ] && mem_mb=$cgm
     fi ;;
esac
swap_mb=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
disk_mb=$(df -m / 2>/dev/null | awk 'NR==2{print $4}')
if [ "$inc" = yes ]; then
  echo "运行环境：容器（LXC / Docker / Podman）"
  echo "可用内存配额：${mem_mb:-未知}MB   可见交换：${swap_mb:-0}MB   根分区可用：${disk_mb:-未知}MB"
  [ -n "$host_mb" ] && [ "$host_mb" != "$mem_mb" ] && echo "（注：/proc/meminfo 显示宿主机 ${host_mb}MB，已改用 cgroup 配额 ${mem_mb}MB 判断）"
else
  echo "运行环境：物理机 / 虚拟机"
  echo "内存：${mem_mb:-未知}MB   交换：${swap_mb:-0}MB   根分区可用：${disk_mb:-未知}MB"
fi
[ -d "$AGS" ] && echo "检测到 argosbx 安装目录：$AGS" || echo "⚠️ 未找到 $AGS，仅执行系统层加固"
echo

# ---------- 1. Alpine 依赖补全（原脚本漏装 curl / CA 证书 / 时钟） ----------
if command -v apk >/dev/null 2>&1; then
  echo "[1/6] 补全 Alpine 依赖（curl / ca-certificates / procps / chrony / crond）……"
  apk update >/dev/null 2>&1
  apk add --no-cache bash busybox-extras ca-certificates coreutils curl gcompat libc6-compat iptables openssl procps chrony >/dev/null 2>&1
  update-ca-certificates >/dev/null 2>&1
  rc-update add crond default >/dev/null 2>&1; rc-service crond start >/dev/null 2>&1
  if ! pgrep -x chronyd >/dev/null 2>&1; then
    rc-update add chronyd default >/dev/null 2>&1; rc-service chronyd start >/dev/null 2>&1
  fi
else
  echo "[1/6] 非 Alpine 系统，跳过 apk 依赖补全"
fi

# ---------- 2. 创建 swap（低内存防 OOM 最有效的一招） ----------
echo "[2/6] 检查交换空间……"
if [ "${swap_mb:-0}" -ge 64 ]; then
  echo "     已有 ${swap_mb}MB swap，跳过"
elif [ "$inc" = yes ]; then
  echo "     ⚠️ 容器内一般无法 swapon，跳过创建交换文件"
  echo "        容器要加 swap 必须在【宿主机】侧配置，例如 LXC / Proxmox 配置里加："
  echo "          lxc.cgroup2.memory.max = 128M"
  echo "          lxc.cgroup2.memory.swap.max = 256M    # 宿主机本身需先有可用 swap"
elif [ "${disk_mb:-0}" -lt 700 ]; then
  echo "     ⚠️ 磁盘可用空间不足 700MB，跳过创建 swap"
else
  echo "     未启用 swap，正在创建 256MB 交换文件（内存不足时救命的缓冲）……"
  dd if=/dev/zero of=/swapfile bs=1M count=256 >/dev/null 2>&1
  chmod 600 /swapfile >/dev/null 2>&1
  if mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile >/dev/null 2>&1; then
    echo "     ✅ swap 已启用"
    grep -q '^/swapfile' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  else
    echo "     ⚠️ 本环境不支持 swapon，已清理临时文件（不占用磁盘）"
    swapoff /swapfile >/dev/null 2>&1
    rm -f /swapfile
  fi
fi

# ---------- 3. 内存回收参数 ----------
echo "[3/6] 调整内核内存回收策略……"
sysctl -w vm.swappiness=100 >/dev/null 2>&1
if [ "$inc" = yes ]; then
  echo "     ⓘ 容器内 vm.* 属于内核全局参数，由宿主机控制，容器里设置无效（已跳过持久化）"
else
  sysctl -w vm.vfs_cache_pressure=200 >/dev/null 2>&1
  grep -q '^vm.swappiness' /etc/sysctl.conf 2>/dev/null || {
    echo 'vm.swappiness=100' >> /etc/sysctl.conf
    echo 'vm.vfs_cache_pressure=200' >> /etc/sysctl.conf
  }
  echo "     ✅ 已写入 /etc/sysctl.conf 持久化"
fi

# ---------- 3b. OOM 诊断与防护（测速 / 大流量把容器拖重启的根因排查） ----------
CG=/sys/fs/cgroup
if [ -r "$CG/memory.events" ]; then
  echo "[3b] 检查 cgroup 内存压力与 OOM 记录……"
  ev_oom=$(awk '/^oom /{print $2}' "$CG/memory.events" 2>/dev/null)
  ev_kill=$(awk '/^oom_kill /{print $2}' "$CG/memory.events" 2>/dev/null)
  ev_max=$(awk '/^max /{print $2}' "$CG/memory.events" 2>/dev/null)
  cur=$(cat "$CG/memory.current" 2>/dev/null)
  if [ -n "$cur" ]; then cur_mb=$((cur/1048576)); else cur_mb="?"; fi
  pk=$(cat "$CG/memory.peak" 2>/dev/null)
  if [ -n "$pk" ]; then peak_mb=$((pk/1048576)); else peak_mb="?"; fi
  og=$(cat "$CG/memory.oom.group" 2>/dev/null)
  echo "     历史 OOM 触发：${ev_oom:-?} 次   被杀进程：${ev_kill:-?} 个   内存触顶：${ev_max:-?} 次"
  echo "     当前用量：${cur_mb}MB   历史峰值：${peak_mb}MB   硬上限：${mem_mb:-?}MB"
  if [ "$og" = "1" ]; then
    echo "     ⚠️ memory.oom.group=1：触发 OOM 时会杀掉容器内【所有】进程，"
    echo "        这正是容器整体重启的直接原因。请在宿主机把 lxc.cgroup2.memory.oom.group 设为 0。"
  fi
  if [ "$PERF" = "1" ]; then
    echo "     ⏭ memory.high：贴极限模式跳过（节流会直接压低带宽）"
  elif [ -f "$CG/memory.high" ] && [ -n "$mem_mb" ]; then
    high_mb=$(( mem_mb * 75 / 100 ))
    if echo "${high_mb}M" > "$CG/memory.high" 2>/dev/null; then
      echo "     ✅ 已设 memory.high=${high_mb}M：内存逼近上限时先节流回收，避免直接 OOM 杀进程"
      echo "        代价：逼近上限那一刻会短暂卡顿，换来的是容器不会整体重启"
    else
      echo "     ⓘ memory.high 不可写（LXC 未开放 cgroup 写权限），跳过"
      echo "       可在宿主机加：lxc.cgroup2.memory.high = ${high_mb}M"
    fi
  fi
  # 关掉"整组 OOM 杀"——这是容器整体重启的直接原因，若 cgroup 可写就能在容器内自救
  if [ "$og" != "0" ] && [ -f "$CG/memory.oom.group" ]; then
    if echo 0 > "$CG/memory.oom.group" 2>/dev/null; then
      echo "     ✅ 已把 memory.oom.group 置 0：此后 OOM 只杀单个进程，容器不会整体重启"
    else
      echo "     ⓘ memory.oom.group 只读，容器内关不掉整组杀（只能靠宿主机改）"
    fi
  fi
fi

# ---------- 3c. socket 缓冲上限（netns 局部参数，容器内可写，且不影响宿主机与其它容器） ----------
SOCK_MAX=${SOCK_MAX:-2097152}
netune(){
  cur=$(sysctl -n "$1" 2>/dev/null | awk '{print $NF}')
  # 只在当前值确实偏大时才下调，避免把本来很小的环境反而调大
  if [ -n "$cur" ] && [ "$cur" -gt "$3" ] 2>/dev/null; then
    if sysctl -w "$1=$2" >/dev/null 2>&1; then
      grep -q "^$1" /etc/sysctl.conf 2>/dev/null || echo "$1 = $2" >> /etc/sysctl.conf
      return 0
    fi
  fi
  return 1
}
if [ "$PERF" = "1" ]; then
  echo "[3c] ⏭ 贴极限模式：保留默认 socket 缓冲（下调 TCP 窗口会直接压低吞吐）"
else
  n1=0
  netune net.core.rmem_max "$SOCK_MAX" "$SOCK_MAX" && n1=$((n1+1))
  netune net.core.wmem_max "$SOCK_MAX" "$SOCK_MAX" && n1=$((n1+1))
  netune net.ipv4.tcp_rmem "4096 87380 $SOCK_MAX" "$SOCK_MAX" && n1=$((n1+1))
  netune net.ipv4.tcp_wmem "4096 65536 $SOCK_MAX" "$SOCK_MAX" && n1=$((n1+1))
  if [ "$n1" -gt 0 ]; then
    echo "[3c] socket 缓冲上限已下调至 $((SOCK_MAX/1024))KB（$n1/4 项已改）"
    echo "     测速时内核侧缓冲不再无限膨胀；代价是 RTT 高时吞吐受限。"
    echo "     嫌慢可重跑并调高：SOCK_MAX=6291456 bash $0"
  else
    echo "[3c] ⓘ socket 缓冲参数无需调整或不可写（部分 NAT 容器限制 net.*），跳过"
  fi
fi

# ---------- 4. 依据内存档位决定内核内存上限 ----------
if [ "$PERF" = "1" ] && [ -n "$mem_mb" ]; then
  # 贴极限：给 Go 更多堆预算 + 更宽松的 GC（GC 太频繁会白烧 CPU 却压不下活跃缓冲）
  GOGC=50
  L_SB=$(( mem_mb * 40 / 100 ))
  [ "$L_SB" -gt 64 ] && L_SB=64
  [ "$L_SB" -lt 20 ] && L_SB=20
  L_XR=$L_SB
  L_CF=$(( L_SB / 2 ))
elif   [ "${mem_mb:-0}" -lt 192 ]; then GOGC=30; L_SB=40; L_XR=40; L_CF=24
elif [ "${mem_mb:-0}" -lt 512 ]; then GOGC=50; L_SB=48; L_XR=48; L_CF=32
else                                GOGC=0;  L_SB=0;  L_XR=0;  L_CF=0
fi
echo "[4/6] 内核内存档位：GOGC=${GOGC:-默认}  sing-box=${L_SB}MiB  xray=${L_XR}MiB  argo=${L_CF}MiB"

# ---------- 4b. 可选：给 hysteria2 加带宽上限，压制测速时的内存峰值 ----------
# 用法：HY2_MBPS=100 bash agsbx-128mb-tune.sh
if [ -n "${HY2_MBPS:-}" ] && [ -f "$AGS/sb.json" ]; then
  if ! grep -q 'hysteria2' "$AGS/sb.json" 2>/dev/null; then
    echo "[4b] 配置里没有 hysteria2 入站，跳过带宽限制"
  else
    echo "[4b] 给 hysteria2 设置带宽上限 ${HY2_MBPS}Mbps……"
    cp "$AGS/sb.json" "$AGS/sb.json.bak"
    # up_mbps/down_mbps 与 ignore_client_bandwidth 语义冲突，必须替换而不是追加。
    # 后两条规则用于"重复调整带宽值"的场景：字段已存在时直接更新数值。
    sed -i \
      -e 's/"ignore_client_bandwidth"[[:space:]]*:[[:space:]]*false,/  "up_mbps": '"$HY2_MBPS"', "down_mbps": '"$HY2_MBPS"',/' \
      -e 's/"up_mbps"[[:space:]]*:[[:space:]]*[0-9][0-9]*/"up_mbps": '"$HY2_MBPS"'/' \
      -e 's/"down_mbps"[[:space:]]*:[[:space:]]*[0-9][0-9]*/"down_mbps": '"$HY2_MBPS"'/' \
      "$AGS/sb.json"
    if ! grep -q '"up_mbps"' "$AGS/sb.json" 2>/dev/null; then
      echo "     ⓘ 没找到可替换的带宽字段，已还原（该配置写法不同）"
      cp "$AGS/sb.json.bak" "$AGS/sb.json"
    elif [ -x "$AGS/sing-box" ] && "$AGS/sing-box" check -c "$AGS/sb.json" >/dev/null 2>&1; then
      echo "     ✅ 已写入并通过 sing-box check 校验（原配置备份为 sb.json.bak）"
    else
      echo "     ⚠️ 配置校验未通过，已还原原配置"
      cp "$AGS/sb.json.bak" "$AGS/sb.json"
    fi
  fi
fi

# ---------- 5. 用 supervise-daemon 重写 OpenRC 服务（崩溃自动拉起 + 内存上限 + 单实例） ----------
if command -v rc-service >/dev/null 2>&1; then
  echo "[5/6] 重写 OpenRC 服务为 supervise-daemon 守护模式……"

  kill_stale(){
    for P in /proc/[0-9]*; do
      [ -L "$P/exe" ] || continue
      T=$(readlink -f "$P/exe" 2>/dev/null) || continue
      case "$T" in *"/agsbx/$1"*) kill -15 "$(basename "$P")" 2>/dev/null ;; esac
    done
  }

  # sing-box
  if [ -x "$AGS/sing-box" ]; then
    rc-service sing-box stop >/dev/null 2>&1
    kill_stale s
    [ "$L_SB" -gt 0 ] && LIM_SB="supervise_daemon_args=\"--env GOGC=$GOGC --env GOMEMLIMIT=${L_SB}MiB\"" || LIM_SB=""
    cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
description="sb service"
supervisor="supervise-daemon"
command="$AGS/sing-box"
command_args="run -c $AGS/sb.json"
pidfile="/run/sing-box.pid"
${LIM_SB}
respawn_delay=3
respawn_period=30
respawn_max=0
depend() {
need net
}
EOF
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default >/dev/null 2>&1
    rc-service sing-box start >/dev/null 2>&1 && echo "     ✅ sing-box 已按新方式守护"
  fi

  # xray
  if [ -x "$AGS/xray" ]; then
    rc-service xray stop >/dev/null 2>&1
    kill_stale x
    [ "$L_XR" -gt 0 ] && LIM_XR="supervise_daemon_args=\"--env GOGC=$GOGC --env GOMEMLIMIT=${L_XR}MiB\"" || LIM_XR=""
    cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
description="xr service"
supervisor="supervise-daemon"
command="$AGS/xray"
command_args="run -c $AGS/xr.json"
pidfile="/run/xray.pid"
${LIM_XR}
respawn_delay=3
respawn_period=30
respawn_max=0
depend() {
need net
}
EOF
    chmod +x /etc/init.d/xray
    rc-update add xray default >/dev/null 2>&1
    rc-service xray start >/dev/null 2>&1 && echo "     ✅ xray 已按新方式守护"
  fi

  # argo（固定隧道，token 从原服务文件里原样搬运）
  if [ -f /etc/init.d/argo ] && [ -x "$AGS/cloudflared" ]; then
    TOKEN=$(sed -n 's/.*--token \(.*\)"[[:space:]]*$/\1/p' /etc/init.d/argo 2>/dev/null | head -n1)
    if [ -n "$TOKEN" ]; then
      rc-service argo stop >/dev/null 2>&1
      kill_stale c
      [ "$L_CF" -gt 0 ] && LIM_CF="supervise_daemon_args=\"--env GOGC=$GOGC --env GOMEMLIMIT=${L_CF}MiB\"" || LIM_CF=""
      cat > /etc/init.d/argo <<EOF
#!/sbin/openrc-run
description="argo service"
supervisor="supervise-daemon"
command="$AGS/cloudflared tunnel"
command_args="--no-autoupdate --edge-ip-version auto --protocol http2 run --token $TOKEN"
pidfile="/run/argo.pid"
${LIM_CF}
respawn_delay=3
respawn_period=30
respawn_max=0
depend() {
need net
}
EOF
      chmod +x /etc/init.d/argo
      rc-update add argo default >/dev/null 2>&1
      rc-service argo start >/dev/null 2>&1 && echo "     ✅ argo(cloudflared) 已按新方式守护"
    else
      echo "     ⓘ argo 使用临时隧道模式，保持原样（不接管）"
    fi
  fi
else
  echo "[5/6] 非 OpenRC 系统，跳过服务重写"
fi

# ---------- 6. Alpine 下修正 agsbx 快捷命令（ash 不读 .bashrc） ----------
echo "[6/6] 修正 agsbx 快捷命令的 PATH 生效位置……"
if [ -f /etc/alpine-release ]; then
  sed -i '/export PATH="\$HOME\/bin:\$PATH"/d' "$HOME/.profile" 2>/dev/null
  echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.profile"
  echo "     已写入 ~/.profile（Alpine 的 ash 登录 shell 只读这里，重连 SSH 生效）"
fi

# ---------- 汇总 ----------
echo
if [ "$PERF" = "1" ]; then
  echo "🚀 贴极限模式已生效：不限速、不节流、不改 TCP 窗口，一切让位给速度。"
  echo "   代价与兜底：内存触顶时 sing-box 会被内核杀掉，但【容器不会整体重启】，"
  echo "               3 秒后由 supervise-daemon 自动拉起。测速掉一下属预期行为。"
  echo
  echo "   想知道极限在哪，先重置基线再测速："
  echo "     bash $0 peak reset    # 然后去测速"
  echo "     bash $0 peak          # 回来看峰值"
  echo
elif [ -f "$AGS/sb.json" ] && grep -q 'hysteria2' "$AGS/sb.json" 2>/dev/null && ! grep -q '"up_mbps"' "$AGS/sb.json" 2>/dev/null; then
  echo "💡 hysteria2 还没设带宽上限 —— 它是测速时内存峰值的主要来源。"
  echo "   想两个协议都保留，可以：HY2_MBPS=100 bash $0"
  echo "   想贴着极限跑，可以：PERF=1 bash $0"
  echo
fi
echo "================== 加固完成 =================="
if [ "$inc" = yes ]; then
  echo "当前容器内存占用情况（本机 cgroup 视角）："
else
  echo "当前内存占用情况："
fi
free -m 2>/dev/null | sed 's/^/  /'
echo
echo "服务状态："
if command -v rc-service >/dev/null 2>&1; then
  for s in sing-box xray argo; do
    [ -f "/etc/init.d/$s" ] && rc-service "$s" status 2>&1 | sed 's/^/  /'
  done
fi
echo
if [ "$inc" = yes ] && [ "$(cat /proc/1/comm 2>/dev/null)" != "init" ]; then
  echo "⚠️ 容器 PID 1 不是 init：OpenRC 服务在【重启容器后不会自动启动】，"
  echo "   建议把容器启动命令改为 /sbin/init，或在 /etc/local.d/ 里补自启脚本。"
  echo
fi
echo "提示：内存紧张时可用 rc-service sing-box status 查看守护状态，"
echo "      异常退出会被自动拉起（respawn_max=0 表示无限次）。"
