# Aliyun ECS Agent Uninstaller / 阿里云 ECS 监控组件一键卸载

> 一键彻底卸载阿里云 ECS 上的云盾（aegis / 安骑士）、云监控（CloudMonitor）、云助手（aliyun-service）三件套。
>
> One-click uninstaller for Aliyun ECS monitoring agents — aegis (Cloud Security Center), CloudMonitor, and aliyun-service.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-green.svg)]()
[![Tested](https://img.shields.io/badge/tested-Ubuntu%2FDebian%2FCentOS-orange.svg)]()

---

## ⚠️ 必读前置条件 / Critical Prerequisite

运行脚本之前，**必须先在网页控制台关闭客户端自保护**，否则即使本地清理干净，云端也会通过云助手通道把云盾推送回来。

操作路径：
> 阿里云控制台 → **云安全中心** → 设置 → 客户端自保护设置 → 找到对应机器 → 关闭 **"客户端自保护"** 和 **"恶意主机行为防御"**

You **must** disable client self-protection in the Cloud Security Center console first. Otherwise the agents will be re-pushed by the cloud control plane even after local cleanup completes successfully.

---

## 快速使用 / Quick Start

下载并执行（推荐，脚本文件留在本地便于排查）：

```bash
wget -O uninstall_aliyun_agents.sh "URL" && chmod +x uninstall_aliyun_agents.sh && sudo ./uninstall_aliyun_agents.sh --yes
```

管道一行版（适合批量部署）：

```bash
curl -fsSL "URL" | sudo bash -s -- --yes
```

> 把 `URL` 替换成本仓库 raw 文件地址即可。

---

## 卸载范围 / What Gets Removed

| 组件 | 主要进程 | 安装路径 |
|------|---------|---------|
| 云盾 / 安骑士 (aegis) | `AliYunDun`, `AliYunDunUpdate`, `AliYunDunMonitor` | `/usr/local/aegis` |
| 云监控 (CloudMonitor) | `CmsGoAgent.linux-*` | `/usr/local/cloudmonitor` |
| 云助手 (aliyun-service) | `aliyun-service`, `assist_daemon` | `/usr/local/share/assist-daemon` |

**不会误删的内容**（这是很多网上教程踩过的坑）：

- ✅ `cloud-init.service` 等开源 cloud-init 组件 —— 所有云厂商都用，与阿里云无关
- ✅ 内核加密模块 `aegis128.ko` —— Linux 内核的 AES 流密码实现，与阿里云无关

---

## 为什么需要这个脚本 / Why This Script Exists

阿里云官方的 `uninstall.sh` 在以下场景会失败或不彻底：

1. **immutable 文件锁** —— aegis 会给自己的目录加 `i` 属性，导致 `rm` 报 `Operation not permitted`，普通 root 也删不掉
2. **多组件耦合** —— 云盾、云监控、云助手是三套独立组件，官方脚本只处理云盾
3. **进程名截断 bug** —— Linux 内核 `/proc/PID/comm` 字段限制 15 字符，`AliYunDunMonitor` (16) / `CmsGoAgent.linux-amd64` (22) 等长名进程用 `pkill -x` 会漏杀
4. **云端自保护推送** —— 不在控制台关闭自保护，本地卸载后云盾会被重新推回来

This script addresses all four root causes that make the official uninstall procedure unreliable.

---

## 使用方式 / Usage

### 交互模式（推荐首次使用）

```bash
sudo bash uninstall_aliyun_agents.sh
```

会展示前置条件提醒并要求 `y/N` 确认。

### 自动模式（CI/CD、批量部署）

```bash
sudo bash uninstall_aliyun_agents.sh --yes
```

### 批量部署示例

```bash
for host in host1 host2 host3; do
    if ssh "$host" "sudo bash -s -- --yes" < uninstall_aliyun_agents.sh; then
        echo "✅ $host succeeded"
    else
        echo "❌ $host failed (exit $?)"
    fi
done
```

---

## 退出码 / Exit Codes

| Code | 含义 |
|------|------|
| `0` | 完全清理成功 / Clean success |
| `1` | 有残留，需手动处理 / Residue detected |
| `2` | 环境/依赖错误 / Environment error (non-root, missing commands) |

可通过 `$?` 在脚本中接收并做后续处理。

---

## 兼容性 / Compatibility

| 系统 | 状态 |
|------|------|
| Ubuntu 18.04 / 20.04 / 22.04 / 24.04 | ✅ |
| Debian 10 / 11 / 12 | ✅ |
| CentOS 7 / 8 | ✅ |
| Alibaba Cloud Linux 2 / 3 | ✅ |
| Windows ECS | ❌（架构完全不同，本脚本不适用） |

**依赖 / Requirements**：

- `bash` 4.0+
- `root` 权限
- 标准包提供的 `chattr` / `pkill` / `pgrep` / `wget` / `systemctl`

绝大多数 Linux 发行版默认都有，无需额外安装。

---

## 脚本工作流程 / How It Works

```
Step 0  前置确认（root 检查 / 依赖检查 / 用户确认）
Step 1  运行阿里云官方 uninstall.sh + quartz_uninstall.sh（带下载校验）
Step 2  优雅停止 CmsGoAgent / assist_daemon / aliyun.service
Step 3  pgrep -f 路径匹配杀残留进程（绕开 comm 截断 bug）
Step 4  chattr -R -i 解除 immutable 锁
Step 5  rm 删除文件、目录、systemd unit、SysV init 软链、log/tmp
Step 6  扫描 cron 任务（系统级 + 用户级 + cron.d 等）
Step 7  三维度交叉验证（进程 / 文件 / systemd），输出退出码
```

---

## 验证清理成功 / Verifying Cleanup

脚本结束会自动输出验证结果。手动验证：

```bash
# 1. 进程检查
ps -ef | grep -iE 'aliyun|aegis|cloudmonitor|assist|yundun' | grep -v grep

# 2. 文件检查
ls /usr/local/ /usr/sbin/ | grep -iE 'aegis|cloud|aliyun|yundun'

# 3. systemd 单元检查
systemctl list-unit-files | grep -iE 'aliyun|aegis|cmsgo|argus'
```

三条都无输出 = 服务器侧完全干净。

**控制台显示离线的时延**：通常 15 分钟到 2 小时（基于客户端心跳超时）。控制台状态比本地清理结果有滞后是正常现象。

---

## 常见问题 / FAQ

**Q：跑完脚本后控制台还是显示"在线"？**

A：控制台基于最后一次心跳判断，最长可能 2 小时才同步为离线。如果超过 2 小时仍显示在线，检查控制台自保护是否真的关了。

**Q：`rm` 报 `Operation not permitted` 怎么办？**

A：这是 immutable 锁。脚本会自动 `chattr -R -i` 解锁。如果你手动跑命令遇到这个错误，先：

```bash
chattr -R -ia /usr/local/aegis
rm -rf /usr/local/aegis
```

**Q：重启后云盾会不会自己回来？**

A：在控制台自保护已关闭的前提下，**不会**。如果担心，可以在云安全中心 → 资产中心 → 移除资产，让云端记录也彻底清除。

**Q：脚本会不会误删别的东西？**

A：所有删除路径都是 hardcoded 阿里云官方安装路径。`cloud-init` 服务和内核模块 `aegis128.ko` 已显式排除（这两个东西经常被网上教程错误地标记为"阿里云组件"）。

**Q：非阿里云 ECS（IDC、其他云）能用吗？**

A：能。如果你的非阿里云机器上之前装过阿里云的 Agent（比如混合云场景），脚本同样适用。

---

## 贡献 / Contributing

欢迎提 Issue / PR。重点关注：

- 新版本 aegis 的进程名变化（已观察到 `aegis_12_61` 这样的版本号）
- 新发行版的兼容性测试反馈
- 阿里云未来可能引入的新反卸载机制

---

## License

[MIT](LICENSE)

---

## Keywords / 关键词

阿里云盾卸载 · 安骑士卸载 · 阿里云监控关闭 · ECS 卸载云盾 · AliYunDun uninstall · aegis remove · CloudMonitor uninstall · aliyun-service disable · 阿里云 ECS 减负 · aliyun agent removal · 云助手关闭 · cloudmonitor cleanup · aegis_12 卸载
