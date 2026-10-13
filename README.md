# LuCI AI Assistant（luci-app-aiassist）

在 LuCI 中与 AI 对话，让 AI **查看 OpenWrt 配置 → 给出调优意见 → 按你的授权直接执行命令**，并支持多轮上下文、权限分级、一键回滚（最高支持 MTD 分区备份）。

**最低支持 OpenWrt 24.x 基线**（LuCI JS + rpcd ucode 后端，OpenWrt 23.05+ 亦可运行）。

---

## 功能总览

| 需求 | 实现 |
|---|---|
| AI 自主配置 | 设置页填写 Provider（OpenAI 兼容 / Anthropic 协议）、Base URL、Key、Model，Key 存 `/etc/aiassist/api_key`（600 权限） |
| 多轮上下文 | 会话按 JSON 文件持久化，天然多轮；支持**自动压缩**（估算 token 超阈值触发，先让 AI 生成摘要，失败降级截断）与**手动压缩**；会话有**硬上限**（`max_session_tokens`，超过拒绝并提示压缩/新建会话） |
| 查看/调优 OpenWrt | 工具 `get_system_info` / `view_config` / `get_log` / `exec_command`；`view_config` 可看任意 UCI 包或受允许路径 |
| 第三方插件支持 | `view_config` 通吃任何 `/etc/config/*` 包（含第三方 LuCI 插件）；设置页 `view_paths` 可追加任意可读路径；`exec_allowlist` 可为受限模式追加第三方命令白名单（用户引导） |
| 权限由用户设置 | 三档：`readonly`（只读）/ `limited`（受限白名单执行）/ `full`（全权负责，root + 无需审批，开启需勾选风险确认） |
| AI 行为限制 | 系统提示词内置红线（禁改密码/禁刷固件/禁重启/禁恢复出厂）、先查后动、一次一条命令；`max_tool_rounds` 限制工具调用轮数；`max_tokens` 限制单次回复；`exec_timeout` 限制命令执行时长；API 失败自动重试（4xx 不重试） |
| 回滚 | 写操作前**自动快照** `/etc/config` 等关键文件（tar + uci show 存档），可回退到第 N 轮之前；回滚前状态会先保存为 `pre-rollback` 正式快照（**可再次回滚撤销本次回退**）；快照按 `snapshot_retention` 自动清理；最高等级支持 **MTD 智能备份**（按实际分区表动态适配：小分区 dd + sysupgrade 配置归档 + 软件清单 + md5 校验，大分区显式指定才备份） |
| 128MB 内存优化 | 无长驻进程、无重型框架；AI 请求在**后台 worker** 异步执行，不阻塞 rpcd；前端**增量渲染**（轮询后只追加新消息）；工具输出截断；job 文件惰性清理；锁自动过期（worker 崩溃 10 分钟后自动恢复） |

---

## 目录结构

```
luci-app-aiassist/
├── Makefile                          # OpenWrt 打包（luci.mk）
├── README.md
├── tests/                            # node 逻辑模拟测试（权限黑名单、协议转换）
└── root/
    ├── etc/
    │   ├── config/aiassist           # UCI 默认配置
    │   └── uci-defaults/aiassist     # 首次启动创建数据目录
    └── usr/
        ├── libexec/aiassist/worker.uc    # 后台 worker（异步跑 AI 循环）
        ├── share/
        │   ├── luci/menu.d/luci-app-aiassist.json
        │   ├── rpcd/
        │   │   ├── acl.d/luci-app-aiassist.json
        │   │   └── ucode/aiassist         # rpcd RPC 入口
        │   └── ucode/aiassist/
        │       ├── lib.uc             # 基础：配置/会话/快照/回滚/MTD/权限/exec
        │       ├── proto.uc           # AI 协议适配（OpenAI / Anthropic）
        │       └── core.uc            # 编排：工具分发/AI 循环/压缩/job
└── htdocs/luci-static/resources/view/aiassist/
    ├── chat.js                        # 聊天页（会话/对话/压缩/回滚/MTD）
    └── settings.js                    # 设置页（服务商/权限/阈值/白名单）
```

---

## 编译安装

在 OpenWrt SDK 或源码树中：

```sh
# 把 luci-app-aiassist 放入 package/ 目录
cp -r luci-app-aiassist package/

# 编译（SDK 方式）
cd sdk
make package/luci-app-aiassist/compile V=s

# 或整树编译后安装产物
make package/luci-app-aiassist/install V=s
```

