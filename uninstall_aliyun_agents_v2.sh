#!/usr/bin/env bash
# ================================================================
# 阿里云 ECS 监控组件一键彻底卸载脚本 v2.0
# ----------------------------------------------------------------
# 涵盖：
#   - 云盾 / 安骑士  (aegis / AliYunDun / AliYunDunMonitor)
#   - 云监控        (CloudMonitor / CmsGoAgent)
#   - 云助手        (aliyun-service / assist_daemon)
#
# 前置条件（必须先做，否则脚本无效）：
#   登录 云安全中心控制台 → 设置 → 客户端自保护设置
#   找到本机 → 关闭"客户端自保护"和"恶意主机行为防御"
#
# 用法：
#   sudo bash uninstall_aliyun_agents.sh         # 交互式
#   sudo bash uninstall_aliyun_agents.sh --yes   # 跳过确认
#
# 退出码：
#   0  - 完全清理成功
#   1  - 有残留（需进一步处理）
#   2  - 环境/参数错误（root 检查、依赖检查未通过）
#
# v2 相对 v1 的改进：
#   - 修复进程匹配 bug（comm 字段 15 字符截断问题）
#   - 加入退出码反馈（便于自动化集成）
#   - 加入 cron 任务扫描
#   - 加入 log/tmp 文件清理
#   - TTY 检测，避免日志文件被颜色码污染
#   - 下载校验（防止 wget 拿到 HTML 错误页）
#   - trap 清理临时目录
# ================================================================

set -u

# ---------- 颜色输出（仅在 TTY 下启用）----------
if [[ -t 1 ]]; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'
else
    R=''; G=''; Y=''; B=''; N=''
fi
log()  { echo -e "${B}[INFO]${N} $*"; }
ok()   { echo -e "${G}[ OK ]${N} $*"; }
warn() { echo -e "${Y}[WARN]${N} $*"; }
err()  { echo -e "${R}[ERR ]${N} $*"; }

# ---------- 全局状态 ----------
RESIDUE_COUNT=0  # 残留计数，用于决定退出码
TMPDIR=""

# ---------- 退出时清理 TMPDIR ----------
cleanup() {
    [[ -n "$TMPDIR" && -d "$TMPDIR" ]] && rm -rf "$TMPDIR"
}
trap cleanup EXIT INT TERM

# ---------- 0. 前置检查 ----------
if [[ $EUID -ne 0 ]]; then
    err "请用 root 或 sudo 运行"
    exit 2
fi

# 关键依赖检查
for cmd in chattr pkill pgrep wget systemctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        err "缺少必要命令: $cmd（建议安装：apt-get install -y e2fsprogs procps wget systemd）"
        exit 2
    fi
done

AUTO_YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && AUTO_YES=1

cat <<'EOF'
================================================================
        阿里云监控组件一键卸载脚本 v2.0
================================================================
本脚本会彻底卸载：
  - 云盾 / 安骑士  (aegis / AliYunDun)
  - 云监控        (CloudMonitor)
  - 云助手        (aliyun-service / assist_daemon)

⚠️  前置条件（必须先在网页控制台完成）：
    云安全中心 → 设置 → 客户端自保护设置
    → 关闭本机的"客户端自保护"和"恶意主机行为防御"

否则即使本地清理干净，云端仍会通过云助手通道重新拉起 aegis。
================================================================
EOF

if [[ $AUTO_YES -ne 1 ]]; then
    read -rp "已确认控制台自保护已关闭，继续? [y/N] " ans
    [[ "$ans" != "y" && "$ans" != "Y" ]] && { warn "已取消"; exit 0; }
fi

# ================================================================
# Step 1/7: 运行官方卸载脚本
# ================================================================
log "Step 1/7: 尝试运行官方卸载脚本..."

TMPDIR=$(mktemp -d)
pushd "$TMPDIR" >/dev/null

for url in \
    "http://update2.aegis.aliyun.com/download/uninstall.sh" \
    "http://update2.aegis.aliyun.com/download/quartz_uninstall.sh"; do
    fname=$(basename "$url")
    if wget -q --timeout=10 "$url" -O "$fname" 2>/dev/null; then
        # 校验下载内容确实是 shell 脚本（防止拿到 HTML 错误页）
        if [[ -s "$fname" ]] && head -c 4 "$fname" | grep -q '^#!'; then
            chmod +x "$fname"
            if ./"$fname" >/dev/null 2>&1; then
                ok "已运行 $fname"
            else
                warn "$fname 执行返回非 0（不影响后续步骤）"
            fi
        else
            warn "$fname 下载内容不是有效脚本（可能是 HTML 错误页），跳过"
        fi
    else
        warn "下载 $fname 失败（可能 Agent 已离线/无网络，跳过）"
    fi
