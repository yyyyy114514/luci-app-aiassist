'use strict';
'require view';
'require rpc';
'require ui';

const api = {
	getSettings:  rpc.declare({ object: 'aiassist', method: 'getSettings', expect: {} }),
	updateSettings: rpc.declare({
		object: 'aiassist', method: 'updateSettings',
		params: [ 'enabled', 'provider', 'base_url', 'model', 'permission', 'context_threshold',
			'max_turns', 'timeout', 'max_output', 'temperature', 'proxy', 'auto_snapshot', 'mtd_backup',
			'system_prompt', 'exec_allowlist', 'view_paths', 'acknowledge_full',
			'max_tokens', 'max_tool_rounds', 'exec_timeout', 'max_session_tokens', 'api_retries' ],
		expect: {}
	}),
	setApiKey:    rpc.declare({ object: 'aiassist', method: 'setApiKey', params: [ 'key' ], expect: {} }),
	clearApiKey:  rpc.declare({ object: 'aiassist', method: 'clearApiKey', expect: {} }),
	testConnection: rpc.declare({ object: 'aiassist', method: 'testConnection', expect: {} })
};

const PERMS = [
	{ id: 'readonly', title: '只读（readonly）', desc: 'AI 只能查看配置与系统状态、给出调优建议，不能执行任何命令。最安全。' },
	{ id: 'limited', title: '受限（limited）', desc: 'AI 可执行白名单内的命令：uci 读写与 commit、/etc/init.d/ 服务 reload/restart、常用诊断命令。危险命令被拦截；每次写操作前自动创建配置快照，可随时回滚。' },
	{ id: 'full', title: '全权负责（full）', desc: 'AI 拥有 root 权限，可执行任意命令且无需逐条审批。写操作前自动快照 + 全程审计。仅拦截不可恢复的毁灭性命令（如 rm -rf /、刷写 mtd）。开启需确认风险。' }
];

