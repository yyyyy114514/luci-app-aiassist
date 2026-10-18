# DEV.md — luci-app-aiassist 二次开发文档（给下一个 AI / 开发者）

> 这是给"接手继续开发"的人的文档，不是用户手册（用户手册是 `README.md`）。
> 阅读顺序建议：第 1 节（现状）→ 第 2 节（ucode 铁律，必看）→ 第 4 节（模块契约）→ 第 5 节（扩展清单）。

---

## 0. 一句话定位

`luci-app-aiassist` 是一个 LuCI（OpenWrt Web 管理界面）插件：在网页上让用户和 AI 对话，AI 可以**查看 OpenWrt 配置、按用户授权的权限档执行命令、做配置快照与回滚**。后端是 **rpcd 的 ucode 插件**，前端是 LuCI 的 JS（rpc.js 调用 ubus）。

技术栈：OpenWrt rpcd + ucode（类 JS 脚本语言，**不是** Node/Browser JS）+ LuCI 前端 JS + curl 调外部 AI API。

---

## 1. 当前状态（2026-10-17）

| 项 | 值 | 备注 |
|---|---|---|
| 当前版本 | `PKG_VERSION:=1.1.6`（`packages/luci-app-aiassist/Makefile`） | ipk 文件名版本号来自这里，**不来自 git tag** |
| 已发布 tag | `v1.1.0` … `v1.1.6` | 都存在于 GitHub |
| `v1.1.6` Release | 已发布，4 架构 ipk 齐全，CI 全绿 | 本体 `luci-app-aiassist_1.1.6-r1_all.ipk`（32→35 KB，多了诊断脚本） |
| 最近提交 | `a7fd5a9 fix(ucode): import access(); materialise missing config file; verify the write landed` | tag `v1.1.6` 与 master 同步 |

**v1.1.0 → v1.1.2 之间修过的真问题（历史，避免重复踩）：**
- `v1.1.1`：用户装完报 "Object not found"。根因是 **ipk 版本号来自 `PKG_VERSION` 而非 git tag**，打 tag 时忘了同步 Makefile，导致产物名仍 `1.1.0-r1`。已修正，**发版 = 改 PKG_VERSION + 打 tag 两步缺一不可**（见第 6 节）。
- `v1.1.2`：**真机 rpcd 完全加载不了插件**，所有 ubus 调用都 `-32000 Object not found`。根因是源码用了 ucode 不支持的 JS 语法（见第 2 节）。v1.1.2 已把全部源码重写为 ucode 兼容写法。

**v1.1.3 → v1.1.6 的关键修复：**
- `v1.1.3/1.1.4`：ucode 2025.07.18 不支持 `export function f(){}`，45 处改 `export const f = function(){}`；新增 `ucode-2410` CI job 复现用户真机环境。
- `v1.1.5`：`updateSettings` 补 `cursor().load()`（不 load 就 `set()` 会 `Entry not found`）。
- `v1.1.6`：**真因** —— `undefined` 在 ucode 里不是变量，`x === undefined` 抛 `Reference error: access to undeclared variable undefined`。它既让每次保存都在写入前抛错，又让新加的错误处理器自己崩溃，于是前端只剩 `[object Object]`。同轮还修了 `access()` 漏 import、config 缺失时 `load()` 为 no-op 导致"假成功"。详见第 2.1 节表格。
- `v1.1.6` 新增可观测性：`selfTest` RPC、设置页「运行诊断」按钮、`/usr/sbin/aiassist-diag`、前端 `errText()` 兜底。**任何异常都不会再以 `[object Object]` 或裸 `-32000` 出现。**

**CI 状态（2026-10-17 已全绿 ✅）：**
- ✅ `ucode-lint`（独立 reusable workflow，见 `.github/workflows/ucode-lint.yml`）：真机 ucode 编译 + import + runtime smoke，**作为 build 的前置门禁**（`build needs: ucode-lint`，lint 不过编译不启动）。
- ✅ `build`：4 架构编译（aarch64_cortex-a53 / x86_64 / mips_24kc / arm_cortex-a7_neon-vfpv4）。
- ⏸ `release`：仅打 tag 时发布。

---

## 2. ⚠️ 最重要：ucode 兼容性铁律

