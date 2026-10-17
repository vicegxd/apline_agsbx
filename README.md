# apline_agsbx

针对 **Alpine 3.23 + 128MB LXC/NAT 容器** 的 argosbx 优化脚本。

原脚本的死穴是：进程崩了没人管、Go 内核又不约束内存 —— 小内存机器上最典型的死法就是内存涨上去被 OOM 杀掉、节点静默掉线，或者触发 cgroup 整组杀把整个容器拖重启。这几个脚本就是修这条链路的。

## 文件

| 文件 | 用途 | 什么时候用 |
|---|---|---|
| `agsbx-128mb-tune.sh` | 低内存加固脚本 | **已装好 argosbx 的机器直接跑**，无需重装 |
| `argosbx-opt.sh` | 优化后的 argosbx 主脚本，用法与原脚本一致 | 首次安装 / 重装时 |
| `argosbx-低内存优化说明.md` | 改动清单、原理、用法与取舍 | 想了解细节时 |

## 一键加固

贴极限模式（不限速、不节流，只保容器不崩）：

```bash
wget -qO /tmp/agsbx.sh https://raw.githubusercontent.com/vicegxd/apline_agsbx/main/agsbx-128mb-tune.sh && [ -s /tmp/agsbx.sh ] && PERF=1 bash /tmp/agsbx.sh
```

稳字优先（hy2 限速 100Mbps，不崩也不卡）：

```bash
wget -qO /tmp/agsbx.sh https://raw.githubusercontent.com/vicegxd/apline_agsbx/main/agsbx-128mb-tune.sh && HY2_MBPS=100 bash /tmp/agsbx.sh
```

下载过一次之后可以复用（摸自己的内存极限）：

```bash
bash /tmp/agsbx.sh peak reset    # 测速前重置内存峰值基线
bash /tmp/agsbx.sh peak          # 测速后查看峰值
```

VPS 拉不动 `raw.githubusercontent.com` 时，启用镜像源：

```bash
R=https://raw.githubusercontent.com/vicegxd/apline_agsbx/main/agsbx-128mb-tune.sh; for u in "$R" "https://ghfast.top/$R" "https://cdn.jsdelivr.net/gh/vicegxd/apline_agsbx@main/agsbx-128mb-tune.sh"; do wget -qO /tmp/agsbx.sh "$u" && [ -s /tmp/agsbx.sh ] && break; done; [ -s /tmp/agsbx.sh ] && PERF=1 bash /tmp/agsbx.sh
```

## 重装主脚本

```bash
wget -qO /tmp/argosbx.sh https://raw.githubusercontent.com/vicegxd/apline_agsbx/main/argosbx-opt.sh && hypt="20088" anpt="20088" bash /tmp/argosbx.sh
```

## 主要改动

- OpenRC 服务改用 `supervise-daemon`：进程崩溃 3 秒自动拉起，不再静默掉线
- 给 sing-box / xray / cloudflared 设 `GOGC` + `GOMEMLIMIT`（Go 内存软上限）
- **内存判断改读 cgroup 配额** —— 容器内 `/proc/meminfo` 显示的是宿主机内存，照它判断会让整套加固静默失效
- 容器内自救 `memory.oom.group = 0`：OOM 只杀单个进程，容器不再整体重启
- 补装 Alpine 缺失依赖：`curl`、`ca-certificates`、`chrony`（原脚本的 apk 清单里漏了 curl）
- 修复 Alpine 下 `agsbx` 快捷命令失效 —— ash 不读 `.bashrc`，只读 `.profile`

完整改动清单、原理和取舍说明见 `argosbx-低内存优化说明.md`。