done

popd >/dev/null

# ================================================================
# Step 2/7: 优雅停止 CloudMonitor / 云助手
# ================================================================
log "Step 2/7: 停止 CloudMonitor / 云助手..."

# CloudMonitor (Go agent，新机器都是这个)
for arch in amd64 386 arm64; do
    bin="/usr/local/cloudmonitor/CmsGoAgent.linux-${arch}"
    if [[ -x "$bin" ]]; then
        "$bin" stop      >/dev/null 2>&1
        "$bin" uninstall >/dev/null 2>&1
        ok "CmsGoAgent (${arch}) 已停止并卸载"
    fi
done

# 云助手守护进程
if [[ -x /usr/local/share/assist-daemon/assist_daemon ]]; then
    /usr/local/share/assist-daemon/assist_daemon --stop   >/dev/null 2>&1
    /usr/local/share/assist-daemon/assist_daemon --delete >/dev/null 2>&1
    ok "assist_daemon 已停止"
fi

# 云助手 systemd 服务
systemctl stop    aliyun.service 2>/dev/null && ok "aliyun.service 已停止"
systemctl disable aliyun.service 2>/dev/null

# ================================================================
# Step 3/7: 强杀残留进程 (使用 pgrep -f 避开 comm 字段截断 bug)
# ----------------------------------------------------------------
# 【v2 修复】v1 使用 pkill -x，但 Linux 内核 /proc/PID/comm 字段
# 最长 15 字符，AliYunDunMonitor (16) / CmsGoAgent.linux-amd64 (22)
# 等长名进程会被截断，导致 -x 精确匹配失败、漏杀。
# 改用 pgrep -f 全命令行匹配，配合路径前缀避免误伤。
# ================================================================
log "Step 3/7: 强杀残留进程..."

# 使用路径前缀做匹配，绝对不会误伤其他进程
PROC_PATTERNS=(
    "/usr/local/aegis"
    "/usr/local/cloudmonitor"
    "/usr/local/share/assist-daemon"
    "/usr/local/share/aliyun-assist"
    "/usr/sbin/aliyun-service"
    "/usr/sbin/aliyun_installer"
    # 进程名级别的兜底（短名，无截断风险）
    "AliYunDun"
    "AliSecGuard"
    "AliSecureCheck"
    "argusagent"
)