> **ucode 是 OpenWrt 的脚本语言，语法是 ES5.1 + 部分 ES6 子集，和 Node/浏览器 JS 不是一回事。**
> **`node --check` 通过 ≠ 真机能跑。** rpcd 用真 ucode 解释器加载插件，遇到不支持的语法会**整文件静默编译失败**，结果是：插件对象从不注册 → 所有 `aiassist/xxx` 调用都报 `-32000 Object not found`。
> 本地全绿、真机必炸，就是因为这个。

### 2.1 真机 ucode 不支持，但 node 能过的写法（已踩）

| 写法 | 例子 | 真机后果 | 本项目替代 |
|---|---|---|---|
| `for...of` | `for (let m of arr)` | 语法错误，整文件不过 | 索引循环 `let __arr = EXPR; for (let __i=0; __i<length(__arr); __i++) { let m = __arr[__i]; ... }` |
| 数组 spread | `[ ...arr ]` / `[ ...a, ...b ]` | 不支持 | `copy_array(arr)` 或显式 `push` 循环 |
| 对象 spread | `{ ...obj }` | 不支持 | 逐字段赋值 |
| 方法式 `.sort(fn)` | `arr.sort((a,b)=>…)` | ucode 没有 `Array.prototype.sort` | 全局函数 `sort(arr, (a,b)=>…)`（注意参数顺序：`sort(数组, 比较器)`） |
| 方法式 `.push` / `.join` / `.slice` / `.length()` | `arr.push(x)` / `arr.join()` | 这些**方法大多不存在**（`push`/`sort` 是全局函数，`length` 是全局函数 `length(arr)`，`join` 需自己写） | 用全局函数：`push(arr, x)`、`sort(arr, fn)`、`length(arr)`、`join(parts, sep)` |
| `delete obj[k]` 操作符 | `delete s.snapshots[t]` | ucode 已移除 `delete` 操作符 | `remove_key(obj, k)` 重建对象（见 lib.uc） |
| 正则里的 `\uXXXX` 转义 | `/[\u4e00-\u9fff]/g` | ucode 正则引擎不支持 `\u` | 改用 `ord(substr(text,i,1))` 逐字符比较码点 |
| `??` 可选链 `/ ?.` | `a?.b` / `a ?? b` | 不支持（`?.` 已部分支持但别依赖） | 显式 `a ? a.b : null` / `a != null ? a : b` |
| 模板字符串 / 反引号 | `` `hi ${x}` `` | 不支持（除非新版） | 用 `sprintf('%s', x)` 或字符串拼接 |
| 默认参数 | `function f(x = 1)` | 旧版不支持 | 函数体内 `x = x || 1` |
| `const`/`let` 顶层 + 块级作用域 | 同 node 行为 | ucode 支持 `let`/`const`，但**循环变量作用域要小心**（见下） | — |
| 八进制字面量 | `0700` | ucode 不支持 `0NNN` 八进制字面量 | 用十进制（`448`）或 `int('0700', 8)` |
| 解构赋值 | `let {a,b} = obj` | 不支持 | 逐字段取 |
| `import * as` 命名空间导入 | `import * as x from 'mod'` | rpcd 加载器不一定支持 | 用 `import { a, b } from 'mod'` 具名导入 |
| 顶层 `export const` | `export const X = 1` | 早期 rpcd 不支持（已验证修过） | 用 `export function` 或 `export const` 在**新版本**可，但稳妥起见常量放模块内、通过 `export function` 暴露 |
| **函数声明不提升** | 函数 A 调用定义在后面的函数 B | **`Reference error: access to undeclared variable B`**（ucode 词法解析：调用点必须先于被调函数定义，与 JS hoisting 相反） | **所有函数必须先定义再被调用**；新增函数时注意放置位置，或跑 `tests/scan_ucode.py` 的前置调用检查 |
| **`json()` 不能序列化** | `writefile(path, json(obj))` | `Type error: Input object does not implement read() method`——ucode 的 `json()` 只做**解析**（字符串/资源→值） | 序列化用 **`sprintf('%J', obj)`**（官方 netifd 用法） |
| **无 `float()` / `double()` 全局** | `float(x)` / `double(x)` | `Reference error: access to undeclared variable float`——core 71 函数表无此函数 | 数值强制转换用一元 `+`：`let t = +cfg.temperature;`（`int(x, base)` 是唯一字符串→整数函数） |
| **无 `rand()` 全局** | `rand() % 100` | `Reference error: access to undeclared variable rand`——随机数在 math 模块（`import ... from 'math'`），且部分 rootfs 没带 math.so | 用 `clock()`（纳秒单调时钟，core 函数）生成唯一后缀：`sprintf('%s_%d_%d', prefix, time(), clock())` |
| **`undefined` 不是变量** | `x === undefined` / `x !== undefined` | **`Reference error: access to undeclared variable undefined`**（ucode 2025.07.18 没有 `undefined` 关键字/全局）。最致命的是：如果它出现在 `catch` 的错误处理函数里，**错误处理器自身崩溃**，前端只能看到 `[object Object]` 或 `-32000`，真实原因被完全掩盖 | 一律用松散比较 **`x == null` / `x != null`**（同时覆盖 null 与"键不存在"）。`tests/scan_ucode.py` 已内置该检测（会先剥离注释，避免注释文字误报） |

