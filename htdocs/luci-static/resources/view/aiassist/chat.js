'use strict';
'require view';
'require rpc';
'require ui';

const api = {
	info:        rpc.declare({ object: 'aiassist', method: 'getInfo', expect: {} }),
	listSessions: rpc.declare({ object: 'aiassist', method: 'listSessions', expect: {} }),
	createSession: rpc.declare({ object: 'aiassist', method: 'createSession', params: [ 'title' ], expect: {} }),
	deleteSession: rpc.declare({ object: 'aiassist', method: 'deleteSession', params: [ 'sid' ], expect: {} }),
	getSession:  rpc.declare({ object: 'aiassist', method: 'getSession', params: [ 'sid' ], expect: {} }),
	sendMessage: rpc.declare({ object: 'aiassist', method: 'sendMessage', params: [ 'sid', 'content' ], expect: {} }),
	pollJob:     rpc.declare({ object: 'aiassist', method: 'pollJob', params: [ 'jobid' ], expect: {} }),
	stopJob:     rpc.declare({ object: 'aiassist', method: 'stopJob', params: [ 'jobid' ], expect: {} }),
	compressContext: rpc.declare({ object: 'aiassist', method: 'compressContext', params: [ 'sid' ], expect: {} }),
	listSnapshots: rpc.declare({ object: 'aiassist', method: 'listSnapshots', params: [ 'sid' ], expect: {} }),
	snapshotDiff: rpc.declare({ object: 'aiassist', method: 'snapshotDiff', params: [ 'sid', 'turn' ], expect: {} }),
	getSnapshot: rpc.declare({ object: 'aiassist', method: 'getSnapshot', params: [ 'sid', 'turn' ], expect: {} }),
	rollback:    rpc.declare({ object: 'aiassist', method: 'rollback', params: [ 'sid', 'turn', 'confirm' ], expect: {} }),
	createSnapshot: rpc.declare({ object: 'aiassist', method: 'createSnapshot', params: [ 'sid', 'comment' ], expect: {} }),
	backupMtd:   rpc.declare({ object: 'aiassist', method: 'backupMtd', params: [ 'device' ], expect: {} }),
	listMtd:     rpc.declare({ object: 'aiassist', method: 'listMtd', expect: {} })
};

const PERM_TEXT = {
	readonly: '只读：AI 仅可查看配置，不可执行命令',
	limited:  '受限：AI 可执行白名单命令（uci/服务重启/诊断）',
	full:     '全权负责：AI 拥有 root 权限，操作无需审批'
};