for pattern in "${PROC_PATTERNS[@]}"; do
    pids=$(pgrep -f "$pattern" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        # shellcheck disable=SC2086
        kill -9 $pids 2>/dev/null
        ok "killed processes matching: $pattern (PIDs: $(echo $pids | tr '\n' ' '))"
    fi
done

# 等待进程真正退出
sleep 1

# ================================================================
# Step 4/7: 解除 immutable 属性 (chattr -i)
# 【整个流程的关键】
# ================================================================
log "Step 4/7: 解除文件锁定 (chattr -i)..."

LOCK_PATHS=(
    /usr/local/aegis
    /usr/local/cloudmonitor
    /usr/local/share/aliyun-assist
    /usr/local/share/assist-daemon
    /usr/sbin/aliyun-service
    /usr/sbin/aliyun-service.backup
    /usr/sbin/aliyun_installer
    /etc/init.d/agentwatch
    /etc/init.d/aegis
)
for p in "${LOCK_PATHS[@]}"; do
    if [[ -e "$p" ]]; then
        chattr -R -ia "$p" 2>/dev/null && ok "解锁 $p"
    fi
done

# ================================================================
# Step 5/7: 删除文件和目录
# ================================================================
log "Step 5/7: 删除文件和目录..."

DEL_DIRS=(
    /usr/local/aegis
    /usr/local/cloudmonitor
    /usr/local/share/aliyun-assist
    /usr/local/share/assist-daemon
    /etc/init.d/agentwatch
    /etc/init.d/aegis
)
DEL_FILES=(
    /usr/sbin/aliyun-service
    /usr/sbin/aliyun-service.backup
    /usr/sbin/aliyun_installer
    /etc/systemd/system/aliyun.service
    /lib/systemd/system/aliyun.service
)

for d in "${DEL_DIRS[@]}"; do
    [[ -e "$d" ]] && rm -rf "$d" 2>/dev/null && ok "删除目录 $d"
done
for f in "${DEL_FILES[@]}"; do
    [[ -e "$f" ]] && rm -f "$f" 2>/dev/null && ok "删除文件 $f"
done

# 老式 SysV init 自启动符号链接
rm -f /etc/rc{0,1,2,3,4,5,6}.d/S*aegis      2>/dev/null
rm -f /etc/rc.d/rc{0,1,2,3,4,5,6}.d/S*aegis 2>/dev/null

# 日志和临时文件
rm -rf /var/log/aegis        2>/dev/null
rm -rf /var/log/cloudmonitor 2>/dev/null
rm -rf /tmp/aegis*           2>/dev/null
rm -rf /tmp/CmsGoAgent*      2>/dev/null

systemctl daemon-reload

# ================================================================
# Step 6/7: 扫描 cron 任务
# ----------------------------------------------------------------
# aegis 历史版本会在 /etc/cron.d/ 写入定时任务。
# 用户级 crontab 也扫一遍。发现可疑条目只警告，不自动删除
# （避免误删用户其他任务）。
# ================================================================
log "Step 6/7: 扫描 cron 任务..."

CRON_HITS=$(
    {
        # 所有用户的 crontab
        for u in $(cut -f1 -d: /etc/passwd 2>/dev/null); do
            crontab -u "$u" -l 2>/dev/null | sed "s|^|[user:$u] |"
        done
        # 系统级 crontab
        sed 's|^|[/etc/crontab] |' /etc/crontab 2>/dev/null
        # cron.d / cron.hourly 等目录下的所有文件内容（按行打标，让外层 grep 匹配内容）
        for f in /etc/cron.d/* /etc/cron.hourly/* /etc/cron.daily/* /etc/cron.weekly/* /etc/cron.monthly/*; do
            [[ -f "$f" ]] && sed "s|^|[$f] |" "$f" 2>/dev/null
        done
    } 2>/dev/null | grep -iE 'aliyun|aegis|cloudmonitor' | grep -v '\][[:space:]]*#' || true
)

if [[ -n "$CRON_HITS" ]]; then
    warn "检测到可疑 cron 条目，请手动审查并清理："
    echo "$CRON_HITS"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
else
    ok "cron 任务无残留"
fi

# ================================================================
# Step 7/7: 验证
# ================================================================
log "Step 7/7: 最终验证..."
echo

# --- 进程检查 ---
echo "--- 残留进程 ---"
RESIDUE_PROC=$(ps -ef | grep -iE 'aliyun|aegis|cloudmonitor|assist|yundun|argus' | grep -v grep | grep -v cloud-init || true)
if [[ -z "$RESIDUE_PROC" ]]; then
    ok "无残留进程"
else
    warn "仍有残留进程："
    echo "$RESIDUE_PROC"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
fi

# --- 文件检查 ---
echo
echo "--- 残留文件 ---"
RESIDUE_FILE=$(ls /usr/local/ /usr/sbin/ 2>/dev/null | grep -iE 'aegis|cloud|aliyun|yundun' | grep -v cloud-init || true)
if [[ -z "$RESIDUE_FILE" ]]; then
    ok "无残留文件"
else
    warn "仍有残留文件（注意排除内核模块 aegis128.ko，那是 AES 算法）："
    echo "$RESIDUE_FILE"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
fi

# --- systemd 单元检查 ---
echo
echo "--- 残留 systemd 单元 ---"
RESIDUE_UNIT=$(systemctl list-unit-files 2>/dev/null | grep -iE 'aliyun|aegis|argus|cmsgo|yundun' | grep -v cloud-init || true)
if [[ -z "$RESIDUE_UNIT" ]]; then
    ok "无残留 systemd 单元"
else
    warn "仍有残留 systemd 单元："
    echo "$RESIDUE_UNIT"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
fi

# ================================================================
# 收尾
# ================================================================
echo
if [[ $RESIDUE_COUNT -eq 0 ]]; then
    cat <<'EOF'
================================================================
  ✅ 清理完成，所有检查通过
================================================================
  下一步建议：
    1. 控制台心跳超时通常 15min ~ 2h，状态会自动转为"离线"
    2. 强烈建议执行 reboot 验证清理彻底（重启后再 ps 一次确认）
    3. 如想云端也彻底移除：云安全中心 → 资产中心 → 移除资产
================================================================
EOF
    exit 0
else
    cat <<EOF
================================================================
  ⚠️  清理完成，但发现 $RESIDUE_COUNT 项残留
================================================================
  请根据上方"残留"输出手动处理。常见原因：
    - 控制台自保护未关闭，aegis 被云端重新推送回来
    - 进程仍持有文件句柄（lsof 排查后再删）
    - cron 任务残留（手动 crontab -e 编辑清理）
================================================================
EOF
    exit 1
fi