**嵌套循环变量名唯一性坑**：把 `for...of` 机械转成 `let __arr = ...; for(let __i=...)` 时，如果多次迭代转换，编号可能撞车导致内外层变量互相覆盖、运行期逻辑错乱。本项目 `tests/fix_forof.py` 已处理（编号取文件内已存在最大值 +1），**手写新循环时务必用全文件唯一的 `__arrN`/`__iN`**。

### 2.2 工具链（已随仓库提供，务必用）

```
packages/luci-app-aiassist/tests/
├── scan_ucode.py   # 静态扫描：检测 node 能过但 ucode 不能的语法，输出行号+片段，发现即 exit(1)
├── fix_forof.py     # 把 for...of 自动转成 ucode 兼容索引循环（in-place）
├── fix_misc.py      # 二阶修复：spread→copy_array、.sort→sort()、delete→remove_key、\u 正则→ord()
├── test_perm.mjs    # node 模拟权限逻辑（FATAL/LIMITED 黑名单、白名单前缀匹配）✅ 可本地跑
└── test_proto.mjs   # node 模拟协议转换（OpenAI/Anthropic 消息格式）✅ 可本地跑
```

**改动 ucode 源码后的标准动作（缺一不可）：**
```sh
cd packages/luci-app-aiassist
# 1) 若有 for...of / spread / .sort / delete / \u 正则，先用脚本机械转换（可重复跑直到 0）
PY=你的python3
$PY tests/fix_forof.py root/usr/share/ucode/aiassist/lib.uc root/usr/share/ucode/aiassist/proto.uc root/usr/share/ucode/aiassist/core.uc
$PY tests/fix_misc.py  root/usr/share/ucode/aiassist/lib.uc root/usr/share/ucode/aiassist/proto.uc root/usr/share/ucode/aiassist/core.uc
# 2) 无论如何，必须跑扫描器确认清零（这是真正确认手段，比 CI 可靠）
$PY tests/scan_ucode.py \
  root/usr/share/ucode/aiassist/lib.uc \
  root/usr/share/ucode/aiassist/proto.uc \
  root/usr/share/ucode/aiassist/core.uc \
  root/usr/share/rpcd/ucode/aiassist \
  root/usr/libexec/aiassist/worker.uc
# 期望输出：CLEAN: no ucode-incompatible constructs found
# 3) node 语法兜底（只能拦语法，拦不了 ucode 语义）
node --input-type=module --check <(sed 's/0[0-7][0-7][0-7]/448/g' root/usr/share/ucode/aiassist/lib.uc)
# 4) 逻辑单测
node tests/test_perm.mjs && node tests/test_proto.mjs
```

> `scan_ucode.py` 的"误报"：`fs`/`uci` 等内建模块导入、以及 `collect_indented` 之类字符串方法不在扫描范围。扫描白名单是"ucode 不支持但 node 支持的 JS 写法"，不是全量 lint。

### 2.3 路由器本地验证（最权威）

