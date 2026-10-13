// LuCI AI Assistant - AI protocol adapter (ucode)
// Path: /usr/share/ucode/aiassist/proto.uc
// Licensed under the Apache License 2.0.

'use strict';

import { popen, readfile, writefile } from 'fs';
import { shellquote, randstr } from 'aiassist.lib';

// ---------------------------------------------------------------- endpoints & headers

export function api_endpoint(cfg) {
	let base = trim(cfg.base_url);
	base = replace(base, /\/+$/, '');
	if (cfg.provider == 'anthropic') {
		if (match(base, /\/v1\/messages$/))
			return base;
		return base + '/v1/messages';
	}
	if (match(base, /\/chat\/completions$/))
		return base;
	return base + '/chat/completions';
}

function api_headers(cfg) {
	if (cfg.provider == 'anthropic')
		return [
			'Content-Type: application/json',
			'x-api-key: ' + cfg.api_key,
			'anthropic-version: 2023-06-01'
		];
	return [
		'Content-Type: application/json',
		'Authorization: Bearer ' + cfg.api_key
	];
}

// ---------------------------------------------------------------- tool definitions

// unified tool spec: { name, description, parameters }
const TOOL_DEFS = [
	{
		name: 'get_system_info',
		description: '查看设备系统概况（OpenWrt 版本、内核、CPU、内存、负载、磁盘、网络、温度）。无参数。',
		parameters: { type: 'object', properties: {} }
	},
	{
		name: 'view_config',
		description: '查看 OpenWrt 配置。target 可以是 "all"（全部 UCI 配置）、某个 UCI 包名（如 network、wireless、firewall、dhcp、luci 或任何第三方插件包名），或受允许的文件绝对路径（如 /etc/config/network、/etc/firewall.user）。只读，不修改任何内容。建议优先按包名查看，避免 "all" 产生超大输出。',
		parameters: {
			type: 'object',
			properties: { target: { type: 'string', description: 'all / UCI 包名 / 允许的文件路径' } }
		}
	},
	{
		name: 'exec_command',
		description: '在路由器上执行一条 shell 命令进行调优。执行前会自动创建 /etc/config 配置快照（可回滚）。一次只传一条完整命令；如需多条命令请分多次调用。禁止用 ; && || 拼接（受限模式下会被拦截）。',
		parameters: {
			type: 'object',
			properties: { command: { type: 'string', description: '要执行的单条完整 shell 命令' } },
			required: [ 'command' ]
		}
	},
	{
		name: 'create_backup',
		description: '手动创建配置快照（/etc/config 等关键文件 + uci show 存档），用于后续回滚。可选 comment 备注。',
		parameters: {
			type: 'object',
			properties: { comment: { type: 'string', description: '快照备注' } }
		}
	},
	{
		name: 'list_backups',
		description: '列出当前会话的所有配置快照（含轮次与时间）。无参数。',
		parameters: { type: 'object', properties: {} }
	},
	{
		name: 'rollback',
		description: '把配置回滚到第 turn 次对话写操作之前的状态（恢复 /etc/config 快照并截断会话历史）。这是不可逆操作，只有当用户明确要求回退时才能调用，且 confirm 必须为 "yes"。回滚会截断历史，请谨慎。',
		parameters: {
			type: 'object',
			properties: {
				turn: { type: 'integer', description: '要回退到的对话轮次（见 list_backups）' },
				confirm: { type: 'string', enum: [ 'yes', 'no' ], description: '必须为 yes 才会执行' }
			},
			required: [ 'turn', 'confirm' ]
		}
	},
	{
		name: 'list_mtd',
		description: '列出 MTD 分区表（/proc/mtd）。无参数。',
		parameters: { type: 'object', properties: {} }
	},
	{
		name: 'backup_mtd',
		description: '备份 MTD 分区到 /etc/aiassist/mtd/（dd 全量拷贝）。device 为 "all"（跳过 firmware/rootfs 分区）或具体 mtdX。仅 full 权限可用，注意 flash 空间。',
		parameters: {
			type: 'object',
			properties: { device: { type: 'string', description: 'all 或 mtdX' } }
		}
	},
	{
		name: 'get_log',
		description: '读取系统日志（logread）。lines 指定行数，默认 100，最大 500。',
		parameters: {
			type: 'object',
			properties: { lines: { type: 'integer', description: '日志行数' } }
		}
	}
];

export function tools_for_permission(permission) {
	let allowed = { get_system_info: 1, view_config: 1, get_log: 1, list_mtd: 1 };
	if (permission == 'limited')
		allowed = { get_system_info: 1, view_config: 1, get_log: 1, list_mtd: 1,
			exec_command: 1, create_backup: 1, list_backups: 1, rollback: 1 };
	if (permission == 'full')
		allowed = { get_system_info: 1, view_config: 1, get_log: 1, list_mtd: 1,
			exec_command: 1, create_backup: 1, list_backups: 1, rollback: 1, backup_mtd: 1 };

	let out = [];
	for (let t of TOOL_DEFS)
		if (allowed[t.name])
			push(out, t);
	return out;
}

