// LuCI AI Assistant - orchestration layer (ucode)
// Path: /usr/share/ucode/aiassist/core.uc
// Licensed under the Apache License 2.0.

'use strict';

// ---------------------------------------------------------------- imports & shared utils

import { access, popen, readfile, writefile, mkdir, stat, unlink, lsdir, basename } from 'fs';
import {
	load_config, read_session, write_session, estimate_session_tokens, trunc,
	create_snapshot, list_snapshots, rollback_session, backup_mtd, list_mtd,
	exec_command, view_config, get_system_info, get_log, shellquote, randstr
} from 'aiassist.lib';
import { tools_for_permission, call_ai, summarize_messages } from 'aiassist.proto';

// ---------------------------------------------------------------- system prompt

export function build_full_system(cfg) {
	let perm = {
		readonly: '只读（readonly）：AI 只能查看配置与系统状态，不能执行任何命令，只能给出建议',
		limited:  '受限（limited）：AI 只能执行白名单内的命令（uci 读写、服务 reload、常用诊断），危险操作被拒绝',
		full:     '全权负责（full）：AI 拥有 root 权限，可执行任意命令，无需逐条审批'
	}[cfg.permission] || '未知权限模式';

	let sys =
		'你是运行在 OpenWrt 路由器上的 AI 配置调优助手（LuCI AI Assistant）。\n' +
		'当前权限模式：' + perm + '。\n' +
		'工作规则：\n' +
		'1. 先查看再操作：用 get_system_info / view_config 了解现状，再给出调优意见或执行操作；不得在未查看的情况下凭空修改配置。\n' +
		'2. 执行任何写操作前，先用一句话说明要做什么及原因；一次只做一件事，不批量堆砌改动。\n' +
		'3. 修改配置优先用 uci 命令（uci set/delete/add/commit）；生效用 /etc/init.d/<服务> reload（network/firewall/dhcp/wireless 等），必要时再 restart。\n' +
		'4. 每次写操作前系统会自动创建 /etc/config 配置快照；用户要求回退时用 list_backups 查看快照、rollback 回滚（confirm=yes）。\n' +
		'5. 回滚只能恢复 /etc/config 等文件配置，无法还原进程/内核运行时状态；回滚后应检查相关服务状态。\n' +
		'6. 目标设备是 128MB 内存的普通路由器：不要提议安装大型软件包；诊断命令（top、大日志）要节制使用。\n' +
		'7. 支持查看任意第三方 LuCI 插件的 /etc/config 配置（view_config 的 target 传包名即可），调优建议应覆盖全局而非只看单一模块。\n' +
		'8. 权限受限时如实告知用户哪些操作做不了，并给出替代建议。\n' +
		'9. 使用简体中文回答，输出简洁、专业、可执行；先给结论，再给依据与命令。\n' +
		'10. 只做与 OpenWrt 配置查看/调优/回滚相关的操作，不做无关事项。\n' +
		'11. 红线（任何时候都禁止，除非用户明确要求）：修改 root 密码或登录凭据；执行 sysupgrade/刷写固件；恢复出厂设置（firstboot）；关闭防火墙并断开远程；重启路由器。\n' +
		'12. 命令纪律：一次只执行一条完整命令，不得用 ; && || | 拼接多条命令（受限模式下也会被拦截）；优先使用专用工具（如备份用 create_backup、查看用 view_config），而非 raw shell。\n' +
		'13. 若某步操作失败，先查看日志（get_log）定位原因，再给出修正方案，不要盲目重试。';

	if (cfg.system_prompt && length(trim(cfg.system_prompt)))
		sys += '\n\n用户补充要求：' + trim(cfg.system_prompt);

	return sys;
}

// ---------------------------------------------------------------- tool dispatch

function dispatch_tool(name, args, ctx) {
	args = args || {};
	let cfg = ctx.cfg;
	let sid = ctx.sid;
	let permission = ctx.permission;

	switch (name) {
		case 'get_system_info':
			return get_system_info();
		case 'view_config':
			return view_config(cfg, args.target);
		case 'exec_command':
			return exec_command(cfg, args.command, sid, permission);
		case 'create_backup':
			return create_snapshot(sid, args.comment || 'manual');
		case 'list_backups':
			return list_snapshots(sid);
		case 'rollback':
			return rollback_session(sid, args.turn, args.confirm);
		case 'list_mtd':
			return list_mtd();
		case 'backup_mtd':
			if (permission != 'full')
				return { ok: false, text: 'MTD 备份仅限 full 权限使用' };
			return backup_mtd(args.device || 'all');
		case 'get_log':
			return get_log(args.lines);
		default:
			return { ok: false, text: '未知工具: ' + name };
	}
}

// ---------------------------------------------------------------- context compression