SSH 进路由器（已装好插件）后：
```sh
# 1) 对象是否注册（核心判活）
ubus list aiassist            # 应列出所有方法
ubus call aiassist getInfo '{}'   # 应返回 {enabled,...}

# 2) 看 rpcd 加载插件有没有编译报错（装完/改完必看）
logread | grep -i -E "ucode|aiassist|rpcd" | tail -30
# 若出现 "Syntax error" / "Parse error" 在 /usr/share/rpcd/ucode/aiassist 附近 → 还有不兼容语法

# 3) 单独编译某个文件（最快定位语法错误）
ucode -c /usr/share/ucode/aiassist/lib.uc
ucode -c /usr/share/ucode/aiassist/proto.uc
ucode -c /usr/share/ucode/aiassist/core.uc
ucode -c /usr/share/rpcd/ucode/aiassist

# 4) 改完源码后的生效动作（关键）
/etc/init.d/rpcd restart      # 重新加载 rpcd 插件（必须）
/etc/init.d/uhttpd restart    # 刷新 LuCI
```

---

## 3. 架构与数据流

```
浏览器 (LuCI JS: chat.js / settings.js)
   │  rpc.declare → POST /ubus  (rpc.js)
   ▼
uhttpd → rpcd
            │  rpcd ucode 插件 = /usr/share/rpcd/ucode/aiassist   （注册 ubus 对象 aiassist）
            │     ├─ 解析 request.args.<param>
            │     ├─ import aiassist.lib / aiassist.core / aiassist.proto
            │     └─ 调用对应逻辑
            ▼
   ┌──────────────────────────────────────────────────────────┐
   │ lib.uc    : 配置/会话/快照/回滚/MTD/权限校验/exec 执行      │
   │ proto.uc  : AI 协议适配（OpenAI / Anthropic 消息格式、工具定义、call_ai）│
   │ core.uc   : 编排（工具分发 dispatch_tool、AI 循环 run_ai_loop、压缩、job 管理）│
   └──────────────────────────────────────────────────────────┘
            │  sendMessage / compressContext 这类耗时操作 → 丢给后台 worker
            ▼
   worker.uc （nohup 异步进程 /usr/libexec/aiassist/worker.uc <sid> <jobid>）
            │  - 调 proto.call_ai 用 curl 打外部 AI API
            │  - 循环：AI 返回 tool_calls → dispatch_tool → 把结果写回会话 JSON → 再问 AI
            │  - 进度写入 /etc/aiassist/jobs/<jobid>.json
            ▼
   前端 2 秒轮询 pollJob，增量渲染新消息
```

**关键设计点：**
- 无长驻进程；AI 调用放后台 `worker.uc` 异步跑，rpcd 线程不阻塞。
- 会话/快照/job 全部以 JSON 文件持久化在 `/etc/aiassist/`（首次启动由 `etc/uci-defaults/aiassist` 建目录）。
- API Key 不进 UCI，单存 `/etc/aiassist/api_key`（chmod 600）。
- AI 协议只用 `curl` 打 HTTP，避免引入额外依赖（路由器友好）。

---

## 4. 文件地图与模块契约

### 4.1 rpcd 入口 `root/usr/share/rpcd/ucode/aiassist`（无扩展名）
- 顶层 `import {...} from 'aiassist.lib' / 'aiassist.core' / 'aiassist.proto'`。
- 末尾 `return { aiassist: methods };` —— 这行决定 ubus 对象名。
- `methods` 是个表，每个 key 是一个 ubus 方法，结构：
  ```ucode
  getSession: {
      args: { sid: '' },                 // 参数名: 默认值（rpcd 约定）
      call: function(request) {           // 参数从 request.args.xxx 取
          let s = read_session(request.args.sid);
          ...
      }
  }
  ```
- 无 `args` 的方法：`call: function() { ... }`（如 `getInfo`、`getSystemInfo`）。
- **新增方法见第 5.1 节。**

### 4.2 `root/usr/share/ucode/aiassist/lib.uc` —— 基础库
导出（给 core/proto/rpcd 用）：
`key_file_path, shellquote, join, trunc, randstr, load_config, api_key_status, session_path, read_session, write_session, create_session, list_sessions, delete_session, rename_session, estimate_session_tokens, create_snapshot, list_snapshots, snapshot_diff, get_snapshot_content, rollback_session, list_mtd, backup_mtd, check_exec, exec_command, view_config, get_system_info, get_log`