function to_openai_tools(tools) {
	let out = [];
	for (let t of tools)
		push(out, { type: 'function', function: { name: t.name, description: t.description, parameters: t.parameters } });
	return out;
}

function to_anthropic_tools(tools) {
	let out = [];
	for (let t of tools)
		push(out, { name: t.name, description: t.description, input_schema: t.parameters });
	return out;
}

// ---------------------------------------------------------------- summary handling

export function collect_summary_text(messages) {
	let parts = [];
	for (let m of messages)
		if (m.kind == 'summary')
			push(parts, m.content);
	return length(parts) ? join_parts(parts) : null;
}

function join_parts(parts) {
	let out = '';
	for (let i = 0; i < length(parts); i++)
		out += (i ? '\n\n' : '') + parts[i];
	return out;
}

// ---------------------------------------------------------------- message conversion

// merge adjacent messages of the same role (text-only) for OpenAI
function merge_adjacent_openai(arr) {
	let out = [];
	for (let m of arr) {
		let last = out[length(out) - 1];
		if (last && last.role == m.role && last.content != null && m.content != null && !last.tool_calls && !m.tool_calls)
			last.content = last.content + '\n\n' + m.content;
		else
			push(out, m);
	}
	return out;
}

function to_openai_messages(messages, sys_text) {
	let out = [];
	if (sys_text && length(sys_text))
		push(out, { role: 'system', content: sys_text });

	for (let m of messages) {
		if (m.kind == 'summary')
			continue;

		if (m.kind == 'tool' && m.role == 'assistant') {
			let tcs = [];
			for (let tc of (m.tool_calls || []))
				push(tcs, { id: tc.id, type: 'function', function: { name: tc.name, arguments: json(tc.args || {}) } });
			push(out, { role: 'assistant', content: null, tool_calls: tcs });
		}
		else if (m.kind == 'tool' && m.role == 'user') {
			push(out, { role: 'tool', tool_call_id: m.tool_call_id, content: m.content || '' });
		}
		else {
			push(out, { role: m.role, content: m.content || '' });
		}
	}

	return merge_adjacent_openai(out);
}

function merge_adjacent_anthropic(arr) {
	let out = [];
	for (let m of arr) {
		let last = out[length(out) - 1];
		if (last && last.role == m.role) {
			last.content = [ ...last.content, ...m.content ];
		}
		else {
			push(out, m);
		}
	}
	return out;
}

function to_anthropic_messages(messages) {
	let out = [];
	for (let m of messages) {
		// anthropic does not allow role=system inside messages; summaries & system go to the system field
		if (m.kind == 'summary' || m.role == 'system')
			continue;

		if (m.role == 'assistant' && m.kind == 'tool') {
			let blocks = [];
			if (m.text && length(m.text))
				push(blocks, { type: 'text', text: m.text });
			for (let tc of (m.tool_calls || []))
				push(blocks, { type: 'tool_use', id: tc.id, name: tc.name, input: tc.args || {} });
			push(out, { role: 'assistant', content: blocks });
		}
		else if (m.role == 'user' && m.kind == 'tool') {
			push(out, { role: 'user', content: [ { type: 'tool_result', tool_use_id: m.tool_call_id, content: m.content || '' } ] });
		}
		else {
			push(out, { role: m.role, content: [ { type: 'text', text: m.content || '' } ] });
		}
	}
	return merge_adjacent_anthropic(out);
}

// ---------------------------------------------------------------- core API call

function parse_openai(data) {
	let choice = data?.choices?.[0];
	if (!choice)
		return { error: 'API 响应缺少 choices 字段' };

	let msg = choice.message || {};
	let text = (msg.content != null) ? ('' + msg.content) : null;
	let tool_calls = [];
	for (let tc of (msg.tool_calls || [])) {
		let args = {};
		try {
			args = json(tc.function.arguments);
		}
		catch (e) {}
		push(tool_calls, { id: tc.id, name: tc.function.name, args });
	}
	return { text, tool_calls };
}

function parse_anthropic(data) {
	let text = null;
	let tool_calls = [];
	for (let blk of (data.content || [])) {
		if (blk.type == 'text')
			text = (text ? text : '') + blk.text;
		else if (blk.type == 'tool_use')
			push(tool_calls, { id: blk.id, name: blk.name, args: blk.input || {} });
	}
	return { text, tool_calls };
}

