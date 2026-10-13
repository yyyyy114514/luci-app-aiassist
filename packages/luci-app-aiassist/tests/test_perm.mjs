// Permission logic simulation test (node) — mirrors check_exec from lib.uc
// Not the real ucode runtime, but verifies regexes and prefix matching logic.

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

const LIMITED_OPERATORS = /[;&|`]|\$\(|\n|\b(rm|reboot|poweroff|halt|mkfs|dd|sh|bash)\b/;

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

function check_exec(permission, command, cfg) {
	if (!command || !command.trim().length) return { ok: false, reason: 'empty' };
	if (command.length > 2048) return { ok: false, reason: 'too long' };
	if (permission == 'readonly') return { ok: false, reason: 'readonly' };
	for (let re of FATAL_PATTERNS)
		if (re.test(command)) return { ok: false, reason: 'fatal: ' + re };
	if (permission == 'full') return { ok: true };
	if (LIMITED_OPERATORS.test(command)) return { ok: false, reason: 'operators' };
	if (/\.\./.test(command)) return { ok: false, reason: 'dotdot' };
	let c = command.trim();
	for (let pre of cfg.exec_allow)
		if (c.startsWith(pre)) return { ok: true };
	return { ok: false, reason: 'not in allowlist' };
}

let pass = 0, fail = 0;
function t(desc, permission, cmd, expectAllow) {
	let r = check_exec(permission, cmd, { exec_allow: DEFAULT_ALLOW });
	let got = r.ok;
	let ok = got === expectAllow;
	if (ok) pass++; else { fail++; console.log('FAIL', desc, '| expect', expectAllow, '| got', got, '|', r.reason, '| cmd:', cmd); }
}

// readonly: everything denied
t('readonly blocks exec', 'readonly', 'uci show', false);

// limited: allow-listed safe ops
t('limited uci set allowed', 'limited', 'uci set network.lan.ipaddr=192.168.1.10', true);
t('limited uci commit allowed', 'limited', 'uci commit network', true);
t('limited init.d reload allowed', 'limited', '/etc/init.d/network reload', true);
t('limited view config allowed', 'limited', 'cat /etc/config/wireless', true);
t('limited diag allowed', 'limited', 'logread -l 50', true);
t('limited df allowed', 'limited', 'df -h', true);
t('limited sysctl allowed', 'limited', 'sysctl -w net.ipv4.ip_forward=1', true);

// limited: compound/injection blocked
t('limited blocks ;', 'limited', 'uci set network.lan.ipaddr=1.1.1.1; rm -rf /etc', false);
t('limited blocks &&', 'limited', 'uci commit network && reboot', false);
t('limited blocks pipe', 'limited', 'ip addr | grep inet', false);
t('limited blocks $()', 'limited', 'uci set x=$(reboot)', false);
t('limited blocks backtick', 'limited', 'uci set x=`id`', false);
t('limited blocks rm word', 'limited', 'rm /tmp/x', false);
t('limited blocks dotdot', 'limited', 'cat /etc/config/../shadow', false);
t('limited blocks dd', 'limited', 'dd if=/dev/mtd0 of=/tmp/x', false);

// full: recoverable ops allowed
t('full arbitrary cmd allowed', 'full', 'sysctl -w net.ipv4.tcp_rmem="4096 87380 6291456"', true);
t('full opkg install allowed', 'full', 'opkg update && opkg install tcpdump', true);
t('full wifi reload allowed', 'full', 'wifi reload', true);

// full: unrecoverable blocked
t('full blocks rm -rf /', 'full', 'rm -rf /', false);
t('full blocks rm -rf /etc', 'full', 'rm -rf /etc', false);
t('full blocks rm -rf /etc/config', 'full', 'rm -rf /etc/config', false);
t('full blocks rm -fr dir', 'full', 'rm -fr /overlay', false);
t('full blocks rm -r -f', 'full', 'rm -r -f /etc', false);
t('full blocks rm -rfv', 'full', 'rm -rfv /overlay/upper', false);
t('full blocks mtd erase', 'full', 'mtd erase firmware', false);
t('full blocks reboot', 'full', 'reboot', false);
t('full blocks poweroff', 'full', 'sync; poweroff', false);
t('full blocks dd to disk', 'full', 'dd if=/dev/zero of=/dev/mmcblk0', false);
t('full blocks mkfs', 'full', 'mkfs.ext4 /dev/sda1', false);
t('full blocks fork bomb', 'full', ':(){ :|:& };:', false);

// plain file rm allowed in full (without -f)
t('full rm single file allowed', 'full', 'rm /tmp/session.lock', true);
// rm -f is blocked in every mode by design (conservative)
t('full rm -f single file blocked (by design)', 'full', 'rm -f /tmp/x', false);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