要点：
- `load_config()`：读 UCI `aiassist.settings` + `/etc/aiassist/api_key`，回填默认值，构造 `cfg`。**所有字符串数字已转 int/float，布尔已转 bool**——后续代码直接用 `cfg.timeout` 当数字。
- `check_exec(permission, command, cfg)`：权限/命令校验，返回 `{ok, reason}`。FATAL_PATTERNS（所有模式拦截：`rm -rf`、`mkfs`、`mtd erase|write|unlock`、`dd` 写块设备、`reboot/poweroff/halt`、`fdisk/parted`、`chmod 777|000 /`、`echo > /dev/...`、fork bomb）+ LIMITED 额外禁复合符（`; & | \` $()`、危险词、`..`）。
- `exec_command(cfg, command, sid, permission)`：先 `check_exec`，通过则（按需）自动快照 → `run_shell` 用 `timeout sh -c` 跑 → 截断输出返回。
- `create_snapshot(sid, label)`：tar `/etc/config` + `uci show` 存档到 `/etc/aiassist/snapshots/<sid>/`。
- MTD 备份 `backup_mtd(device)`：`device='all'`（跳过固件/rootfs 大分区）/`mtdX`/`full`，含空间预检、sysupgrade 配置归档、软件清单、md5。

### 4.3 `root/usr/share/ucode/aiassist/proto.uc` —— AI 协议适配
导出：`api_endpoint, tools_for_permission, collect_summary_text, to_openai_messages, to_anthropic_messages, call_ai, summarize_messages`
- `TOOL_DEFS[]`：**AI 可见工具清单**（JSON Schema 风格），新增工具主要改这里（见 5.2）。
- `tools_for_permission(perm)`：按权限档过滤 `TOOL_DEFS`，生成发给 AI 的 tools。
- `call_ai(cfg, messages, tools, extra_system)`：构造 payload（OpenAI `/chat/completions` 或 Anthropic `/v1/messages`），`curl` 调用，带网络失败指数退避重试（4xx 不重试），`parse_openai`/`parse_anthropic` 解析返回 `{text, tool_calls}`。
- 消息格式：内部消息统一为 `{role, kind, content, ts, turn, tool_calls?, tool_call_id?, text?}`。`kind` ∈ `text|tool|summary`；`role` ∈ `user|assistant|system`。

### 4.4 `root/usr/share/ucode/aiassist/core.uc` —— 编排层
导出：`build_full_system, compress_session, run_ai_loop, read_job, write_job, is_job_stopped, stop_job, lock_session, unlock_session, cleanup_jobs, submit_job, poll_job, run_job`
- `build_full_system(cfg)`：拼系统提示词（权限说明 + 12 条工作规则 + 红线 + 用户补充提示）。
- `dispatch_tool(name, args, ctx)`：**工具名 → 实际函数** 的 switch（新增 AI 工具必须在这里加 case，见 5.2）。
- `run_ai_loop(cfg, sid, content, jobid)`：主循环。append 用户消息 → 循环（call_ai → 若有 tool_calls 逐个 dispatch_tool 并写回会话 → 直到无 tool_calls 或达 `max_tool_rounds`）→ 落最终回复。
- `compress_session` / `auto_compress`：上下文压缩（早期轮次交 AI 摘要，失败降级截断）。
- `submit_job`：加锁 → 写 job → `nohup ucode worker.uc <sid> <jobid> &` 起后台进程。
- `run_job(job)`：worker 入口，`compress` 类型走 `compress_session`，否则 `run_ai_loop`。

### 4.5 `root/usr/libexec/aiassist/worker.uc`
后台进程入口：`read_job → run_job → 写回 job 状态（running/done/error）→ 清 .stop 文件、解会话锁`。参数 `ARGV[1]=sid, ARGV[2]=jobid`。

### 4.6 前端 `htdocs/luci-static/resources/view/aiassist/`
- `chat.js`：聊天页。`api` 对象里 `rpc.declare({object:'aiassist', method:'...', params:[...]})` 声明每个 ubus 方法。核心交互：定时 `pollJob` 增量渲染。
- `settings.js`：设置页。字段与 `updateSettings` 的 `args` 严格对应（顺序敏感，见 5.3）。

### 4.7 配置 / ACL / 菜单（均在 `root/` 下）
- `etc/config/aiassist`：UCI 默认配置（注释即文档）。
- `etc/uci-defaults/aiassist`：首次启动建 `/etc/aiassist/{sessions,snapshots,jobs,locks,mtd,undo}`。
- `usr/share/rpcd/acl.d/luci-app-aiassist.json`：**LuCI 访问权限**。read/write 分别列出可被调用的 ubus 方法。**新增 ubus 方法必须同步加到这里**（否则前端无权限调用，表现也是报错）。
  - ⚠️ 已知小瑕疵：acl 里写了 `listJobs`、`listApiKeyState` 两个**不存在**的方法（真实方法是 `pollJob`/`getSettings` 里的 api_key 状态）。无害（永不调用），接手者可顺手清理。