return view.extend({
	render: async function() {
		this.info = await api.info();
		this.session = null;
		this.jobid = null;
		this.pollTimer = null;
		this.sessions = [];

		if (!this.info.enabled) {
			return E('div', { class: 'cbi-section' }, [
				E('h2', {}, 'AI Assistant'),
				E('div', { class: 'cbi-section-descr' },
					'AI 助手未启用。请先在「设置」页面开启并配置 API（Provider / Base URL / Key / Model）与权限模式。'),
				E('div', { style: 'margin-top:10px' },
					E('a', { class: 'cbi-button cbi-button-action', href: L.url('admin/system/aiassist/settings') }, '前往设置'))
			]);
		}

		await this.loadSessions();

		this.msgList = E('div', { class: 'aias-msgs', style: 'flex:1;overflow-y:auto;padding:12px;background:#f4f4f4;border:1px solid #ccc;border-radius:4px;min-height:280px;max-height:55vh' });
		this.input = E('textarea', {
			class: 'cbi-input-textarea',
			style: 'width:100%;height:60px;resize:vertical;box-sizing:border-box',
			placeholder: '向 AI 提问：查看/调优 OpenWrt 配置，例如「分析 network 配置并优化 DNS 延迟」…',
			keydown: (ev) => { if (ev.key == 'Enter' && !ev.shiftKey) { ev.preventDefault(); this.doSend(); } }
		});
		this.btnSend = E('button', { class: 'cbi-button cbi-button-action', click: () => this.doSend() }, '发送');
		this.btnStop = E('button', { class: 'cbi-button cbi-button-negative', style: 'display:none', click: () => this.doStop() }, '停止');
		this.tokenBadge = E('span', { style: 'color:#666;font-size:12px' }, '');

		this.sessList = E('div', { class: 'aias-sessions', style: 'width:220px;margin-right:12px;overflow-y:auto;border:1px solid #ccc;border-radius:4px;background:#fff;padding:6px' });
		this.sessTitle = E('h2', { style: 'margin:0 0 8px;font-size:16px' }, '会话');

		this.statusBar = E('div', { class: 'aias-status', style: 'display:flex;gap:8px;align-items:center;margin-bottom:10px;flex-wrap:wrap' });

		return E('div', { class: 'cbi-section', style: 'display:flex;flex-direction:column;height:100%' }, [
			E('h2', {}, 'AI Assistant'),
			this.statusBar,
			E('div', { style: 'display:flex;flex:1;min-height:0' }, [
				E('div', {}, [
					this.sessTitle,
					E('div', { style: 'margin-bottom:6px' },
						E('button', { class: 'cbi-button cbi-button-action', click: () => this.newSession() }, '＋ 新建会话')),
					this.sessList
				]),
				E('div', { style: 'flex:1;display:flex;flex-direction:column;min-width:0' }, [
					this.msgList,
					E('div', { style: 'display:flex;gap:6px;margin-top:8px' }, [
						this.input,
						this.btnSend,
						this.btnStop
					])
				])
			])
		]);
	},

	loadSessions: async function() {
		let r = await api.listSessions();
		this.sessions = (r && r.sessions) || [];
		this.renderSessions();
	},

	renderSessions: async function() {
		this.sessList.innerHTML = '';
		for (let s of this.sessions) {
			let item = E('div', {
				class: 'aias-sess-item',
				style: 'padding:6px 8px;cursor:pointer;border-radius:3px;margin-bottom:2px;' + (this.session && this.session.id == s.id ? 'background:#dbeafe;font-weight:600' : ''),
				click: () => this.openSession(s.id)
			}, [
				E('div', { style: 'font-size:13px;word-break:break-all' }, s.title),
				E('div', { style: 'font-size:11px;color:#888' }, '轮次 ' + (s.turn || 0) + ' · 消息 ' + (s.count || 0))
			]);
			this.sessList.appendChild(item);
		}
		if (!this.sessions.length)
			this.sessList.appendChild(E('div', { style: 'color:#888;font-size:12px;padding:6px' }, '（暂无会话，点击「新建会话」开始）'));
	},

	newSession: async function() {
		let title = prompt('新会话标题（可留空自动生成）');
		if (title === null)
			return;
		let r = await api.createSession(title || '');
		if (r && r.ok)
			await this.openSession(r.id);
	},

	openSession: async function(sid) {
		this.stopPolling();
		let r = await api.getSession(sid);
		if (!r || !r.ok) {
			ui.addNotification({ title: 'AI Assistant', text: r.reason || '无法打开会话', type: 'error' });
			return;
		}
		this.session = r.session;
		this.renderStatus();
		this.renderMessages();
		await this.loadSessions();
	},

	renderStatus: async function() {
		this.statusBar.innerHTML = '';
		let perm = this.info.permission;
		this.statusBar.appendChild(E('span', { class: 'cbi-button cbi-button-' + (perm == 'full' ? 'negative' : (perm == 'limited' ? 'action' : 'neutral')), style: 'cursor:default;padding:2px 8px' },
			'权限: ' + PERM_TEXT[perm] || perm));
		this.statusBar.appendChild(E('span', { style: 'color:#666;font-size:12px' }, '模型: ' + this.info.provider + ' / ' + this.info.model));

		let snaps = await api.listSnapshots(this.session.id);
		this.snapshots = (snaps && snaps.snapshots) || [];
		this.tokenBadge.textContent = '~' + (this.session.estimated_tokens || 0) + ' tokens';
		this.statusBar.appendChild(this.tokenBadge);

		this.statusBar.appendChild(E('button', { class: 'cbi-button', click: () => this.doSnapshot() }, '备份配置'));
		this.statusBar.appendChild(E('button', { class: 'cbi-button', click: () => this.doCompress() }, '压缩上下文'));
		this.statusBar.appendChild(E('button', { class: 'cbi-button', click: () => this.doRollbackPanel() }, '回滚 (' + this.snapshots.length + ')'));
		if (perm == 'full')
			this.statusBar.appendChild(E('button', { class: 'cbi-button cbi-button-negative', click: () => this.doMtdBackup() }, 'MTD 智能备份'));
	},

	renderMessages: function() {
		this.msgList.innerHTML = '';
		for (let m of this.session.messages)
			this.msgList.appendChild(this.renderMessage(m));
		this.msgList.scrollTop = this.msgList.scrollHeight;
	},

	renderMessage: function(m) {
		if (m.kind == 'summary') {
			return E('div', { style: 'margin:6px 0;padding:4px 8px;background:#f0f0ff;border-left:3px solid #8888cc;color:#555;font-size:12px' },
				'[历史摘要] ' + (m.content || ''));
		}

		if (m.kind == 'tool') {
			if (m.role == 'assistant') {
				let tcs = (m.tool_calls || []);
				let label = '🔧 ' + tcs.map(t => t.name + '(' + JSON.stringify(t.args || {}) + ')').join(', ');
				return E('details', { style: 'margin:4px 0' }, [
					E('summary', { style: 'cursor:pointer;font-size:12px;color:#444;background:#eee;border-radius:3px;padding:2px 6px' }, label),
					E('div', { style: 'font-size:11px;color:#666;padding:2px 6px' }, 'AI 请求执行工具')
				]);
			}
			// tool result (user role)
			return E('details', { style: 'margin:4px 0' }, [
				E('summary', { style: 'cursor:pointer;font-size:12px;color:#444;background:#e8e8e8;border-radius:3px;padding:2px 6px' }, '📄 工具结果'),
				E('pre', { style: 'white-space:pre-wrap;word-break:break-all;font-size:11px;color:#333;background:#fafafa;padding:6px;max-height:200px;overflow:auto;margin:2px 0' }, m.content || '')
			]);
		}

		let isUser = (m.role == 'user');
		return E('div', {
			style: 'display:flex;justify-content:' + (isUser ? 'flex-end' : 'flex-start') + ';margin:6px 0'
		}, E('div', {
			style: 'max-width:85%;padding:8px 10px;border-radius:8px;white-space:pre-wrap;word-break:break-word;font-size:13px;' +
				(isUser ? 'background:#2563eb;color:#fff' : 'background:#fff;border:1px solid #ddd;color:#222')
		}, m.content || ''));
	},

	doSend: async function() {
		let text = this.input.value.trim();
		if (!text || !this.session)
			return;
		if (this.jobid) {
			ui.addNotification({ title: 'AI Assistant', text: '上一条请求仍在处理中', type: 'error' });
			return;
		}
		this.input.value = '';
		this.btnSend.style.display = 'none';
		this.btnStop.style.display = '';

		let r = await api.sendMessage(this.session.id, text);
		if (!r || r.error) {
			this.btnSend.style.display = '';
			this.btnStop.style.display = 'none';
			ui.addNotification({ title: 'AI Assistant', text: (r && r.error) || '发送失败', type: 'error' });
			return;
		}
		this.jobid = r.job;
		this.startPolling();
	},

	startPolling: function() {
		this.msgList.appendChild(E('div', { class: 'aias-wait', style: 'color:#666;font-size:13px;padding:6px' }, '🤔 AI 思考中…'));
		this.pollTimer = setTimeout(() => this.pollOnce(), 2000);
	},

	pollOnce: async function() {
		if (!this.jobid)
			return;
		let j = await api.pollJob(this.jobid);
		if (!j)
			return this.stopPolling();

		if (j.status == 'running' || j.status == 'queued') {
			this.pollTimer = setTimeout(() => this.pollOnce(), 2000);
			return;
		}

		this.stopPolling();
		if (j.status == 'error')
			ui.addNotification({ title: 'AI Assistant', text: j.error || '任务出错', type: 'error' });
		// incremental refresh: only append newly arrived messages, avoid full re-render
		await this.refresh();
	},

	// fetch the session and append only messages that are new (cheap on 128MB devices)
	refresh: async function() {
		if (!this.session)
			return;
		let r = await api.getSession(this.session.id);
		if (!r || !r.ok)
			return;
		let prevCount = this.session.messages.length;
		this.session = r.session;
		this.tokenBadge.textContent = '~' + (this.session.estimated_tokens || 0) + ' tokens';
		let wait = this.msgList.querySelector('.aias-wait');
		if (wait)
			wait.remove();
		for (let i = prevCount; i < this.session.messages.length; i++)
			this.msgList.appendChild(this.renderMessage(this.session.messages[i]));
		this.msgList.scrollTop = this.msgList.scrollHeight;
		await this.renderSessions();
	},

	stopPolling: function() {
		if (this.pollTimer) {
			clearTimeout(this.pollTimer);
			this.pollTimer = null;
		}
		this.jobid = null;
		this.btnSend.style.display = '';
		this.btnStop.style.display = 'none';
	},

	doStop: async function() {
		if (this.jobid)
			await api.stopJob(this.jobid);
	},

	doCompress: async function() {
		if (!this.session)
			return;
		let r = await api.compressContext(this.session.id);
		if (!r || r.error) {
			ui.addNotification({ title: 'AI Assistant', text: (r && r.error) || '压缩失败', type: 'error' });
			return;
		}
		this.jobid = r.job;
		this.btnSend.style.display = 'none';
		this.startPolling();
		ui.addNotification({ title: 'AI Assistant', text: '正在压缩上下文…', type: 'info' });
	},

	doSnapshot: async function() {
		if (!this.session)
			return;
		let r = await api.createSnapshot(this.session.id, 'manual');
		if (r && r.ok)
			ui.addNotification({ title: 'AI Assistant', text: r.text, type: 'info' });
		else
			ui.addNotification({ title: 'AI Assistant', text: (r && r.text) || '备份失败', type: 'error' });
		await this.renderStatus();
	},

	doRollbackPanel: async function() {
		if (!this.session)
			return;
		let snaps = await api.listSnapshots(this.session.id);
		let list = (snaps && snaps.snapshots) || [];
		if (!list.length) {
			ui.addNotification({ title: 'AI Assistant', text: '当前会话还没有可回滚的快照', type: 'info' });
			return;
		}

		let fmt = (ts) => {
			let d = new Date((ts || 0) * 1000);
			return ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2) + ':' + ('0' + d.getSeconds()).slice(-2);
		};

		let rows = list.map(s => {
			let actions = (s.actions || []).map(a => E('div', { style: 'font-size:11px;color:#555;word-break:break-all' }, '· ' + a));

			return E('li', { style: 'margin:8px 0;padding:6px;border:1px solid #eee;border-radius:4px' }, [
				E('div', { style: 'display:flex;gap:6px;align-items:center;flex-wrap:wrap' }, [
					E('span', { style: 'font-weight:600' }, '第 ' + s.turn + ' 轮'),
					E('span', { style: 'font-size:11px;color:#888' }, fmt(s.ts) + ' · ' + (s.label || 'auto')),
					E('button', {
						class: 'cbi-button',
						style: 'margin-left:auto',
						click: async () => { await this.showSnapshotDiff(s.turn); }
					}, '对比'),
					E('button', {
						class: 'cbi-button cbi-button-negative',
						click: async () => { await this.doRollback(s.turn); }
					}, '回退')
				]),
				actions.length ? E('div', { style: 'margin-top:4px' }, actions)
				               : E('div', { style: 'font-size:11px;color:#aaa;margin-top:4px' }, '（本轮为手动备份，无操作记录）')
			]);
		});

		ui.showModal('回滚到之前的配置状态', [
			E('div', { class: 'cbi-section-descr' },
				'每个快照记录了一次写操作前的 /etc/config 状态。回退 = 恢复该轮之前的配置快照并截断后续对话。' +
				'注意：无法覆盖进程/内核运行时状态，回滚后建议让 AI 检查服务状态。'),
			E('ol', { style: 'max-height:320px;overflow-y:auto;padding-left:16px;list-style:none;margin:0' }, rows)
		]);
	},

	showSnapshotDiff: async function(turn) {
		let r = await api.snapshotDiff(this.session.id, turn);
		let text = (r && r.ok) ? (r.text || '（无差异）') : ((r && r.text) || '获取差异失败');
		ui.showModal('第 ' + turn + ' 轮快照 vs 当前配置', [
			E('div', { class: 'cbi-section-descr' }, '「+」= 当前新增/改动；「-」= 快照中存在、当前已移除。'),
			E('pre', {
				style: 'white-space:pre-wrap;word-break:break-all;font-size:11px;background:#fafafa;border:1px solid #ddd;' +
					'padding:8px;max-height:340px;overflow:auto'
			}, text)
		]);
	},

	doRollback: async function(turn) {
		if (!confirm('确定回滚到第 ' + turn + ' 轮对话之前的状态？\n将恢复该轮写操作前的 /etc/config 快照，并删除之后的对话记录。\n此操作不可撤销（回滚前的状态会自动备份到 /etc/aiassist/undo/）。'))
			return;
		ui.hideModal();
		let r = await api.rollback(this.session.id, turn, 'yes');
		if (r && r.ok) {
			ui.addNotification({ title: 'AI Assistant', text: r.text, type: 'info' });
			await this.openSession(this.session.id);
		}
		else
			ui.addNotification({ title: 'AI Assistant', text: (r && r.text) || '回滚失败', type: 'error' });
	},

	doMtdBackup: async function() {
		if (!confirm('MTD 智能备份将按设备实际分区表执行：\n' +
			'· 自动备份小分区（bootloader/ubootenv/factory 等）+ 分区表 + sysupgrade 配置归档 + 软件清单 + md5 校验；\n' +
			'· 大分区（固件/rootfs/ubi 整盘镜像，可能上百 MB）默认跳过，避免写满 flash；如需完整镜像可在确认后再次执行完整模式；\n' +
			'· 空间不足时会自动中止并提示挂载 U 盘。\n\n' +
			'注意：MTD 镜像是物理分区快照，不包含 overlay 扩容成果；恢复后需按原布局重新扩容。继续？'))
			return;
		let r = await api.backupMtd('all');
		if (r && r.ok)
			ui.addNotification({ title: 'AI Assistant', text: r.text, type: 'info' });
		else
			ui.addNotification({ title: 'AI Assistant', text: (r && r.text) || 'MTD 备份失败', type: 'error' });
	}
});