export function compress_session(sid) {
	let s = read_session(sid);
	if (!s)
		return { ok: false, changed: false, reason: '会话不存在' };

	// group text rounds by turn number, keep chronological order
	let rounds = {};
	let order = [];
	let __arr0 = s.messages;
for (let __i0 = 0; __i0 < length(__arr0); __i0++) {
	let m = __arr0[__i0];
	{
		if ((m.role == 'user' || m.role == 'assistant') && m.kind == 'text' && m.turn) {
			if (!rounds[m.turn]) {
				rounds[m.turn] = [];
				push(order, m.turn);
			}
			push(rounds[m.turn], m);
		}
	}
}


	if (length(order) <= 1)
		return { ok: false, changed: false, reason: '对话太短，无需压缩' };

	let target = int(length(order) / 2);
	if (target < 1)
		target = 1;

	let victim = [];
	let victim_turns = {};
	for (let i = 0; i < target; i++) {
		let t = order[i];
		victim_turns[t] = 1;
		let __arr1 = rounds[t];
for (let __i1 = 0; __i1 < length(__arr1); __i1++) {
	let m = __arr1[__i1];
	push(victim, m);
}

	}

	let cfg = load_config();
	let sum = summarize_messages(cfg, victim);
	let summary;
	if (sum.ok && length(sum.summary) > 0) {
		summary = sum.summary;
	}
	else {
		summary = '[上下文已压缩：最早 ' + target + ' 轮对话被截断，AI 摘要不可用（' + (sum.error || '未知原因') + '）]';
	}

	let final = [ { role: 'system', kind: 'summary', content: summary, ts: time() } ];
	let __arr2 = s.messages;
for (let __i2 = 0; __i2 < length(__arr2); __i2++) {
	let m = __arr2[__i2];
	if (!(m.turn && victim_turns[m.turn]))
			push(final, m);
}

	s.messages = final;
	s.updated = time();
	write_session(s);

	return { ok: true, changed: true, removed_turns: target, estimated: estimate_session_tokens(s) };
}

function auto_compress(sid, cfg) {
	let guard = 0;
	let s = read_session(sid);
	while (s && estimate_session_tokens(s) > cfg.context_threshold && length(s.messages) > 6 && guard < 4) {
		let r = compress_session(sid);
		if (!r.ok || !r.changed)
			break;
		s = read_session(sid);
		guard++;
	}
}

// ---------------------------------------------------------------- AI loop

export function run_ai_loop(cfg, sid, content, jobid) {
	let s = read_session(sid);
	if (!s)
		return { error: '会话不存在' };

	// hard cap: refuse to grow the session beyond max_session_tokens
	if (estimate_session_tokens(s) + estimate_tokens(content) > cfg.max_session_tokens) {
		return {
			error: sprintf(
				'会话上下文已超过硬上限（%d tokens）。请先手动「压缩上下文」，或开新会话继续。',
				cfg.max_session_tokens
			)
		};
	}

	auto_compress(sid, cfg);
	s = read_session(sid);

	// append the new user message
	s.turn = int(s.turn || 0) + 1;
	let turn = s.turn;
	push(s.messages, { role: 'user', kind: 'text', content, ts: time(), turn });
	s.updated = time();
	write_session(s);

	let tools = tools_for_permission(cfg.permission);
	let sys = build_full_system(cfg);
	let executed = [];
	let final_text = null;
	let stop = false;
	let loop = 0;
	let max_rounds = cfg.max_tool_rounds || 6;

	while (loop < max_rounds && !stop) {
		if (is_job_stopped(jobid)) {
			final_text = '（已停止）';
			stop = true;
			break;
		}

		let resp = call_ai(cfg, s.messages, tools, sys);
		if (resp.error) {
			// keep the user message in history, surface the error to the UI
			return { error: resp.error, tools: executed };
		}

		if (!resp.tool_calls || !length(resp.tool_calls)) {
			final_text = resp.text || '（AI 未返回内容）';
			break;
		}

		let __arr3 = resp.tool_calls;
for (let __i3 = 0; __i3 < length(__arr3); __i3++) {
	let tc = __arr3[__i3];
	{
			// reload session before dispatching: dispatch may write snapshots / truncate history
			s = read_session(sid);

			let r = dispatch_tool(tc.name, tc.args, { cfg, sid, permission: cfg.permission });
			push(executed, { name: tc.name, args: tc.args, ok: !!r.ok });

			s = read_session(sid);
			push(s.messages, { role: 'assistant', kind: 'tool', tool_calls: [ tc ], text: null, ts: time(), turn });
			push(s.messages, { role: 'user', kind: 'tool', tool_call_id: tc.id, content: trunc(r.text || '（无输出）', cfg.max_output), ts: time(), turn });
			s.updated = time();
			write_session(s);

			if (tc.name == 'rollback' && r.ok) {
				// history already truncated inside rollback_session
				stop = true;
				final_text = r.text;
				break;
			}

			if (is_job_stopped(jobid)) {
				stop = true;
				final_text = '（已停止）';
				break;
			}
		}
}


		loop++;
	}

	if (!stop) {
		if (!final_text)
			final_text = sprintf('（已达到最大工具调用轮数 %d，请继续提问）', max_rounds);
		s = read_session(sid);
		push(s.messages, { role: 'assistant', kind: 'text', content: final_text, ts: time(), turn });
		s.updated = time();
		write_session(s);
	}

	return { reply: final_text, tools: executed, rounds: loop };
}