- `usr/share/luci/menu.d/luci-app-aiassist.json`：菜单「系统 → AI Assistant → Chat/Settings」。

---

## 5. 扩展实操清单（给下一个 AI）

### 5.1 新增一个 ubus 方法（例：批量删除会话）
1. **rpcd 入口**（`root/usr/share/rpcd/ucode/aiassist`）：在 `const methods = { ... }` 内加：
   ```ucode
   bulkDeleteSessions: {
       args: { sids: '' },
       call: function(request) {
           let list = split(request.args.sids or '', /\s+/);
           for (let __i=0; __i<length(list); __i++) delete_session(list[__i]);
           return { ok: true, deleted: length(list) };
       }
   },
   ```
2. **ACL**（`acl.d/luci-app-aiassist.json`）：若需前端写权限，把 `bulkDeleteSessions` 加进 `write.ubus.aiassist[]`。
3. **前端声明**（`chat.js` 的 `api` 对象）：`bulkDeleteSessions: rpc.declare({object:'aiassist', method:'bulkDeleteSessions', params:['sids'], expect:{}})`
4. **调用**：在 `chat.js` 某处 `await api.bulkDeleteSessions(ids.join(' '))`。
5. **校验**：`tests/scan_ucode.py` 跑通过；提交前按第 2.2 节。

### 5.2 新增一个 AI 工具（例：查 WiFi 客户端列表）
1. **工具定义**（`proto.uc` 的 `TOOL_DEFS[]` 末尾加一项）：
   ```ucode
   {
       name: 'list_wifi_clients',
       description: '列出当前连接的 WiFi 客户端（MAC/IP/信号）。无参数。',
       parameters: { type: 'object', properties: {} }
   },
   ```
2. **权限**：`tools_for_permission()` 里把 `list_wifi_clients` 加进对应档位的 `allowed` 表（至少 `limited`/`full`）。
3. **实现 + 分发**（`core.uc` 的 `dispatch_tool` switch 加 case）：
   ```ucode
   case 'list_wifi_clients':
       return { ok: true, text: exec_command(cfg, 'iwinfo phy0-ap0 assoclist 2>/dev/null', sid, permission).text };
   ```
   （或自己写函数放 lib.uc 再 import。）
4. **校验 + 文档**：系统提示词（`build_full_system`）无需改（通用规则已覆盖）；改完跑 `scan_ucode.py`。

### 5.3 新增前端设置字段（例：新增 `max_history` 选项）
1. `etc/config/aiassist` 加 `option max_history '10'`。
2. `lib.uc` 的 `load_config()` `defs` 加 `max_history: '10'`（及类型转换）。
3. rpcd `updateSettings` 的 `args` 加 `max_history: 10`，`call` 里 `set('max_history', a.max_history)`，`clean_settings` 里回传。
4. `settings.js`：`collect()` 返回加 `max_history`，`api.updateSettings(...)` 参数**顺序必须与 rpcd `args` 顺序完全一致**（ubus 位置参数），UI 加一个控件。
5. 前端 `rpc.declare` 的 `params` 数组顺序也要对齐。

> ⚠️ **顺序敏感陷阱**：rpcd `updateSettings` 用位置参数（`params` 数组顺序 = `args` 表顺序）。`settings.js` 调 `api.updateSettings(a,b,c,...)` 的顺序、**chat.js 里 `rpc.declare` 的 `params` 顺序**、**rpcd `args` 表顺序** 三者必须一致，否则字段串位。

---

## 6. 发版流程（踩坑版）

1. **改代码**（含本仓库 `tests/` 下校验）。
2. **升版本号**：编辑 `packages/luci-app-aiassist/Makefile` 的 `PKG_VERSION:=x.y.z`（和 `PKG_RELEASE` 按需）。**这一步漏了 = 产物名不变 = 用户以为没更新**（v1.1.1 的教训）。
3. **提交**：`git commit -m "..."`（注意：commit message 里别用反引号包裹 `delete obj[k]` 之类会被 shell 当命令执行，用 heredoc `-F -` 提交最稳）。
4. **推 master** + **打 tag**：`git tag vX.Y.Z && git push origin master --tags`。
5. CI 自动：4 架构 `build` → 打 `vX.Y.Z` Release（含本体 ipk + curl 依赖族 4 架构）。
6. 用户安装后**必须** `/etc/init.d/rpcd restart`（见第 2.3 节）。