return view.extend({
	render: async function() {
		this.cfg = await api.getSettings();

		let rows = [];

		// enabled
		this.f_enabled = E('input', { type: 'checkbox', checked: !!this.cfg.enabled });
		rows.push(this.row('启用', '总开关。关闭后 AI 不可发起对话。', this.f_enabled));

		// provider
		this.f_provider = E('select', { class: 'cbi-input-select' }, [
			E('option', { value: 'openai', selected: this.cfg.provider == 'openai' ? true : undefined }, 'OpenAI（兼容协议）'),
			E('option', { value: 'anthropic', selected: this.cfg.provider == 'anthropic' ? true : undefined }, 'Anthropic（Claude 协议）')
		]);
		rows.push(this.row('协议 Provider', 'openai = OpenAI 兼容接口；anthropic = Claude Messages 接口。第三方中转站如兼容其中之一即可使用。', this.f_provider));

		// base url
		this.f_base_url = E('input', { class: 'cbi-input-text', style: 'width:100%', value: this.cfg.base_url || '' });
		rows.push(this.row('Base URL', '例如 https://api.openai.com/v1 或 https://api.anthropic.com。若已包含 /chat/completions 或 /v1/messages 结尾则直接使用。', this.f_base_url));

		// model
		this.f_model = E('input', { class: 'cbi-input-text', style: 'width:100%', value: this.cfg.model || '' });
		rows.push(this.row('模型 ID (model)', '例如 gpt-4o-mini、claude-3-5-haiku-latest 等。建议选择低延迟小模型以适配 128MB 内存设备。', this.f_model));

		// api key
		this.f_key = E('input', { type: 'password', class: 'cbi-input-text', style: 'width:70%',
			placeholder: this.cfg.api_key.configured ? '已配置（' + this.cfg.api_key.hint + '），输入新 Key 可覆盖' : 'sk-…' });
		rows.push(this.row('API Key',
			'密钥保存在 /etc/aiassist/api_key（权限 600），不写入 UCI 配置。',
			E('div', { style: 'display:flex;gap:6px;width:100%' }, [
				this.f_key,
				E('button', { class: 'cbi-button cbi-button-action', click: () => this.saveKey() }, '保存 Key'),
				E('button', { class: 'cbi-button', click: () => this.testConn() }, '测试连接'),
				E('button', { class: 'cbi-button cbi-button-negative', click: () => this.clearKey() }, '清空')
			])));

		// permission radios
		let radios = PERMS.map(p => {
			let radio = E('input', { type: 'radio', name: 'perm', value: p.id,
				checked: this.cfg.permission == p.id ? true : undefined,
				change: () => this.permChanged(p.id) });
			return E('label', { style: 'display:block;margin:6px 0;padding:8px;border:1px solid #ddd;border-radius:4px;cursor:pointer' }, [
				radio,
				E('span', { style: 'font-weight:600;margin-left:4px' }, p.title),
				E('div', { style: 'font-size:12px;color:#666;margin:4px 0 0 20px' }, p.desc)
			]);
		});
		this.permRadios = radios;
		rows.push(this.row('权限模式', '决定 AI 能做什么。full（全权负责）模式下所有操作无需审批，务必谨慎。', E('div', {}, radios)));

		// full risk acknowledge
		this.f_ack = E('input', { type: 'checkbox', checked: !!this.cfg.full_risk_acknowledged });
		this.ackRow = this.row('我已知晓 full 权限风险',
			'确认后允许切换到「全权负责」模式：AI 将获得 root 权限并可执行任意命令、无需逐条审批。',
			this.f_ack);
		this.warnBox = E('div', {
			class: 'cbi-section',
			style: 'display:none;background:#fde8e8;border:1px solid #ecc;padding:8px;color:#a00;margin-top:6px'
		}, '⚠️ 高风险提示：full（全权负责）模式赋予 AI root 权限且所有操作无需审批。' +
			'AI 可能执行任何命令（含安装软件、修改固件相关配置）。仅建议在可控测试设备上使用，并保持「自动快照」开启。');
		this.permChanged(this.cfg.permission);

		// numeric / advanced
		this.f_threshold = E('input', { type: 'number', min: 500, max: 50000, class: 'cbi-input-text', value: this.cfg.context_threshold });
		rows.push(this.row('上下文压缩阈值 (tokens)', '对话估算 token 超过该值后自动压缩早期内容（先让 AI 生成摘要，失败则截断）。', this.f_threshold));

		this.f_max_turns = E('input', { type: 'number', min: 2, max: 200, class: 'cbi-input-text', value: this.cfg.max_turns });
		rows.push(this.row('保留轮数上限', '上下文压缩后保留的最大对话轮数（每轮含一问一答）。', this.f_max_turns));

		this.f_timeout = E('input', { type: 'number', min: 10, max: 300, class: 'cbi-input-text', value: this.cfg.timeout });
		rows.push(this.row('API 超时 (秒)', '单次 AI 请求的最大等待时间。网络差时调大。', this.f_timeout));

		this.f_max_output = E('input', { type: 'number', min: 512, max: 32768, class: 'cbi-input-text', value: this.cfg.max_output });
		rows.push(this.row('工具输出截断 (字节)', '命令输出 / 配置查看结果超过该大小会被截断，防止请求体过大。', this.f_max_output));

		this.f_max_tokens = E('input', { type: 'number', min: 128, max: 32768, class: 'cbi-input-text', value: this.cfg.max_tokens });
		rows.push(this.row('AI 单次回复上限 (tokens)', '限制 AI 单次生成的最大 token 数。调优回答通常不需要大篇幅，128MB 设备建议 1024~2048。', this.f_max_tokens));

		this.f_max_tool_rounds = E('input', { type: 'number', min: 1, max: 20, class: 'cbi-input-text', value: this.cfg.max_tool_rounds });
		rows.push(this.row('工具调用轮数上限', 'AI 每次回复最多连续调用工具的次数。过低会打断流程，过高会放大成本/延迟。', this.f_max_tool_rounds));

		this.f_exec_timeout = E('input', { type: 'number', min: 5, max: 300, class: 'cbi-input-text', value: this.cfg.exec_timeout });
		rows.push(this.row('命令执行超时 (秒)', 'AI 发起的 shell 命令最长运行时间，超时强制终止，防止卡死。', this.f_exec_timeout));

		this.f_max_session_tokens = E('input', { type: 'number', min: 2000, max: 200000, class: 'cbi-input-text', value: this.cfg.max_session_tokens });
		rows.push(this.row('会话上下文硬上限 (tokens)', '超过该值将拒绝继续对话并提示压缩/新建会话。防止无限增长拖垮内存与费用。', this.f_max_session_tokens));

		this.f_api_retries = E('input', { type: 'number', min: 0, max: 5, class: 'cbi-input-text', value: this.cfg.api_retries });
		rows.push(this.row('API 失败重试次数', '网络错误/超时自动重试的次数（4xx 类错误不重试），带退避间隔。', this.f_api_retries));

		this.f_temperature = E('input', { type: 'number', step: 0.1, min: 0, max: 1.5, class: 'cbi-input-text', value: this.cfg.temperature });
		rows.push(this.row('Temperature', '生成随机性。调优场景建议 0~0.3。', this.f_temperature));

		this.f_proxy = E('input', { class: 'cbi-input-text', style: 'width:100%', value: this.cfg.proxy || '', placeholder: '可选，如 http://127.0.0.1:7890' });
		rows.push(this.row('HTTP 代理', 'AI API 请求使用的代理（如路由器本身是代理服务器，或需经过局域网代理出口）。留空直连。', this.f_proxy));

		this.f_auto_snapshot = E('input', { type: 'checkbox', checked: !!this.cfg.auto_snapshot });
		rows.push(this.row('写操作前自动快照', '每次执行写命令前自动备份 /etc/config 等关键文件，支持一键回滚到任意轮次。建议保持开启。', this.f_auto_snapshot));

		this.f_mtd = E('input', { type: 'checkbox', checked: !!this.cfg.mtd_backup });
		rows.push(this.row('允许 MTD 智能备份', '在聊天页启用「MTD 智能备份」：按实际 /proc/mtd 动态适配（小分区 dd + sysupgrade 配置归档 + 软件清单 + md5 校验），大分区显式指定才备份，空间不足自动中止。', this.f_mtd));

		this.f_sysprompt = E('textarea', { class: 'cbi-input-textarea', style: 'width:100%;height:70px', value: this.cfg.system_prompt || '' });
		rows.push(this.row('附加系统提示词', '追加到 AI 系统提示词末尾，可定制行为偏好。', this.f_sysprompt));

		this.f_allow = E('textarea', { class: 'cbi-input-textarea', style: 'width:100%;height:70px', value: this.cfg.exec_allowlist || '' });
		rows.push(this.row('受限模式命令白名单（追加）',
			'空格分隔的命令前缀，追加到默认白名单。用于支持第三方插件的操作，例如 /usr/bin/myservice、ubus call myplugin。' +
			'注意：受限模式仍禁止复合命令（; && | 等）与危险操作。', this.f_allow));

		this.f_view = E('textarea', { class: 'cbi-input-textarea', style: 'width:100%;height:70px', value: this.cfg.view_paths || '' });
		rows.push(this.row('允许查看的额外路径（追加）',
			'空格分隔的绝对路径/目录，AI 可通过 view_config 读取这些文件。用于支持第三方插件配置的查看，如 /tmp/myapp.conf。', this.f_view));

		let btn = E('button', { class: 'cbi-button cbi-button-action', click: () => this.save() }, '保存设置');

		return E('div', { class: 'cbi-section' }, [
			E('h2', {}, 'AI Assistant 设置'),
			E('div', { class: 'cbi-section-descr' },
				'配置 AI 服务商、权限模式与回滚选项。AI 由你自主配置，密钥仅保存在本机。'),
			E('div', { style: 'max-width:760px' }, rows),
			this.warnBox,
			E('div', { style: 'margin-top:14px' }, btn)
		]);
	},

	row: function(label, desc, control) {
		return E('div', { style: 'display:flex;margin:10px 0;gap:10px;align-items:flex-start' }, [
			E('div', { style: 'width:200px;flex-shrink:0' }, [
				E('div', { style: 'font-weight:600;font-size:13px' }, label),
				E('div', { style: 'font-size:11px;color:#888;margin-top:2px' }, desc)
			]),
			E('div', { style: 'flex:1' }, control)
		]);
	},

	permChanged: function(id) {
		let isFull = (id == 'full');
		this.warnBox.style.display = isFull ? 'block' : 'none';
		if (this.ackRow)
			this.ackRow.style.display = isFull ? 'flex' : 'none';
	},

	collect: function() {
		let perm = '';
		for (let r of this.permRadios)
			if (r.querySelector('input').checked)
				perm = r.querySelector('input').value;

		return {
			enabled: this.f_enabled.checked,
			provider: this.f_provider.value,
			base_url: this.f_base_url.value.trim(),
			model: this.f_model.value.trim(),
			permission: perm,
			context_threshold: parseInt(this.f_threshold.value) || 6000,
			max_turns: parseInt(this.f_max_turns.value) || 20,
			timeout: parseInt(this.f_timeout.value) || 60,
			max_output: parseInt(this.f_max_output.value) || 4096,
			temperature: parseFloat(this.f_temperature.value) || 0.3,
			proxy: this.f_proxy.value.trim(),
			auto_snapshot: this.f_auto_snapshot.checked,
			mtd_backup: this.f_mtd.checked,
			system_prompt: this.f_sysprompt.value,
			exec_allowlist: this.f_allow.value,
			view_paths: this.f_view.value,
			acknowledge_full: this.f_ack.checked,
			max_tokens: parseInt(this.f_max_tokens.value) || 2048,
			max_tool_rounds: parseInt(this.f_max_tool_rounds.value) || 6,
			exec_timeout: parseInt(this.f_exec_timeout.value) || 30,
			max_session_tokens: parseInt(this.f_max_session_tokens.value) || 20000,
			api_retries: parseInt(this.f_api_retries.value) || 2
		};
	},

	save: async function() {
		let d = this.collect();
		if (d.permission == 'full' && !d.acknowledge_full && !this.cfg.full_risk_acknowledged) {
			ui.addNotification({ title: 'AI Assistant', text: '切换到 full（全权负责）必须先勾选「我已知晓 full 权限风险」', type: 'error' });
			return;
		}
		let r = await api.updateSettings(
			d.enabled, d.provider, d.base_url, d.model, d.permission, d.context_threshold,
			d.max_turns, d.timeout, d.max_output, d.temperature, d.proxy, d.auto_snapshot, d.mtd_backup,
			d.system_prompt, d.exec_allowlist, d.view_paths, d.acknowledge_full,
			d.max_tokens, d.max_tool_rounds, d.exec_timeout, d.max_session_tokens, d.api_retries
		);
		if (r && r.ok)
			ui.addNotification({ title: 'AI Assistant', text: '设置已保存', type: 'info' });
		else
			ui.addNotification({ title: 'AI Assistant', text: (r && r.error) || '保存失败', type: 'error' });
	},

	saveKey: async function() {
		let k = this.f_key.value.trim();
		if (!k) {
			ui.addNotification({ title: 'AI Assistant', text: '请输入 API Key', type: 'error' });
			return;
		}
		let r = await api.setApiKey(k);
		if (r && r.ok) {
			this.f_key.value = '';
			ui.addNotification({ title: 'AI Assistant', text: 'API Key 已保存', type: 'info' });
		}
		else
			ui.addNotification({ title: 'AI Assistant', text: (r && r.error) || '保存失败', type: 'error' });
	},

	clearKey: async function() {
		if (!confirm('确定清空已保存的 API Key？'))
			return;
		let r = await api.clearApiKey();
		if (r && r.ok)
			ui.addNotification({ title: 'AI Assistant', text: 'API Key 已清空', type: 'info' });
	},

	testConn: async function() {
		ui.addNotification({ title: 'AI Assistant', text: '正在测试连接…', type: 'info' });
		let r = await api.testConnection();
		if (r && r.ok)
			ui.addNotification({ title: 'AI Assistant', text: '连接成功：' + (r.reply || ''), type: 'info' });
		else
			ui.addNotification({ title: 'AI Assistant', text: (r && r.error) || '连接失败', type: 'error' });
	}
});