export function call_ai(cfg, messages, tools, extra_system) {
	if (!cfg.api_key || !length(cfg.api_key))
		return { error: '未配置 API Key，请在设置页填写并保存' };
	if (!cfg.model || !length(cfg.model))
		return { error: '未配置模型 ID（model）' };

	let summary = collect_summary_text(messages);
	let sys_text = '';
	if (extra_system && length(extra_system))
		sys_text = extra_system;
	if (summary)
		sys_text = (length(sys_text) ? sys_text + '\n\n' : '') + '[历史对话摘要]\n' + summary;

	let payload;
	if (cfg.provider == 'anthropic') {
		let sys_blocks = [];
		if (length(sys_text))
			push(sys_blocks, { type: 'text', text: sys_text });
		if (!length(sys_blocks))
			push(sys_blocks, { type: 'text', text: '你是一个 OpenWrt 网络设备调优助手。' });

		payload = {
			model: cfg.model,
			max_tokens: cfg.max_tokens || 2048,
			temperature: cfg.temperature,
			system: sys_blocks,
			messages: to_anthropic_messages(messages)
		};
		if (length(tools))
			payload.tools = to_anthropic_tools(tools);
	}
	else {
		payload = {
			model: cfg.model,
			temperature: cfg.temperature,
			max_tokens: cfg.max_tokens || 2048,
			messages: to_openai_messages(messages, sys_text)
		};
		if (length(tools))
			payload.tools = to_openai_tools(tools);
	}

	// perform the HTTP request via curl (no long-lived process, router friendly)
	// network-level failures are retried with backoff; HTTP 4xx/5xx are not retried
	let retries = int(cfg.api_retries) || 2;
	let last = null;

	for (let attempt = 0; attempt <= retries; attempt++) {
		last = http_once(cfg, payload);
		if (!last.error)
			return last;

		// 4xx / provider-side errors: do not retry
		if (match(last.error, /(^|: )(401|403|404|429)\b|invalid|not (found|supported)|insufficient|exceeded/))
			return last;

		if (attempt < retries)
			sleep(1 + attempt); // 1s / 2s / 3s backoff
	}

	return last;
}

function http_once(cfg, payload) {
	let bodyfile = randstr('/tmp/aiassist_body') + '.json';
	let respfile = randstr('/tmp/aiassist_resp') + '.json';
	let rcfile   = respfile + '.rc';

	try {
		writefile(bodyfile, json(payload));

		let curl = sprintf('curl -sS --max-time %d -o %s --data-binary @%s', cfg.timeout, respfile, bodyfile);
		if (cfg.proxy && length(cfg.proxy))
			curl += ' --proxy ' + shellquote(cfg.proxy);
		for (let h of api_headers(cfg))
			curl += ' -H ' + shellquote(h);
		curl += ' ' + shellquote(api_endpoint(cfg)) + '; echo $? > ' + rcfile;

		popen(curl).read('all');

		let rc = trim(readfile(rcfile) || '');
		if (rc != '0')
			return { error: sprintf('API 网络请求失败（curl exit=%s，已重试 %d 次）：检查网络/代理/Base URL', rc, int(cfg.api_retries) || 2) };

		let body = readfile(respfile) || '';
		if (!length(body))
			return { error: 'API 返回空响应（HTTP 4xx/5xx 时常见，请检查 Key/Base URL 权限）' };

		let data;
		try {
			data = json(body);
		}
		catch (e) {
			return { error: 'API 响应不是有效 JSON（可能被网关/代理拦截）' };
		}

		if (data?.error) {
			let m = data.error.message || data.error.type || '未知错误';
			return { error: 'API 返回错误: ' + m };
		}

		if (cfg.provider == 'anthropic')
			return parse_anthropic(data);
		return parse_openai(data);
	}
	catch (e) {
		return { error: 'AI 调用异常: ' + e };
	}
}

// ---------------------------------------------------------------- context summarization

export function summarize_messages(cfg, messages) {
	// messages: internal text messages to compress (user/assistant kind=text)
	let sys = '你是 OpenWrt 配置调优助手。请把以下对话压缩为不超过 150 字的中文摘要，必须保留：' +
		'讨论过的配置项与数值、已执行的命令与结果、已确定的方案、待办事项、用户偏好与约束。' +
		'只输出摘要文本本身，不要输出任何其他内容。';

	let internal = [];
	for (let m of messages)
		if (m.role == 'user' || m.role == 'assistant')
			push(internal, { role: m.role, kind: 'text', content: m.content || '' });

	// summarization is a plain completion (no tools); instruction goes to the system field
	let resp = call_ai(cfg, internal, [], sys);
	if (resp.error)
		return { ok: false, error: resp.error };

	return { ok: true, summary: (resp.text || '').trim() };
}