> 当前 CI 矩阵：`aarch64_cortex-a53`（ARMv8，如 R2S/R4S/ipq807x）、`x86_64`、`mips_24kc`（MT7620/21）、`arm_cortex-a7_neon-vfpv4`（MT7623/ipq40xx）。SDK 镜像 tag 用完整版本 `x86_64-24.10.0`（不是 `24.10`）。

**⚠️ v1.1.2 之后的未发布修复**：真机 lint 在 master 上又抓出并修掉了 6 个运行时 bug（函数提升 7 处重排、`json()` 序列化 4 处、`float/double`、`rand`、解构、TDZ 遮蔽）——**这些 commit 尚未发版**。下次发版（v1.1.3 或更高）前先确认：`ucode-lint` 门禁绿 + `git log v1.1.2..HEAD --oneline` 里的 fix commit 都包含进来，再改 `PKG_VERSION` 打 tag。

---

## 7. 测试与 CI

- **可本地跑**：`node tests/test_perm.mjs`、`node tests/test_proto.mjs`（node 模拟权限/协议逻辑，非真 ucode，但能拦逻辑回归）。
- **ucode 语法真闸门**：`tests/scan_ucode.py`（见 2.2）。这是改动源码后**必须**过的。
- **CI**：
  - `build`：4 架构 SDK 编译 + 发布 ✅ 稳定。
  - `ucode-lint`：用 `ghcr.io/openwrt/rootfs:x86_64-master` 容器装/调 `ucode` 做真机编译校验。**状态：实验性、未绿过，见第 1 节**。接手者请优先让其跑通或替换为可靠校验（例如在路由器上 `ucode -c` 的等效物）。

---

## 8. 已知问题 / TODO（留给接手者）

1. **🟢 发版**：v1.1.2 之后的 6 个运行时修复（函数重排/json 序列化/float/double/rand/解构）已在 master 上全绿，**尚未发版**——下次发版直接带上（见第 6 节）。
2. **🟡 ACL 幽灵方法**：`acl.d` 里的 `listJobs`/`listApiKeyState` 已删除（commit `db25e18`）。✅ 已解决
3. **🟡 `args` 顺序三处必须对齐**（rpcd / chat.js params / settings.js 调用），无自动化校验，易错。可考虑改用具名参数传递（但 rpcd 约定是位置参数，需权衡）。
4. **🟢 压缩摘要质量**：`summarize_messages` 依赖 AI 自己摘要，失败时降级为截断；可加"摘要命中率"统计。
5. **🟢 多 Provider**：目前写死 OpenAI 兼容 + Anthropic。新增如 Gemini/DeepSeek 需扩 `call_ai` 的分支与 `api_endpoint`/`api_headers`。
6. **🟢 流式输出**：当前是"跑完一轮再轮询"，可改 SSE/流式降低体感延迟（需改 worker+前端）。
7. **🟢 国际化**：目前纯中文 UI 与提示词，未做 i18n。

---

## 9. 本地调试速查

```sh
# 进路由后
ubus list aiassist | head                 # 看对象注册了没
ubus call aiassist getInfo '{}'           # 最小活体检查
logread | tail -40 | grep -i aiassist      # 看运行错误
ucode -c /usr/share/ucode/aiassist/lib.uc # 单独编译查语法
cat /etc/aiassist/audit.log | tail        # 看执行/快照/回滚审计
ls /etc/aiassist/sessions/                 # 会话 JSON
ls /etc/aiassist/snapshots/<sid>/          # 该会话快照

# 本地（开发机）
python3 tests/scan_ucode.py root/usr/share/ucode/aiassist/*.uc root/usr/share/rpcd/ucode/aiassist root/usr/libexec/aiassist/worker.uc
node tests/test_perm.mjs && node tests/test_proto.mjs
```

---

> 最后提醒：本项目**最贵的教训是 ucode 兼容性**（第 2 节）。任何改了 `*.uc` 的 PR，没过 `scan_ucode.py` 就不要合、不要发版。路由器的 `ucode -c` 是终极裁决。
