// LuCI AI Assistant - shared core library part 1 (ucode)
// Path: /usr/share/ucode/aiassist/lib.uc
// Licensed under the Apache License 2.0.

'use strict';

import { access, open, popen, readfile, writefile, mkdir, lsdir, stat, unlink, basename, dirname, realpath } from 'fs';
import { cursor } from 'uci';

// ---------------------------------------------------------------- paths & constants

const DATA_DIR    = '/etc/aiassist';
const SESS_DIR    = DATA_DIR + '/sessions';
const SNAP_DIR    = DATA_DIR + '/snapshots';
const JOBS_DIR    = DATA_DIR + '/jobs';
const LOCK_DIR    = DATA_DIR + '/locks';
const MTD_DIR     = DATA_DIR + '/mtd';
const UNDO_DIR    = DATA_DIR + '/undo';
export const KEY_FILE = DATA_DIR + '/api_key';
const AUDIT_FILE  = DATA_DIR + '/audit.log';

const MAX_COMMAND_LEN   = 2048;
const MAX_VIEW_LEN      = 16384;
const MAX_TOOL_ROUNDS   = 6;

// default exec allow-list prefixes for "limited" permission (uci writes included, snapshots protect them)
const DEFAULT_ALLOW = [
	'uci show', 'uci get', 'uci changes', 'uci dump', 'uci set', 'uci delete', 'uci add', 'uci add_list',
	'uci del_list', 'uci rename', 'uci revert', 'uci commit',
	'/etc/init.d/', 'wifi reload', 'wifi up', 'wifi down', 'wifi status', 'wifi scan',
	'logread', 'dmesg', 'cat /etc/config/', 'ls /etc/config/', 'grep /etc/config/',
	'df', 'free', 'top -n1', 'ps', 'uptime', 'ping -c', 'nslookup', 'iwinfo', 'iw dev', 'iwgetid',
	'ifstatus', 'ubus call system.', 'ubus call network.', 'ubus call service.', 'ubus call dhcp.', 'ubus call log.',
	'nft list', 'iptables -L', 'iptables -S', 'iptables -nL', 'ip addr', 'ip route', 'ip link', 'ip neigh',
	'ethtool', 'swconfig', 'sysctl -a', 'sysctl -w', 'tc -s', 'tc qdisc', 'hostapd_cli status',
	'curl -s', 'curl -I', 'opkg list', 'opkg update', 'date', 'logger'
];

// files which may be viewed through view_config (third-party configs can be added via view_paths)
const VIEW_PATHS = [
	'/etc/config/', '/etc/rc.local', '/etc/firewall.user', '/etc/sysctl.conf', '/etc/hosts',
	'/etc/dnsmasq.conf', '/etc/sysupgrade.conf', '/etc/opkg/', '/etc/nftables.d/', '/etc/crontabs/'
];

