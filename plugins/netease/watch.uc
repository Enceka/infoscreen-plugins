// 网易云的"被打断"守护：通话、蓝牙断开，两种情况都暂停播放。
//
// 原本是 watch.sh（sh 脚本）。应用商店不收 .sh，翻译到这里。
// 为什么必须独立进程而不是后端在 status 里顺手判断：页面隐藏时 WebKit 会节流
// 定时器，前端不再轮询就永远发现不了来电。这里自己盯。
//
// 只看 Call 的 State 属性，不走 mmcli —— mmcli 每次要 0.5 秒以上，1 秒一轮扛不住。
// State: 3 = ringing-in（来电响铃）, 4 = active（接通）。
//
// 暂停来源分两类：
//   call  —— 通话结束会自动恢复（接着刚才的位置放）
//   bt    —— 蓝牙断开导致的暂停**不自动恢复**：重连后突然出声比不响更吓人
// 用户自己按的暂停不会被动恢复，靠 callpause.flag 记住是谁暂停的。

'use strict';

const fs = require('fs');

const DB = 'dbus-send --system --print-reply --dest=org.freedesktop.ModemManager1';
const MODEM = '/org/freedesktop/ModemManager1/Modem/0';
const STATE = '/tmp/netease-state.txt';
const FLAG = '/tmp/netease-callpause.flag';
const API = 'http://127.0.0.1:8088/api/plugins/netease';
const LOG = '/tmp/netease-watch.log';

function sh(cmd) {
	let f = fs.popen(cmd, 'r');
	if (!f) return '';
	let s = f.read('all');
	f.close();
	return s ?? '';
}

function log(msg) {
	let d = trim(sh(`date '+%m-%d %H:%M:%S'`) ?? '');
	sh(`printf '%s %s\\n' '${d}' '${msg}' >> '${LOG}' 2>/dev/null`);
}

// 正在播放 = state 里有 start 且没被暂停
function playing() {
	let s = '';
	try { s = fs.readfile(STATE) ?? ''; } catch (e) { return false; }
	let start = '', paused = '0';
	for (let line in split(s, '\n')) {
		let l = trim(line);
		if (substr(l, 0, 6) == 'start=') start = trim(substr(l, 6));
		else if (substr(l, 0, 10) == 'paused_at=') paused = trim(substr(l, 10));
	}
	return length(start) > 0 && start != '0' && (length(paused) < 1 || paused == '0');
}

// 有来电响铃或通话进行中？
function inCall() {
	let out = sh(`${DB} ${MODEM} org.freedesktop.DBus.Properties.Get string:org.freedesktop.ModemManager1.Modem.Voice string:Calls 2>/dev/null`);
	let calls = trim(sh(`printf '%s' '${out}' | grep -oE '/org/freedesktop/ModemManager1/Call/[0-9]+' | head -4`) ?? '');
	if (length(calls) < 1) return false;
	for (let c in split(calls, '\n')) {
		let path = trim(c);
		if (length(path) < 1) continue;
		let st = trim(sh(`${DB} '${path}' org.freedesktop.DBus.Properties.Get string:org.freedesktop.ModemManager1.Call string:State 2>/dev/null | grep -oE 'int32 [0-9]+' | cut -d' ' -f2`) ?? '');
		if (st == '3' || st == '4') return true;     // ringing-in / active
	}
	return false;
}

// 有没有蓝牙音频出口（A2DP 连着时 pactl 里才有 bluez sink）
function btPresent() {
	let n = trim(sh(`pactl list short sinks 2>/dev/null | grep -c bluez`) ?? '0');
	return length(n) > 0 && n != '0';
}

function flagOn() {
	return length(trim(sh(`[ -f '${FLAG}' ] && echo yes`) ?? '')) > 0;
}

// ---- 主循环 ----
let btWas = false, btMiss = 0;

while (true) {
	// 蓝牙断开：只在"刚才还在、现在连着两次看不到"时才算，躲开 pactl 抖动
	if (btPresent()) {
		btWas = true;
		btMiss = 0;
	} else if (btWas) {
		btMiss++;
		if (btMiss >= 2) {
			btWas = false;
			btMiss = 0;
			if (playing()) {
				sh(`curl -s -m 3 '${API}/pause' >/dev/null 2>&1`);
				log('bt gone -> paused');
			}
		}
	}

	// 通话：没在放歌也没挂起标志时慢一点轮询，省掉多余的 dbus 往返
	if (playing() || flagOn()) {
		if (inCall()) {
			if (!flagOn() && playing()) {
				sh(`curl -s -m 3 '${API}/pause' >/dev/null 2>&1`);
				sh(`: > '${FLAG}'`);
				log('call start -> paused');
			}
			sleep(1);
			continue;
		}
		if (flagOn()) {
			sh(`rm -f '${FLAG}'`);
			sh(`curl -s -m 3 '${API}/resume' >/dev/null 2>&1`);
			log('call end -> resumed');
		}
		sleep(1);
	} else {
		sleep(3);
	}
}