function estimate_tokens(text) {
	text = '' + (text || '');
	let cjk = 0;
	for (let i = 0; i < length(text); i++) {
		let c = ord(substr(text, i, 1));
		if ((c >= 0x4e00 && c <= 0x9fff) || (c >= 0x3400 && c <= 0x4dbf))
			cjk++;
	}
	let other = length(text) - cjk;
	return int(cjk * 1.5 + other / 4 + 0.999);
}

// ---------------------------------------------------------------- jobs (async worker)

function job_path(id) {
	return '/etc/aiassist/jobs/' + id + '.json';
}

export function read_job(id) {
	try {
		let raw = readfile(job_path(id));
		if (raw) {
			let j = json(raw);
			if (type(j) == 'object')
				return j;
		}
	}
	catch (e) {}
	return null;
}

export function write_job(j) {
	writefile(job_path(j.id), json(j));
}

export function is_job_stopped(id) {
	return access('/etc/aiassist/jobs/' + id + '.stop');
}

export function stop_job(id) {
	writefile('/etc/aiassist/jobs/' + id + '.stop', time() + '\n');
	return { ok: true };
}

export function lock_session(sid) {
	let lockdir = '/etc/aiassist/locks/' + sid;
	let lockfile = lockdir + '/lock';
	try {
		mkdir(lockdir, 0700);
		writefile(lockfile, time() + '\n');
		return true;
	}
	catch (e) {
		// lock exists: recover stale locks (worker crashed) after 10 minutes
		try {
			let st = stat(lockfile);
			if (st && st.mtime && time() - int(st.mtime) > 600) {
				popen('rmdir ' + shellquote(lockdir) + ' 2>/dev/null');
				mkdir(lockdir, 0700);
				writefile(lockfile, time() + '\n');
				return true;
			}
		}
		catch (e2) {}
		return false; // still locked
	}
}

export function unlock_session(sid) {
	popen('rmdir /etc/aiassist/locks/' + sid + ' 2>/dev/null');
}

// lazily remove stale job files (done/error > 1h, stuck queued > 5min)
export function cleanup_jobs() {
	try {
		for (let f in lsdir('/etc/aiassist/jobs')) {
			if (substr(f, -5) != '.json')
				continue;
			let j = read_job(basename(f, '.json'));
			if (!j)
				continue;
			let age = time() - int(j.created || 0);
			if ((j.status == 'done' || j.status == 'error') && (time() - int(j.done_ts || 0)) > 3600) {
				unlink('/etc/aiassist/jobs/' + j.id + '.json');
				unlink('/etc/aiassist/jobs/' + j.id + '.stop');
			}
			else if (j.status == 'queued' && age > 300) {
				unlink('/etc/aiassist/jobs/' + j.id + '.json');
				unlink('/etc/aiassist/jobs/' + j.id + '.stop');
			}
		}
	}
	catch (e) {}
}

export function submit_job(sid, content, type) {
	let s = read_session(sid);
	if (!s)
		return { error: '会话不存在' };

	cleanup_jobs();

	if (!lock_session(sid))
		return { error: '该会话已有任务正在运行，请等待完成或先停止' };

	let jobid = randstr('j');
	let job = {
		id: jobid, sid, type: type || 'msg', status: 'queued',
		content, created: time(), done_ts: 0, reply: null, tools: [], error: null
	};
	write_job(job);

	let worker = '/usr/bin/ucode /usr/libexec/aiassist/worker.uc';
	popen(sprintf('nohup %s %s %s >/dev/null 2>&1 &', worker, shellquote(sid), shellquote(jobid)));

	return { job: jobid };
}

export function poll_job(id) {
	return read_job(id);
}

// ---------------------------------------------------------------- main worker entry

export function run_job(job) {
	let cfg = load_config();
	if (!cfg.enabled)
		return { error: 'AI 助手未启用，请在设置页开启' };

	let sid = job.sid;

	if (job.type == 'compress') {
		let r = compress_session(sid);
		return { reply: r.ok ? sprintf('已压缩 %d 轮，当前约 %d tokens', r.removed_turns || 0, r.estimated || 0) : r.reason, compress: r };
	}

	return run_ai_loop(cfg, sid, job.content, job.id);
}