产物 `.ipk` 通过 `opkg install` 安装；也可直接 scp 到路由：

```sh
opkg install luci-app-aiassist_1.0.0-1_all.ipk
/etc/init.d/rpcd reload   # 让 rpcd 加载新的 ucode 插件
/etc/init.d/uhttpd reload # 刷新 LuCI
```

之后 LuCI 菜单 **系统 → AI Assistant** 出现聊天与设置页面。

> 依赖：`luci-base`、`curl`（OpenWrt 自带 busybox 的 `tar`、`timeout`、`logread`、`dd` 均可用）。

---

## 快速开始

1. **设置页**（系统 → AI Assistant → Settings）：
   - 勾选「启用」；
   - Provider 选 `OpenAI` 或 `Anthropic`；填 Base URL（OpenAI 兼容如 `https://api.openai.com/v1`，Anthropic 如 `https://api.anthropic.com`，可填含 `/chat/completions` 或 `/v1/messages` 结尾的完整地址）与模型 ID；
   - 输入 API Key 并点「保存 Key」，点「测试连接」验证；
   - 选权限模式（见下），点「保存设置」。
2. **聊天页**（系统 → AI Assistant → Chat）：
   - 「＋ 新建会话」，提问，例如：
     - “查看 network 和 dhcp 配置，分析有哪些可以优化的点”
     - “当前内存占用情况如何？建议如何降低占用”
     - “把无线 2.4G 的信道改为自动并重启无线服务”
3. 需要回退时点「回滚」选择轮次，或直接对 AI 说“回滚到第 3 轮之前的状态”。

---

## 权限设计（三档）

| 模式 | AI 能力 | 说明 |
|---|---|---|
| **readonly 只读** | 查看配置/系统状态/日志，仅给建议 | 最安全；`exec_command` 直接拒绝 |
| **limited 受限** | 白名单命令：`uci` 读写与 commit、`/etc/init.d/*` 启停、常用诊断（logread/df/free/ping…） | 禁止复合命令（`; && | $()` 等）、禁止 `rm`/`dd`/`mkfs`/路径穿越；可经 `exec_allowlist` 追加第三方命令前缀 |
| **full 全权负责** | root + 任意命令，**无需逐条审批** | 开启须在设置页勾选「我已知晓 full 权限风险」（服务端校验 `full_risk_acknowledged`）；写操作自动快照 + 全程审计；仅拦截快照无法恢复的毁灭操作（`rm -rf`、刷写 mtd、mkfs、重启类等） |

所有模式共有安全网（FATAL 拦截）：`rm -rf` / `mkfs` / `mtd erase|write|unlock` / `dd` 写块设备 / `reboot|poweroff|halt` / `fdisk` / 根目录 `chmod 777|000` / fork bomb 等。`limited` 额外禁止一切复合/注入写法。

---

## 回滚设计

- **自动快照**：`limited`/`full` 下每次执行写命令前，自动打包 `/etc/config`（及 rc.local、firewall.user、sysctl.conf、hosts、dnsmasq.conf）为 `turn_<N>_<ts>.tar.gz`，并保存 `uci show` 存档到 `/etc/aiassist/snapshots/<会话>/`；快照数量超 `snapshot_retention`（默认 30）自动清理最旧。
- **回退面板（带操作记录）**：聊天页「回滚」列出每个快照轮次，并显示该轮 AI 实际执行的操作（执行的命令 / 查看的配置 / 提问内容），可一键「对比」查看该快照与当前 `uci` 状态的差异（`+` 当前新增，`-` 快照独有）。
- **对话回退**：回退到第 N 轮 = 恢复该轮写操作前快照 + 截断该轮之后的对话记录；**回退前会把当前状态保存为 `pre-rollback` 正式快照**，因此可以再次回滚撤销本次回退；同时原始 tar 存档在 `/etc/aiassist/undo/` 双保险；随后执行 `reload_config` 让配置生效。
- **AI 自主回滚**：full 模式下 AI 可调用 `list_backups` + `rollback`（需 `confirm=yes`）工具自行恢复。
- **MTD 智能备份（最高等级）**：设置页开启 `mtd_backup`（或 full 权限）后，聊天页「MTD 智能备份」按实际 `/proc/mtd` 动态适配，不硬编码分区：自动备份**小分区**（bootloader/ubootenv/factory 等，bs=128k dd）+ 分区表 + **sysupgrade 配置归档**（`config_backup.tar.gz`，日常恢复用）+ 软件清单（opkg/apk）+ md5 校验；**大分区**（固件/rootfs/ubi 整盘镜像）默认跳过防写满 flash，可用 `device=mtdX` / `device=full` 显式备份；空间不足自动中止并提示先挂载 U 盘。
  > overlay 扩容说明：MTD 镜像是**物理分区快照**，不包含 overlay resize 的成果——恢复镜像后分区回到备份时大小，需按原布局重新扩容；日常配置级恢复请用 `config_backup.tar.gz`。