// fatal patterns blocked in every mode (unrecoverable, snapshots cannot restore them)
const FATAL_PATTERNS = [
	/(^|[;&|]\s*)rm\s+(-[a-zA-Z]*r[a-zA-Z]*\s+)*-[a-zA-Z]*f[a-zA-Z]*(\s|$)/,
	/(^|[;&|]\s*)rm\s+(-[a-zA-Z]*f[a-zA-Z]*\s+)*-[a-zA-Z]*r[a-zA-Z]*(\s|$)/,
	/(^|[;&|]\s*)mkfs(\.[a-z0-9]+)?\s+\/?dev\//,
	/(^|[;&|]\s*)mtd\s+(erase|write|unlock)\b/,
	/(^|[;&|]\s*)dd\s+if=\/dev\/(zero|urandom|sd|mmc|mtd)/,
	/(^|[;&|]\s*)(reboot|poweroff|halt)\b/,
	/(^|[;&|]\s*)(fdisk|parted)\s+\/?dev\//,
	/(^|[;&|]\s*)chmod\s+(-R\s+)?(777|000)\s+\//,
	/(^|[;&|]\s*)echo\s+[^\n]*>\s*\/dev\/(sd|mmcblk|mtd)/,
	/(^|[;&|]\s*)dd\s+of=\/dev\/(sd|mmcblk|mtd)/,
	/:\s*\(\)\s*\{/
];

// operator patterns blocked in "limited" mode (no compound/injection constructs)
const LIMITED_OPERATORS = /[;&|`]|\$\(|\n|\b(rm|reboot|poweroff|halt|mkfs|dd|sh|bash)\b/;

// ---------------------------------------------------------------- small utilities

export function shellquote(s) {
	return `'${replace(s, "'", "'\\''")}'`;
}

export function join(parts, sep) {
	let out = '';
	for (let i = 0; i < length(parts); i++)
		out += (i ? sep : '') + parts[i];
	return out;
}

export function trunc(text, max) {
	if (text == null)
		return '';
	text = '' + text;
	if (length(text) <= max)
		return text;
	return substr(text, 0, max) + '\n...[output truncated at ' + max + ' bytes]';
}

function now() {
	return time();
}

export function randstr(prefix) {
	return sprintf('%s_%d_%d', prefix, time(), rand() % 100000);
}

function audit(msg) {
	try {
		let fd = open(AUDIT_FILE, 'a');
		fd.write(sprintf('[%d] %s\n', now(), msg));
		fd.close();
		let st = stat(AUDIT_FILE);
		if (st && st.size && st.size > 524288)
			popen('mv ' + AUDIT_FILE + ' ' + AUDIT_FILE + '.1 2>/dev/null');
	}
	catch (e) {}
}

// ---------------------------------------------------------------- configuration

export function load_config() {
	const defs = {
		enabled: '0', provider: 'openai', base_url: 'https://api.openai.com/v1', model: 'gpt-4o-mini',
		permission: 'readonly', full_risk_acknowledged: '0', context_threshold: '6000', max_turns: '20',
		timeout: '60', max_output: '4096', temperature: '0.3', proxy: '', auto_snapshot: '1',
		mtd_backup: '0', session_retention: '50', system_prompt: '', exec_allowlist: '', view_paths: '',
		max_tokens: '2048', max_tool_rounds: '6', exec_timeout: '30',
		max_session_tokens: '20000', api_retries: '2'
	};

	let cfg = {};
	for (let k in defs)
		cfg[k] = defs[k];

	try {
		let ctx = cursor();
		let v = ctx.get_all('aiassist', 'settings');
		if (v)
			for (let k in v) {
				if (k == 'view_paths')
					cfg.view_paths_str = v[k];
				else if (k in cfg)
					cfg[k] = v[k];
			}
	}
	catch (e) {}

	cfg.enabled        = (cfg.enabled == '1' || cfg.enabled == true);
	cfg.auto_snapshot  = (cfg.auto_snapshot == '1' || cfg.auto_snapshot == true);
	cfg.mtd_backup     = (cfg.mtd_backup == '1' || cfg.mtd_backup == true);
	cfg.full_risk_acknowledged = (cfg.full_risk_acknowledged == '1' || cfg.full_risk_acknowledged == true);
	cfg.temperature    = float(cfg.temperature);
	cfg.context_threshold = int(cfg.context_threshold) || 6000;
	cfg.max_turns      = int(cfg.max_turns) || 20;
	cfg.timeout        = int(cfg.timeout) || 60;
	cfg.max_output     = int(cfg.max_output) || 4096;
	cfg.max_tokens     = int(cfg.max_tokens) || 2048;
	cfg.max_tool_rounds = int(cfg.max_tool_rounds) || 6;
	cfg.exec_timeout   = int(cfg.exec_timeout) || 30;
	cfg.max_session_tokens = int(cfg.max_session_tokens) || 20000;
	cfg.api_retries    = int(cfg.api_retries) || 2;

	cfg.api_key = '';
	try {
		let k = readfile(KEY_FILE);
		if (k)
			cfg.api_key = trim(k);
	}
	catch (e) {}

	cfg.exec_allow = [ ...DEFAULT_ALLOW ];
	if (cfg.exec_allowlist) {
		let extra = split(trim(cfg.exec_allowlist), /\s+/);
		for (let i = 0; i < length(extra); i++)
			if (length(extra[i]) > 0)
				push(cfg.exec_allow, extra[i]);
	}

	cfg.view_paths = [ ...VIEW_PATHS ];
	if (defs.view_paths && type(cfg.view_paths_str) == 'string' && length(trim(cfg.view_paths_str))) {
		let extra = split(trim(cfg.view_paths_str), /\s+/);
		for (let i = 0; i < length(extra); i++)
			if (length(extra[i]) > 0 && substr(extra[i], 0, 1) == '/')
				push(cfg.view_paths, extra[i]);
	}

	return cfg;
}

export function api_key_status(cfg) {
	return {
		configured: length(cfg.api_key) > 0,
		hint: length(cfg.api_key) > 0 ? substr(cfg.api_key, 0, 8) + '...' : ''
	};
}

// ---------------------------------------------------------------- sessions

export function session_path(sid) {
	return SESS_DIR + '/' + sid + '.json';
}

export function read_session(sid) {
	try {
		let raw = readfile(session_path(sid));
		if (raw) {
			let s = json(raw);
			if (type(s) == 'object' && s.messages)
				return s;
		}
	}
	catch (e) {}
	return null;
}

export function write_session(s) {
	writefile(session_path(s.id), json(s));
}

export function create_session(title) {
	let sid = randstr('s');
	let s = {
		id: sid,
		title: (title && length(title)) ? substr(title, 0, 60) : sprintf('会话 %s', sid),
		created: now(), updated: now(), turn: 0, messages: []
	};
	write_session(s);

	// enforce session retention: drop the oldest sessions beyond the limit
	prune_sessions();
	return s;
}

function prune_sessions() {
	try {
		let cfg = load_config();
		let keep = int(cfg.session_retention) || 50;
		let all = list_sessions();
		if (length(all) <= keep)
			return;
		for (let i = keep; i < length(all); i++)
			delete_session(all[i].id);
	}
	catch (e) {}
}

export function list_sessions() {
	let out = [];
	try {
		for (let f in lsdir(SESS_DIR))
			if (substr(f, -5) == '.json') {
				let s = read_session(basename(f, '.json'));
				if (s)
					push(out, { id: s.id, title: s.title, created: s.created, updated: s.updated,
						turn: s.turn, count: length(s.messages) });
			}
	}
	catch (e) {}
	out.sort((a, b) => b.updated - a.updated);
	return out;
}

export function delete_session(sid) {
	unlink(session_path(sid));
	popen('rm -rf ' + shellquote(SNAP_DIR + '/' + sid) + ' 2>/dev/null');
	return { ok: true };
}

export function rename_session(sid, title) {
	let s = read_session(sid);
	if (!s)
		return { ok: false, reason: '会话不存在' };
	s.title = substr(title, 0, 60);
	s.updated = now();
	write_session(s);
	return { ok: true };
}

// ---------------------------------------------------------------- token estimation

function estimate_tokens(text) {
	text = '' + text;
	let cjk = length(replace(text, /[^\u4e00-\u9fff\u3400-\u4dbf]/g, ''));
	let other = length(text) - cjk;
	return int(cjk * 1.5 + other / 4 + 0.999);
}

export function estimate_session_tokens(s) {
	let total = 0;
	for (let m of s.messages)
		total += estimate_tokens(m.content || '') + 8;
	return total;
}

// ---------------------------------------------------------------- snapshots & rollback

function snapshot_paths() {
	let paths = [ 'etc/config' ];
	for (let p of [ 'etc/rc.local', 'etc/firewall.user', 'etc/sysctl.conf', 'etc/hosts', 'etc/dnsmasq.conf' ])
		if (access('/' + p))
			push(paths, p);
	return paths;
}

export function create_snapshot(sid, label) {
	let s = read_session(sid);
	if (!s)
		return { ok: false, text: '会话不存在' };

	let turn = s.turn + 1;
	let dir  = SNAP_DIR + '/' + sid;
	let ts   = now();
	let arch = sprintf('%s/turn_%d_%d.tar.gz', dir, turn, ts);
	let uci  = sprintf('%s/turn_%d_%d.uci.txt', dir, turn, ts);

	try {
		mkdir(dir, 0700);
		let paths = snapshot_paths();
		let cmd = sprintf('tar czf %s -C / %s 2>/dev/null', shellquote(arch), join(paths, ' '));
		popen(cmd).read('all');
		popen('uci show > ' + shellquote(uci) + ' 2>/dev/null').read('all');

		if (!s.snapshots)
			s.snapshots = {};
		s.snapshots[turn] = { file: basename(arch), uci: basename(uci), ts, label: label || 'auto' };
		s.updated = now();
		write_session(s);
		audit(sprintf('snapshot session=%s turn=%d label=%s', sid, turn, label || 'auto'));

		prune_snapshots(sid, s);
		return { ok: true, text: sprintf('配置快照已创建（第 %d 轮，%s）', turn, basename(arch)) };
	}
	catch (e) {
		return { ok: false, text: '快照创建失败: ' + e };
	}
}

// keep at most `snapshot_retention` snapshots per session (oldest dropped)
function prune_snapshots(sid, s) {
	try {
		let cfg = load_config();
		let keep = int(cfg.snapshot_retention) || 30;
		let keys = keys(s.snapshots || {});
		if (length(keys) <= keep)
			return;
		keys.sort((a, b) => int(a) - int(b));
		let drop = length(keys) - keep;
		for (let i = 0; i < drop; i++) {
			let t = keys[i];
			let sn = s.snapshots[t];
			unlink(SNAP_DIR + '/' + sid + '/' + sn.file);
			if (sn.uci)
				unlink(SNAP_DIR + '/' + sid + '/' + sn.uci);
			delete s.snapshots[t];
		}
		write_session(s);
	}
	catch (e) {}
}

export function list_snapshots(sid) {
	let s = read_session(sid);
	if (!s)
		return { ok: true, snapshots: [] };

	// summarize what happened in each snapshot turn (tools executed, commands run)
	let turn_summary = {};
	for (let m of s.messages) {
		if (!m.turn)
			continue;
		if (m.kind == 'tool' && m.role == 'assistant') {
			for (let tc of (m.tool_calls || [])) {
				let label = tc.name;
				if (tc.name == 'exec_command' && tc.args && tc.args.command)
					label += ': ' + trunc(tc.args.command, 80);
				else if (tc.name == 'rollback')
					label += ': 第 ' + (tc.args && tc.args.turn) + ' 轮';
				push(turn_summary[m.turn] || (turn_summary[m.turn] = []), label);
			}
		}
		else if (m.kind == 'text' && m.role == 'user') {
			push(turn_summary[m.turn] || (turn_summary[m.turn] = []), '提问: ' + trunc(m.content, 60));
		}
	}

	let out = [];
	if (s.snapshots)
		for (let t in s.snapshots) {
			let sn = s.snapshots[t];
			push(out, {
				turn: int(t),
				ts: sn.ts,
				label: sn.label,
				file: sn.file,
				uci: sn.uci,
				actions: turn_summary[t] || []
			});
		}
	out.sort((a, b) => a.turn - b.turn);
	return { ok: true, snapshots: out };
}

// compare the uci state frozen in a snapshot against the current live uci state
export function snapshot_diff(sid, turn) {
	let s = read_session(sid);
	if (!s || !s.snapshots || !s.snapshots[turn])
		return { ok: false, text: '快照不存在' };

	let sn = s.snapshots[turn];
	let arch_uci = SNAP_DIR + '/' + sid + '/' + (sn.uci || '');

	let old_text = readfile(arch_uci) || '';
	let new_text = '';
	let r = popen('uci show 2>/dev/null').read('all');
	if (r != null)
		new_text = r;

	// show running diff (current vs snapshot): '+' = current added, '-' = snapshot-only
	if (access('/usr/bin/diff'))
		return run_diff('/usr/bin/diff', new_text, old_text);
	if (access('/bin/diff'))
		return run_diff('/bin/diff', new_text, old_text);

	// fallback: simple line-set diff
	function in_array(arr, val) {
		for (let i = 0; i < length(arr); i++)
			if (arr[i] == val)
				return true;
		return false;
	}

	let out = [];
	let old_lines = split(old_text, /\n/);
	let new_lines = split(new_text, /\n/);
	for (let l of new_lines)
		if (length(l) && !in_array(old_lines, l))
			push(out, '+ ' + l);
	for (let l of old_lines)
		if (length(l) && !in_array(new_lines, l))
			push(out, '- ' + l);
	return { ok: true, text: join(out, '\n') || '（无差异）' };
}

function run_diff(diffbin, new_text, old_text) {
	let f1 = randstr('/tmp/aias_diff') + '.new';
	let f2 = randstr('/tmp/aias_diff') + '.old';
	writefile(f1, new_text);
	writefile(f2, old_text);
	let out = popen(sprintf('%s -u %s %s 2>/dev/null', diffbin, shellquote(f2), shellquote(f1))).read('all') || '';
	popen('rm -f ' + shellquote(f1) + ' ' + shellquote(f2));
	return { ok: true, text: out || '（无差异）' };
}

export function get_snapshot_content(sid, turn) {
	let s = read_session(sid);
	if (!s || !s.snapshots || !s.snapshots[turn])
		return { ok: false, text: '快照不存在' };
	let sn = s.snapshots[turn];
	let arch_uci = SNAP_DIR + '/' + sid + '/' + (sn.uci || '');
	let content = readfile(arch_uci) || '（快照中无 uci 存档）';
	return { ok: true, text: content };
}

export function rollback_session(sid, turn, confirm) {
	if (confirm != 'yes')
		return { ok: false, text: '回滚需要确认参数 confirm=yes（防止误操作）' };

	let s = read_session(sid);
	if (!s)
		return { ok: false, text: '会话不存在' };

	turn = int(turn);
	if (!s.snapshots || !s.snapshots[turn])
		return { ok: false, text: sprintf('第 %d 轮没有配置快照（该轮未执行过写操作）', turn) };

	let sn  = s.snapshots[turn];
	let arch = SNAP_DIR + '/' + sid + '/' + sn.file;

	try {
		// 0. snapshot the current state as a formal snapshot first, so this
		//    rollback can itself be undone later (label: pre-rollback)
		create_snapshot(sid, 'pre-rollback');
		s = read_session(sid);

		// 1. also keep a raw tar in the undo dir as a second fallback
		let undo = sprintf('%s/undo_%s_%d.tar.gz', UNDO_DIR, sid, now());
		popen(sprintf('tar czf %s -C / etc/config 2>/dev/null', shellquote(undo))).read('all');

		// 2. restore files
		popen(sprintf('tar xzf %s -C / 2>/dev/null', shellquote(arch))).read('all');

		// 3. truncate session history to before this turn
		let keep = [];
		for (let m of s.messages)
			if (!(m.turn && m.turn >= turn))
				push(keep, m);
		s.messages = keep;
		s.turn = turn - 1;
		s.updated = now();
		delete s.snapshots[turn];
		write_session(s);

		// 4. apply configuration to services
		let reloaded = '';
		if (access('/sbin/reload_config')) {
			popen('/sbin/reload_config >/dev/null 2>&1').read('all');
			reloaded = '已执行 reload_config 重新应用配置';
		}

		audit(sprintf('rollback session=%s turn=%d file=%s', sid, turn, sn.file));
		return {
			ok: true,
			text: sprintf(
				'已回退到第 %d 轮对话前的状态（快照 %s）。%s\n' +
				'回滚前的状态已保存为 pre-rollback 快照，如需要可再次回滚撤销本次操作。\n' +
				'注意：回滚仅恢复 /etc/config 等文件配置，无法覆盖内核/进程运行时状态。' +
				'建议检查 network/firewall/dhcp 等服务状态，必要时 restart 一次。',
				turn, sn.file, reloaded
			),
			undo: undo
		};
	}
	catch (e) {
		return { ok: false, text: '回滚失败: ' + e };
	}
}

// ---------------------------------------------------------------- mtd backup

export function list_mtd() {
	try {
		let out = [];
		let lines = split(trim(readfile('/proc/mtd') || ''), /\n/);
		for (let i = 1; i < length(lines); i++) {
			let m = match(lines[i], /^(mtd\d+):\s*([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+"([^"]+)"/);
			if (m)
				push(out, { dev: m[1], size: m[2], erasesize: m[3], name: m[4] });
		}
		return { ok: true, parts: out };
	}
	catch (e) {
		return { ok: false, text: '读取 /proc/mtd 失败: ' + e };
	}
}

// available free space (KB) on the filesystem hosting `path`
function avail_kb(path) {
	let r = popen("df -P " + shellquote(path) + " 2>/dev/null | tail -1").read('all') || '';
	let cols = split(trim(r), /\s+/);
	if (length(cols) >= 4)
		return int(cols[3]) || 0;
	return 0;
}

// overlay mount line (used to warn about overlay-resize scenarios)
function overlay_info() {
	let r = popen("grep -E '(^| )overlay( |$)' /proc/mounts | head -1").read('all') || '';
	return trim(r);
}

// Smart MTD backup, adapted to the actual device layout (not hard-coded):
//   device='all'  -> small partitions (<= 8MB) + config archive + package list + checksums
//   device='mtdX' -> exactly that partition (big ones included / always space-checked)
//   device='full' -> every partition including firmware/rootfs/ubi whole-disk images
// Overlay-resize note: mtd images are physical partition snapshots; restoring them does not
// bring back a later overlay resize - use the config archive for day-to-day config recovery.
export function backup_mtd(device) {
	let lm = list_mtd();
	if (!lm.ok)
		return lm;

	device = device || 'all';

	let targets = [];
	let skipped = [];

	if (device != 'all' && device != 'full') {
		let hit = false;
		for (let p of lm.parts)
			if (p.dev == device) {
				push(targets, p);
				hit = true;
			}
		if (!hit)
			return { ok: false, text: '分区不存在: ' + device + '（可先用 list_mtd 查看分区表）' };
	}
	else {
		for (let p of lm.parts) {
			let sz_kb = int(p.size, 16) / 1024;
			let big = match(p.name, /firmware|kernel|rootfs|ubi|image/i) || sz_kb > 8192;
			if (device == 'full' || !big)
				push(targets, p);
			else
				push(skipped, sprintf('%s(%s,%dkB)', p.dev, p.name, sz_kb));
		}
	}

	if (!length(targets))
		return { ok: false, text: '没有可备份的分区（大分区默认跳过，可显式指定 device=mtdX 或 device=full）' };

	try {
		mkdir(MTD_DIR, 0700);

		let ts = now();
		let dir_now = sprintf('%s/mtdbackup_%d', MTD_DIR, ts);
		mkdir(dir_now, 0700);

		// space pre-check: refuse when the image would fill the backing filesystem
		let need_kb = 0;
		for (let p of targets)
			need_kb += int(p.size, 16) / 1024;
		let free_kb = avail_kb(MTD_DIR);
		if (free_kb > 0 && need_kb > free_kb * 0.9)
			return {
				ok: false,
				text: sprintf(
					'空间不足：本次需要约 %d MB，而 %s 所在分区仅剩约 %d MB。\n' +
					'请先挂载 U 盘/存储卡（建议挂到 /mnt 后在设置页把备份目录指过去），' +
					'或改用 device=mtdX 只备份小分区、日常恢复用 config_backup.tar.gz。',
					need_kb / 1024, MTD_DIR, free_kb / 1024
				)
			};

		let done = [];

		// 1. partition table
		popen('cat /proc/mtd > ' + shellquote(dir_now + '/partition_table.txt') + ' 2>/dev/null').read('all');
		push(done, 'partition_table.txt (分区表)');

		// 2. raw images of the selected partitions (single dd, bs=128k)
		for (let p of targets) {
			let sz_kb = int(p.size, 16) / 1024;
			let fname = replace(sprintf('%s_%s.bin', p.dev, p.name), /[^a-zA-Z0-9._-]/g, '_');
			let out = dir_now + '/' + fname;
			popen(sprintf('dd if=/dev/%s of=%s bs=128k 2>/dev/null', p.dev, shellquote(out))).read('all');
			push(done, sprintf('%s(%s,%dkB)', p.dev, p.name, sz_kb));
		}

		// 3. config archive via sysupgrade -b (lightweight, day-to-day recovery)
		if (access('/sbin/sysupgrade')) {
			let cfg = dir_now + '/config_backup.tar.gz';
			popen('sysupgrade -b ' + shellquote(cfg) + ' >/dev/null 2>&1').read('all');
			if (access(cfg))
				push(done, 'config_backup.tar.gz (sysupgrade 配置归档，日常恢复用)');
		}

		// 4. installed packages list (opkg or apk)
		let pkgs = dir_now + '/installed_packages.txt';
		if (access('/usr/bin/apk') || access('/bin/apk'))
			popen('apk list -I > ' + shellquote(pkgs) + ' 2>/dev/null').read('all');
		else
			popen('opkg list-installed > ' + shellquote(pkgs) + ' 2>/dev/null').read('all');
		if (access(pkgs))
			push(done, 'installed_packages.txt (已装软件清单)');

		// 5. checksums
		popen('cd ' + shellquote(dir_now) + ' && md5sum *.bin *.tar.gz *.txt > md5sum.txt 2>/dev/null').read('all');
		if (access(dir_now + '/md5sum.txt'))
			push(done, 'md5sum.txt (校验和)');

		// 6. notes
		let notes = [];
		let ov = overlay_info();
		if (length(ov))
			push(notes, '· 检测到 overlay 挂载：' + ov);
		push(notes, '· 说明：MTD 镜像是物理分区快照，不包含 overlay 扩容（resize）的成果；恢复分区镜像后分区会回到备份时的大小，需要按原布局重新扩容。日常配置级恢复请使用 config_backup.tar.gz。');
		if (length(skipped))
			push(notes, '· 已跳过大分区（如需要请用 device=mtdX 或 device=full 显式备份）：' + join(skipped, ', '));

		audit('mtd backup: ' + join(done, ', '));

		return {
			ok: true,
			text: 'MTD 智能备份完成，目录: ' + dir_now + '\n\n内容：\n- ' + join(done, '\n- ') + '\n\n' + join(notes, '\n')
		};
	}
	catch (e) {
		return { ok: false, text: 'MTD 备份失败: ' + e };
	}
}

// ---------------------------------------------------------------- permission & exec

export function check_exec(permission, command, cfg) {
	if (!command || !length(trim(command)))
		return { ok: false, reason: '空命令' };

	if (length(command) > MAX_COMMAND_LEN)
		return { ok: false, reason: '命令过长' };

	if (permission == 'readonly')
		return { ok: false, reason: '当前为只读权限（readonly），AI 无权执行命令' };

	for (let re of FATAL_PATTERNS)
		if (match(command, re))
			return { ok: false, reason: '危险命令被拦截（该操作无法通过快照恢复）' };

	if (permission == 'full')
		return { ok: true };

	// limited: no compound / injection constructs
	if (match(command, LIMITED_OPERATORS))
		return { ok: false, reason: '受限模式（limited）禁止复合命令与危险操作符' };

	if (match(command, /\.\./))
		return { ok: false, reason: '受限模式禁止路径穿越' };

	let c = trim(command);
	for (let pre of cfg.exec_allow)
		if (substr(c, 0, length(pre)) == pre)
			return { ok: true };

	return { ok: false, reason: '命令不在受限模式白名单（可在设置页 exec_allowlist 添加前缀，或切换到 full 权限）' };
}

function run_shell(command, timeout_sec) {
	let out = randstr('/tmp/aiassist_exec');
	let rc  = out + '.rc';
	try {
		let cmd = sprintf('timeout %d sh -c %s > %s 2>&1; echo $? > %s', timeout_sec, shellquote(command), shellquote(out), shellquote(rc));
		popen(cmd).read('all');
		let code = trim(readfile(rc) || '');
		let body = readfile(out) || '';
		return { code, output: body };
	}
	catch (e) {
		return { code: 'x', output: '执行失败: ' + e };
	}
}

export function exec_command(cfg, command, sid, permission) {
	let check = check_exec(permission, command, cfg);
	if (!check.ok) {
		audit(sprintf('exec DENIED session=%s perm=%s cmd=%s', sid, permission, substr(command, 0, 200)));
		return { ok: false, text: '权限拒绝：' + check.reason, denied: true };
	}

	if (cfg.auto_snapshot)
		create_snapshot(sid, 'auto before exec');

	let to = int(cfg.exec_timeout) || 30;
	let r = run_shell(command, to);
	let out = trunc(r.output, cfg.max_output);
	audit(sprintf('exec session=%s perm=%s rc=%s to=%ds cmd=%s', sid, permission, r.code, to, substr(command, 0, 500)));
	return { ok: true, code: r.code, text: sprintf('命令已执行（exit=%s）：\n%s', r.code, out) };
}

// ---------------------------------------------------------------- view / system info

function allowed_view_path(cfg, path) {
	try {
		let rp = realpath(path);
		if (!rp)
			return false;
		for (let p of cfg.view_paths) {
			let rpp = realpath(p) || p;
			if (substr(rp, 0, length(rpp)) == rpp)
				return true;
		}
	}
	catch (e) {}
	return false;
}

export function view_config(cfg, target) {
	if (!target || target == 'all') {
		let r = run_shell('uci show 2>/dev/null', 10);
		return { ok: true, text: trunc(r.output, MAX_VIEW_LEN) };
	}

	if (match(target, /^[a-zA-Z0-9_-]{1,32}$/)) {
		let r = run_shell('uci show ' + target + ' 2>/dev/null', 10);
		return { ok: true, text: trunc(r.output, MAX_VIEW_LEN) };
	}

	if (substr(target, 0, 1) == '/') {
		if (!allowed_view_path(cfg, target))
			return { ok: false, text: '路径不在允许列表（可在设置页 view_paths 添加）: ' + target };
		let r = run_shell('ls -la ' + shellquote(target) + ' 2>/dev/null; cat ' + shellquote(target) + ' 2>/dev/null', 10);
		return { ok: true, text: trunc(r.output, MAX_VIEW_LEN) };
	}

	return { ok: false, text: '无效的查看目标（使用 all / UCI 包名 / 绝对路径）' };
}

export function get_system_info() {
	let parts = [];

	let rel = readfile('/etc/openwrt_release') || readfile('/etc/openwrt_version') || 'unknown';
	push(parts, '== OpenWrt ==\n' + trim(rel));

	let ver = readfile('/proc/version');
	if (ver)
		push(parts, '== Kernel ==\n' + trim(split(ver, /\n/)[0]));

	let up = readfile('/proc/uptime');
	if (up)
		push(parts, '== Uptime ==\n' + trim(up));

	let load = readfile('/proc/loadavg');
	if (load)
		push(parts, '== Load ==\n' + trim(load));

	let mem = readfile('/proc/meminfo');
	if (mem) {
		let mt = match(mem, /MemTotal:\s+(\d+) kB/);
		let mf = match(mem, /MemFree:\s+(\d+) kB/);
		let ma = match(mem, /MemAvailable:\s+(\d+) kB/);
		let mc = match(mem, /Cached:\s+(\d+) kB/);
		push(parts, sprintf('== Memory ==\nTotal: %s kB  Free: %s kB  Available: %s kB  Cached: %s kB',
			mt ? mt[1] : '?', mf ? mf[1] : '?', ma ? ma[1] : '?', mc ? mc[1] : '?'));
	}

	let cpu = readfile('/proc/cpuinfo');
	if (cpu) {
		let mm = match(cpu, /model name\s*:\s*(.+)/) || match(cpu, /Processor\s*:\s*(.+)/);
		let cores = length(split(cpu, /processor\s*:/)) - 1;
		push(parts, sprintf('== CPU ==\n%s (%d core)', mm ? trim(mm[1]) : 'unknown', cores));
	}

	let disk = run_shell('df -h 2>/dev/null', 5);
	if (disk.output)
		push(parts, '== Disk ==\n' + disk.output);

	let route = run_shell('ip -4 route show default 2>/dev/null; ip -6 route show default 2>/dev/null; echo; ip -4 addr show 2>/dev/null | grep -E "inet |^[0-9]"', 5);
	if (route.output)
		push(parts, '== Network ==\n' + trunc(route.output, 4000));

	let temps = [];
	try {
		for (let z in lsdir('/sys/class/thermal'))
			if (substr(z, 0, 11) == 'thermal_zone') {
				let t = readfile('/sys/class/thermal/' + z + '/temp');
				if (t)
					push(temps, z + ': ' + int(t) / 1000 + 'C');
			}
	}
	catch (e) {}
	if (length(temps))
		push(parts, '== Thermal ==\n' + join(temps, '  '));

	return { ok: true, text: join(parts, '\n\n') };
}

export function get_log(lines) {
	lines = int(lines) || 100;
	if (lines < 1) lines = 1;
	if (lines > 500) lines = 500;
	let r = run_shell('logread -l ' + lines + ' 2>/dev/null', 10);
	return { ok: true, text: trunc(r.output, MAX_VIEW_LEN) };
}
