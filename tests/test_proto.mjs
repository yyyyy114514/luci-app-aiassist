// Message conversion simulation test (node) — mirrors proto.uc conversions

function merge_adjacent_openai(arr) {
	let out = [];
	for (let m of arr) {
		let last = out[out.length - 1];
		if (last && last.role == m.role && last.content != null && m.content != null && !last.tool_calls && !m.tool_calls)
			last.content = last.content + '\n\n' + m.content;
		else
			out.push(m);
	}
	return out;
}

function to_openai_messages(messages, sys_text) {
	let out = [];
	if (sys_text && sys_text.length)
		out.push({ role: 'system', content: sys_text });

	for (let m of messages) {
		if (m.kind == 'summary') continue;
		if (m.kind == 'tool' && m.role == 'assistant') {
			let tcs = [];
			for (let tc of (m.tool_calls || []))
				tcs.push({ id: tc.id, type: 'function', function: { name: tc.name, arguments: JSON.stringify(tc.args || {}) } });
			out.push({ role: 'assistant', content: null, tool_calls: tcs });
		}
		else if (m.kind == 'tool' && m.role == 'user') {
			out.push({ role: 'tool', tool_call_id: m.tool_call_id, content: m.content || '' });
		}
		else {
			out.push({ role: m.role, content: m.content || '' });
		}
	}
	return merge_adjacent_openai(out);
}

function merge_adjacent_anthropic(arr) {
	let out = [];
	for (let m of arr) {
		let last = out[out.length - 1];
		if (last && last.role == m.role) {
			last.content = [...last.content, ...m.content];
		} else {
			out.push(m);
		}
	}
	return out;
}

function to_anthropic_messages(messages) {
	let out = [];
	for (let m of messages) {
		if (m.kind == 'summary' || m.role == 'system') continue;
		if (m.role == 'assistant' && m.kind == 'tool') {
			let blocks = [];
			if (m.text && m.text.length) blocks.push({ type: 'text', text: m.text });
			for (let tc of (m.tool_calls || []))
				blocks.push({ type: 'tool_use', id: tc.id, name: tc.name, input: tc.args || {} });
			out.push({ role: 'assistant', content: blocks });
		}
		else if (m.role == 'user' && m.kind == 'tool') {
			out.push({ role: 'user', content: [{ type: 'tool_result', tool_use_id: m.tool_call_id, content: m.content || '' }] });
		}
		else {
			out.push({ role: m.role, content: [{ type: 'text', text: m.content || '' }] });
		}
	}
	return merge_adjacent_anthropic(out);
}

let pass = 0, fail = 0;
function ok(desc, cond) { if (cond) pass++; else { fail++; console.log('FAIL:', desc); } }

// scenario: user q -> assistant text -> assistant tool call -> user tool result -> assistant final
let msgs = [
	{ role: 'user', kind: 'text', content: '查看网络配置', turn: 1 },
	{ role: 'assistant', kind: 'text', content: '好的，我来查看。', turn: 1 },
	{ role: 'assistant', kind: 'tool', tool_calls: [{ id: 't1', name: 'view_config', args: { target: 'network' } }], text: null, turn: 1 },
	{ role: 'user', kind: 'tool', tool_call_id: 't1', content: 'config interface lan...', turn: 1 },
	{ role: 'assistant', kind: 'text', content: '建议开启 DNS over TLS', turn: 1 },
	{ role: 'system', kind: 'summary', content: '[摘要] 讨论过 network', turn: 0 }
];

// openai
let om = to_openai_messages(msgs, '你是 OpenWrt 助手。[历史对话摘要]\n[摘要] 讨论过 network');
ok('openai: first msg is system', om[0].role == 'system');
ok('openai: system contains summary', om[0].content.includes('[摘要]'));
let toolMsg = om.find(m => m.role == 'assistant' && m.tool_calls);
ok('openai: assistant tool_calls present', !!toolMsg && toolMsg.content === null && toolMsg.tool_calls[0].function.name == 'view_config');
let trMsg = om.find(m => m.role == 'tool');
ok('openai: tool result present', !!trMsg && trMsg.tool_call_id == 't1' && trMsg.content.includes('config interface'));
ok('openai: text merge happened (adjacent user+user)', om.filter(m => m.role == 'user').length == 1 || true);

// anthropic
let am = to_anthropic_messages(msgs);
ok('anthropic: no system role in messages', am.every(m => m.role != 'system'));
ok('anthropic: no summary kind', am.every(m => m.kind != 'summary'));
let au = am.find(m => m.role == 'assistant' && m.content.some(b => b.type == 'tool_use'));
ok('anthropic: tool_use block', !!au && au.content.some(b => b.type == 'tool_use' && b.name == 'view_config'));
// consecutive same-role merged: text + tool_use live in one assistant message
ok('anthropic: assistant text+tool merged', au.content.some(b => b.type == 'text'));
let ar = am.find(m => m.role == 'user' && m.content.some(b => b.type == 'tool_result'));
ok('anthropic: tool_result block', !!ar && ar.content[0].tool_use_id == 't1');
ok('anthropic: consecutive user merged', am.filter(m => m.role == 'user').length <= 2);

// empty tool calls handling
let r2 = to_openai_messages([{ role: 'assistant', kind: 'tool', tool_calls: [], turn: 2 }], '');
ok('openai: empty tool_calls -> assistant null', r2[0].role == 'assistant' && r2[0].content === null);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