> 已知边界（用户已接受）：回滚只能恢复**文件态**配置，无法覆盖进程/内核运行时状态、overlayfs 已加载数据等；回滚后应让 AI 检查相关服务状态，必要时 restart。快照占用空间请留意（每次写操作一个 tar.gz，通常 <100KB）。

---

## 上下文与性能（128MB 内存友好）

- **异步 job 模型**：`sendMessage` 立即返回 job id，后台 `worker.uc` 用 curl 调 API 并循环工具；rpcd 线程不长时间占用，前端 2 秒轮询。并发保护：同会话同时只允许一个任务（锁目录，**锁超过 10 分钟自动过期**，worker 崩溃不卡死）。
- **token 估算**：中文 ≈1.5 token/字、英文 ≈1 token/4 字符，发送前估算；**硬上限** `max_session_tokens`（默认 20000）防止无限膨胀，超限拒绝新消息并提示压缩/新建会话。
- **自动压缩**：超过 `context_threshold`（默认 6000）时，把最早一半轮次交给 AI 生成 ≤150 字摘要（失败则直接截断），替换为 summary 消息；`max_turns` 控制保留轮数。
- **手动压缩**：聊天页「压缩上下文」按钮即时触发。
- **输出截断**：`max_output`（默认 4096 字节）限制工具结果；`max_tokens` 限制单次 AI 回复长度；`exec_timeout`（默认 30s）强制终止挂死命令。
- **前端增量渲染**：轮询完成后只追加新消息，不整页重绘；回滚/快照数据按需加载。
- **存储自清理**：job 文件完成后 1 小时自动删除；会话数超 `session_retention`（默认 50）自动删最旧；快照数超 `snapshot_retention`（默认 30）自动删最旧；审计日志 >512KB 自动轮转。
- 前端零第三方依赖，只使用 LuCI 自带组件。

## 设置项速查

| 配置项 | 默认 | 说明 |
|---|---|---|
| `enabled` | 0 | 总开关 |
| `provider` / `base_url` / `model` / `api_key` | — | AI 服务商配置（Key 存文件） |
| `permission` | readonly | readonly / limited / full |
| `context_threshold` | 6000 | 自动压缩触发阈值（tokens） |
| `max_session_tokens` | 20000 | 会话硬上限，超限拒绝新消息 |
| `max_turns` | 20 | 压缩后保留轮数 |
| `timeout` | 60 | API 请求超时（秒） |
| `api_retries` | 2 | 网络错误重试次数（4xx 不重试） |
| `max_tokens` | 2048 | AI 单次回复上限 |
| `max_tool_rounds` | 6 | AI 工具调用轮数上限 |
| `max_output` | 4096 | 工具输出截断（字节） |
| `exec_timeout` | 30 | 命令执行超时（秒） |
| `temperature` | 0.3 | 生成随机性 |
| `proxy` | 空 | HTTP 代理 |
| `auto_snapshot` | 1 | 写操作前自动快照 |
| `snapshot_retention` | 30 | 每会话保留快照数 |
| `session_retention` | 50 | 保留会话数（超出删最旧） |
| `mtd_backup` | 0 | 允许 MTD 分区备份 |
| `system_prompt` / `exec_allowlist` / `view_paths` | 空 | 提示词 / 白名单 / 可读路径（用户引导第三方插件支持） |

---

## 数据与审计

- 会话：`/etc/aiassist/sessions/*.json`（含快照映射）
- 密钥：`/etc/aiassist/api_key`（`chmod 600`，不写入 UCI）
- 审计：`/etc/aiassist/audit.log`（每次执行命令/快照/回滚/MTD 备份均记录，>512KB 自动轮转）

---

## 安全提示

1. **full（全权负责）模式风险极高**：AI 可执行任意命令。仅建议在可控测试设备启用，保持「写操作前自动快照」开启，并定期检查 `audit.log`。
2. API Key 保存在路由器本机；请勿把 `/etc/aiassist/api_key` 外泄。
3. `view_paths` / `exec_allowlist` 是用户引导第三方插件支持的安全通道，按需最小授权。
