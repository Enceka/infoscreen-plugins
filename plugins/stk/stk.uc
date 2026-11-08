// SIM Toolkit: the modem forwards each card's proactive commands as
// +SPUSATPROCMDIND URCs on its sbuf ring, which a tracefs kretprobe on
// sipc_core:sbuf_read copies out while the screen runs.  The menu cache and
// the sessions are shared with the screen's own STK app (e5-infoscreen-lvgl
// src/stk.c), so both frontends show the same menus.
'use strict';
import { readfile, writefile, open as fs_open, stat, lstat, mkdir, unlink, rename, lsdir } from 'fs';

const CACHE_DIR = '/etc/e5-infoscreen/stk';
const SESSION_DIR = '/tmp/e5-stk';
const TRACE_DIR = '/sys/kernel/debug/tracing';
const DEVICE_TREE = '/proc/device-tree/sipc-virt';
const SIM_SERVICE = '/etc/init.d/e5-infoscreen-sim';
const SIM_RC = '/etc/rc.d/S22e5-infoscreen-sim';
const SIM_SERVICE_TEXT = `#!/bin/sh /etc/rc.common
START=22
USE_PROCD=1

start_service() {
	# Gone with the plugin, and with the screen that runs the mapping itself.
	if [ ! -e /usr/share/e5-infoscreen/www/plugins/stk/manifest.json ] && [ ! -e /etc/e5-infoscreen/plugins/stk/manifest.json ] && [ ! -x /usr/libexec/e5-infoscreen/ui ]; then
		rm -f /etc/rc.d/S22e5-infoscreen-sim /etc/init.d/e5-infoscreen-sim
		return
	fi
	[ "$(uci -q get e5-plugin-stk.settings.enabled || uci -q get e5-infoscreen.main.stk)" = "0" ] && return
	# Both do what stk_map_channels (src/stk.c) does: put the modem in its
	# dual-SIM channel mapping once it answers, before the SIMs come up.
	procd_open_instance
	if [ -x /usr/libexec/e5-infoscreen/ui ]; then
		procd_set_param command /usr/libexec/e5-infoscreen/ui --map-sim-channels
	else
		procd_set_param command python3 -c '
import os, time, select, termios

def command_ok(fd, command, timeout_ms):
    if os.write(fd, command) != len(command):
        return False
    reply = b""
    for waited in range(0, timeout_ms, 100):
        poller = select.poll()
        poller.register(fd, select.POLLIN)
        if not poller.poll(100):
            continue
        try:
            chunk = os.read(fd, 255)
        except OSError:
            chunk = b""
        if chunk:
            reply += chunk
            if b"OK\\r\\n" in reply:
                return True
            if b"ERROR" in reply:
                return False
    return False

for tries in range(600):
    try:
        fd = os.open("/dev/stty_nr5", os.O_RDWR | os.O_NONBLOCK | os.O_NOCTTY)
    except OSError:
        fd = -1
    if fd >= 0:
        try:
            t = termios.tcgetattr(fd)
            t[0] = 0
            t[1] = 0
            t[2] = termios.CS8
            t[3] = 0
            termios.tcsetattr(fd, termios.TCSANOW, t)
        except termios.error:
            pass
        ready = command_ok(fd, b"AT\\r", 1000)
        mapped = ready and command_ok(fd, b"AT+SMMSWAP=0\\r", 3000)
        os.close(fd)
        if mapped:
            os.makedirs("/tmp/e5-stk", 0o700, exist_ok=True)
            os.close(os.open("/tmp/e5-stk/mapped", os.O_WRONLY | os.O_CREAT, 0o600))
        if ready:
            os.write(2, ("dual-SIM channel mapping %s\\n" % ("set" if mapped else "refused")).encode())
            raise SystemExit(0 if mapped else 1)
    time.sleep(0.2)
os.write(2, "/dev/stty_nr5: no answer\\n")
raise SystemExit(1)
'
	fi
	procd_set_param stderr 1
	procd_close_instance
}
`;
const TE_PROFILE = '08E09731610D005C6B00001F40000000032B0000000408000000000000000000';
const ITEMS = 32;
const UI_TIMEOUT = 30000;
const TEXT_TIMEOUT = 60000;
const TEXT_CLEAR_TIMEOUT = 15000;
const LOAD_GIVE_UP = 20000;

const CMD_REFRESH = 0x01, CMD_MORE_TIME = 0x02, CMD_SET_UP_EVENT_LIST = 0x05,
      CMD_SET_UP_CALL = 0x10, CMD_SEND_SS = 0x11, CMD_SEND_USSD = 0x12,
      CMD_SEND_SMS = 0x13, CMD_SEND_DTMF = 0x14, CMD_LAUNCH_BROWSER = 0x15,
      CMD_PLAY_TONE = 0x20, CMD_DISPLAY_TEXT = 0x21, CMD_GET_INKEY = 0x22,
      CMD_GET_INPUT = 0x23, CMD_SELECT_ITEM = 0x24, CMD_SET_UP_MENU = 0x25,
      CMD_PROVIDE_LOCAL_INFO = 0x26, CMD_SET_UP_IDLE_TEXT = 0x28,
      CMD_LANGUAGE_NOTIFICATION = 0x35;

const TR_OK = 0x00, TR_END = 0x10, TR_BACK = 0x11, TR_NO_RESPONSE = 0x12, TR_UNABLE = 0x20;

const LIVE_VIEWS = ['select', 'text', 'input', 'yesno', 'call'];

const gsm7_basic = [
	0x40, 0xA3, 0x24, 0xA5, 0xE8, 0xE9, 0xF9, 0xEC, 0xF2, 0xC7, 0x0A, 0xD8, 0xF8, 0x0D, 0xC5, 0xE5,
	0x394, 0x5F, 0x3A6, 0x393, 0x39B, 0x3A9, 0x3A0, 0x3A8, 0x3A3, 0x398, 0x39E, 0x1B, 0xC6, 0xE6, 0xDF, 0xC9,
	0x20, 0x21, 0x22, 0x23, 0xA4, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F,
	0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,
	0xA1, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F,
	0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0xC4, 0xD6, 0xD1, 0xDC, 0xA7,
	0xBF, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F,
	0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0xE4, 0xF6, 0xF1, 0xFC, 0xE0
];

// 0x1B, then one of these, is the default alphabet's extension page.
const gsm7_ext = [];
gsm7_ext[0x0A] = 0x0C;
gsm7_ext[0x14] = 0x5E;
gsm7_ext[0x28] = 0x7B;
gsm7_ext[0x29] = 0x7D;
gsm7_ext[0x2F] = 0x5C;
gsm7_ext[0x3C] = 0x5B;
gsm7_ext[0x3D] = 0x7E;
gsm7_ext[0x3E] = 0x5D;
gsm7_ext[0x40] = 0x7C;
gsm7_ext[0x65] = 0x20AC;

const trace_escapes = { n: 10, r: 13, t: 9, '"': 34, '\\': 92, a: 7, b: 8, f: 12, v: 11 };

const HEX_DIGITS = '0123456789abcdef';

function hex_value(c) { return index(HEX_DIGITS, lc(c)); }

function unhex_int(h) {
	let v = 0;
	for (let i = 0; i < length(h); i++) {
		let d = hex_value(substr(h, i, 1));
		if (d < 0) break;
		v = v * 16 + d;
	}
	return v;
}

function hex_to_bytes(hex) {
	let s = replace(`${hex ?? ''}`, /[^0-9A-Fa-f]/g, '');
	if (length(s) % 2) s = substr(s, 0, length(s) - 1);
	let out = '';
	for (let i = 0; i < length(s); i += 2)
		out += chr(unhex_int(substr(s, i, 2)));
	return out;
}

function bytes_to_hex(bytes) {
	let out = '';
	for (let i = 0; i < length(bytes); i++)
		out += sprintf('%02X', ord(substr(bytes, i, 1)));
	return out;
}

function utf8_char(cp) {
	if (cp >= 0xD800 && cp < 0xE000) cp = 0x3F;
	if (cp < 0x80) return chr(cp);
	if (cp < 0x800) return chr(0xC0 | (cp >> 6)) + chr(0x80 | (cp & 0x3F));
	return chr(0xE0 | (cp >> 12)) + chr(0x80 | ((cp >> 6) & 0x3F)) + chr(0x80 | (cp & 0x3F));
}

// The text as UTF-8 code points (an answer is typed by the page, so it is UTF-8).
function utf8_codes(text) {
	let out = [], i = 0, n = length(text);
	while (i < n) {
		let c = ord(substr(text, i, 1));
		i++;
		let more = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : c >= 0xC0 ? 1 : 0;
		c &= more == 3 ? 0x07 : more == 2 ? 0x0F : more == 1 ? 0x1F : 0x7F;
		while (more > 0 && i < n) {
			let b = ord(substr(text, i, 1));
			if ((b & 0xC0) != 0x80) break;
			c = (c << 6) | (b & 0x3F);
			i++;
			more--;
		}
		push(out, c);
	}
	return out;
}

// Septets of the default alphabet, one per byte; 0xFF is the SIM's padding.
function decode_gsm7(data) {
	let out = '', n = length(data);
	for (let i = 0; i < n; i++) {
		let b = ord(substr(data, i, 1));
		if (b == 0xFF) break;
		if (b == 0x1B && i + 1 < n) {
			i++;
			out += utf8_char(gsm7_ext[ord(substr(data, i, 1))] ?? 0x20);
			continue;
		}
		out += utf8_char(gsm7_basic[b & 0x7F]);
	}
	return out;
}

function decode_gsm7_packed(data) {
	let n = length(data), septets = '', count = int(n * 8 / 7);
	for (let i = 0; i < count; i++) {
		let bit = i * 7, at = int(bit / 8), shift = bit % 8;
		let v = ord(substr(data, at, 1)) >> shift;
		if (shift > 1 && at + 1 < n)
			v |= ord(substr(data, at + 1, 1)) << (8 - shift);
		septets += chr(v & 0x7F);
	}
	if (count && (n * 8) % 7 == 0 && ord(substr(septets, count - 1, 1)) == 0x0D)
		septets = substr(septets, 0, count - 1);
	return decode_gsm7(septets);
}

function decode_ucs2(data) {
	let out = '', n = length(data);
	for (let i = 0; i + 1 < n; i += 2) {
		let a = ord(substr(data, i, 1)), b = ord(substr(data, i + 1, 1));
		if (a == 0xFF && b == 0xFF) continue;
		out += utf8_char((a << 8) | b);
	}
	return out;
}

// An alpha identifier: the default alphabet, or UCS-2 in one of 102 221's three forms.
function decode_alpha(data) {
	let n = length(data);
	if (n <= 0) return '';
	let first = ord(substr(data, 0, 1));
	if (first == 0x80) return decode_ucs2(substr(data, 1));
	if ((first == 0x81 && n >= 3) || (first == 0x82 && n >= 4)) {
		let count = ord(substr(data, 1, 1));
		let at = first == 0x81 ? 3 : 4;
		let base = first == 0x81 ? ord(substr(data, 2, 1)) << 7
		                         : (ord(substr(data, 2, 1)) << 8) | ord(substr(data, 3, 1));
		let out = '';
		for (let i = 0; i < count && at + i < n; i++) {
			let b = ord(substr(data, at + i, 1));
			out += (b & 0x80) ? utf8_char(base + (b & 0x7F)) : decode_gsm7(substr(data, at + i, 1));
		}
		return out;
	}
	return decode_gsm7(data);
}

// A text string: a data coding scheme byte, then packed septets, bytes or UCS-2.
function decode_text_string(data) {
	if (length(data) <= 1) return '';
	let dcs = ord(substr(data, 0, 1)) & 0x0C, body = substr(data, 1);
	if (dcs == 0x08) return decode_ucs2(body);
	if (dcs == 0x04) return decode_gsm7(body);
	return decode_gsm7_packed(body);
}

// A dialled number: TON/NPI, then two digits per byte, low first; 0xF is filler.
function decode_address(data) {
	const digits = '0123456789*#abc';
	let out = '';
	for (let i = 1; i < length(data); i++) {
		let b = ord(substr(data, i, 1));
		for (let half = 0; half < 2; half++) {
			let v = half ? (b >> 4) : (b & 0x0F);
			if (v == 0x0F) return out;
			if (v < length(digits)) out += substr(digits, v, 1);
		}
	}
	return out;
}

function parse_proactive_pdu(pdu) {
	let b = type(pdu) == 'string' ? hex_to_bytes(pdu) : `${pdu ?? ''}`;
	let n = length(b);
	if (n < 3 || ord(substr(b, 0, 1)) != 0xD0) return null;
	let i = 1, len = ord(substr(b, i, 1));
	i++;
	if (len == 0x81 && i < n) {
		len = ord(substr(b, i, 1));
		i++;
	} else if (len == 0x82 && i + 1 < n) {
		len = (ord(substr(b, i, 1)) << 8) | ord(substr(b, i + 1, 1));
		i += 2;
	}
	let end = min(n, i + len);
	let cmd = { details: [0, 0, 0], type: 0, qualifier: 0, title: '', text: '', fill: '', address: '',
	            items: [], count: 0, min: 0, max: 160, duration: 0, default_item: 0, immediate: false };
	while (i + 2 <= end) {
		let tag = ord(substr(b, i, 1)) & 0x7F;
		i++;
		let l = ord(substr(b, i, 1));
		i++;
		if (l == 0x81 && i < end) {
			l = ord(substr(b, i, 1));
			i++;
		} else if (l == 0x82 && i + 1 < end) {
			l = (ord(substr(b, i, 1)) << 8) | ord(substr(b, i + 1, 1));
			i += 2;
		}
		if (i + l > end) break;
		let v = substr(b, i, l);
		if (tag == 0x01 && l >= 3) {
			cmd.details = [ord(substr(v, 0, 1)), ord(substr(v, 1, 1)), ord(substr(v, 2, 1))];
		} else if (tag == 0x04 && l >= 2) {
			let unit = [60000, 1000, 100], k = ord(substr(v, 0, 1));
			cmd.duration = k < 3 ? unit[k] * ord(substr(v, 1, 1)) : 0;
		} else if (tag == 0x05) {
			cmd.title = decode_alpha(v);
		} else if (tag == 0x06) {
			cmd.address = decode_address(v);
		} else if (tag == 0x0D) {
			cmd.text = decode_text_string(v);
		} else if (tag == 0x0F && l >= 1 && cmd.count < ITEMS) {
			push(cmd.items, { id: ord(substr(v, 0, 1)), text: decode_alpha(substr(v, 1)) });
			cmd.count++;
		} else if (tag == 0x10 && l >= 1) {
			cmd.default_item = ord(substr(v, 0, 1));
		} else if (tag == 0x11 && l >= 2) {
			cmd.min = ord(substr(v, 0, 1));
			cmd.max = ord(substr(v, 1, 1));
		} else if (tag == 0x17) {
			cmd.fill = decode_text_string(v);
		} else if (tag == 0x2B) {
			cmd.immediate = true;
		}
		i += l;
	}
	cmd.type = cmd.details[1];
	cmd.qualifier = cmd.details[2];
	return cmd.type ? cmd : null;
}

return function(ctx) {
	const instance = `${TRACE_DIR}/instances/e5stk`;
	const probe = 'e5stk/sbuf';
	const state_path = `${SESSION_DIR}/state.json`;

	function uptime() {
		return +split(trim(readfile('/proc/uptime') ?? '0'), ' ')[0];
	}

	function now() {
		return int(uptime() * 1000);
	}

	function sim_present_hint(slot) {
		let data = null;
		try { data = json(readfile('/run/t551m-sims.json') ?? 'null'); } catch (e) { return null; }
		let row = data?.sims?.[slot];
		if (row?.present !== true && row?.present !== false) return null;
		let age = uptime() - +(row.updated ?? -1);
		if (!(age >= 0 && age <= 15)) return null;
		return row.present;
	}

	function at(slot, cmd, timeout) {
		return ctx.at(cmd, timeout ?? 10, slot);
	}

	// Shared with the LVGL interface: the plugin's setting, else the screen's.
	function setting_enabled() {
		let c = ctx.uci();
		return (c.get('e5-plugin-stk', 'settings', 'enabled') ?? c.get('e5-infoscreen', 'main', 'stk')) != '0';
	}

	function store_setting(on) {
		let c = ctx.uci(), v = on ? '1' : '0';
		if (c.get('e5-plugin-stk', 'settings', 'enabled') != v) {
			if (!stat('/etc/config/e5-plugin-stk')) writefile('/etc/config/e5-plugin-stk', '');
			if (c.get('e5-plugin-stk', 'settings') == null) c.set('e5-plugin-stk', 'settings', 'settings');
			c.set('e5-plugin-stk', 'settings', 'enabled', v);
			c.commit('e5-plugin-stk');
		}
		if (c.get('e5-infoscreen', 'main', 'stk') != v) {
			c.set('e5-infoscreen', 'main', 'stk', v);
			c.commit('e5-infoscreen');
		}
	}

	/* ---------- what outlives a request ---------- */

	function blank_slot() {
		return { iccid: '', profile: '', status_le: 0, view: 'empty', since: 0, pending: false,
		         present: false, registered: false, auto_clear: false, recovering: false,
		         notify: false, menu_known: false, no_menu: false, menu: null, menu_pdu: '', cmd: null,
		         ring: '', toast: '', timed_out: false };
	}

	function slot_at(st, slot) {
		while (length(st.slots) < 2) push(st.slots, blank_slot());
		let s = st.slots[slot];
		if (type(s) != 'object') s = st.slots[slot] = blank_slot();
		let defaults = blank_slot();
		for (let k in keys(defaults))
			if (s[k] == null && k != 'cmd' && k != 'menu') s[k] = defaults[k];
		return s;
	}

	function load_state() {
		let st = null;
		try { st = json(readfile(state_path) ?? 'null'); } catch (e) { st = null; }
		if (type(st) != 'object') st = {};
		if (type(st.slots) != 'array') st.slots = [];
		st.slot = st.slot == 1 ? 1 : 0;
		st.open = !!st.open;
		st.seen_at = int(st.seen_at ?? 0);
		st.ring_dst = st.ring_dst == null ? 3 : int(st.ring_dst);
		st.ring_ch = st.ring_ch == null ? 4 : int(st.ring_ch);
		slot_at(st, 0);
		slot_at(st, 1);
		return st;
	}

	// The page asked for the menus a moment ago: what the SIM sends now is
	// answered in the app, not raised as a background notification.
	function app_open(st) {
		return !!(st.open && st.seen_at && (now() - st.seen_at) <= 3000);
	}

	function save_state(st) {
		mkdir(SESSION_DIR, 0700);
		let tick = clock();
		let tmp = `${state_path}.${tick[0]}${tick[1]}`;
		if (!writefile(tmp, sprintf('%J\n', st))) return false;
		if (!rename(tmp, state_path)) {
			unlink(tmp);
			return false;
		}
		return true;
	}

	// The routes run in separate uhttpd workers: one request at a time, so a
	// slow modem call cannot be overwritten by another worker's stale state.
	function with_lock(fn) {
		mkdir(SESSION_DIR, 0700);
		let lock = fs_open(`${SESSION_DIR}/state.lock`, "w");
		if (lock) lock.lock("x");
		let res = fn();
		if (lock) {
			lock.lock("u");
			lock.close();
		}
		return res;
	}

	function session_path(slot) { return `${SESSION_DIR}/${slot}`; }

	// "<kind> <since, boot ms> <pdu>" is what the screen's STK app reads and writes.
	function save_slot_session(slot, kind, since, pdu) {
		mkdir(SESSION_DIR, 0700);
		return writefile(session_path(slot), sprintf('%s %d %s\n', kind, since, pdu));
	}

	function load_slot_session(slot) {
		let m = match(readfile(session_path(slot)) ?? '', /^([PC])[ \t]+([0-9]+)[ \t]+([0-9A-Fa-f]+)/);
		return m ? { kind: m[1], since: int(m[2]), pdu: uc(m[3]) } : null;
	}

	function clear_slot_session(slot) { unlink(session_path(slot)); }

	/* ---------- the main menu, kept by ICCID ---------- */

	function cache_path(iccid) { return `${CACHE_DIR}/${iccid}`; }

	// As the screen's own STK app keeps it: the SET UP MENU command's hex, or
	// "none" for a card found to offer no menu.
	function save_cached_pdu(iccid, pdu) {
		if (!iccid || !pdu || readfile(cache_path(iccid)) == pdu) return;
		mkdir(CACHE_DIR, 0755);
		writefile(cache_path(iccid), pdu);
	}

	function load_cached_menu(iccid) {
		let text = iccid ? readfile(cache_path(iccid)) : null;
		if (text == 'none') return { title: '', count: 0, items: [], pdu: '' };
		let cmd = text ? parse_proactive_pdu(text) : null;
		if (cmd?.type != CMD_SET_UP_MENU || !cmd.count) return null;
		return { title: cmd.title, count: cmd.count, items: cmd.items, pdu: text };
	}

	function use_cached_menu(s, menu) {
		s.menu = menu.count ? { title: menu.title, count: menu.count, items: menu.items } : null;
		s.menu_pdu = menu.pdu;
		s.menu_known = menu.count > 0;
		s.no_menu = !menu.count;
		s.view = s.menu_known ? 'menu' : 'empty';
	}

	function clear_cached_menu() {
		for (let name in lsdir(CACHE_DIR) ?? [])
			if (substr(name, 0, 1) != '.') unlink(`${CACHE_DIR}/${name}`);
	}

	/* ---------- answers ---------- */

	function settle(st, slot) {
		let s = slot_at(st, slot);
		s.pending = false;
		s.notify = false;
		s.timed_out = false;
		clear_slot_session(slot);
	}

	// The same command sent again, as the modem replays it, keeps its time.
	function wait_for_user(st, slot, kind, pdu) {
		let s = slot_at(st, slot), since = now();
		let old = load_slot_session(slot);
		if (old && old.kind == kind && old.pdu == pdu && old.since) since = old.since;
		s.pending = true;
		s.since = since;
		save_slot_session(slot, kind, since, pdu);
	}

	function tr_bytes(details, result, extra) {
		let b = chr(0x81) + chr(3) + chr(details[0] ?? 0) + chr(details[1] ?? 0) + chr(details[2] ?? 0)
		      + chr(0x82) + chr(2) + chr(0x82) + chr(0x81)
		      + chr(0x83) + chr(1) + chr(result & 0xFF);
		return extra ? b + extra : b;
	}

	function send_tr(slot, details, result, extra) {
		let b = tr_bytes(details, result, extra);
		at(slot, `AT+SPUSATTERMINAL="${bytes_to_hex(b)}"`);
		return b;
	}

	function text_tlv(dcs, data) {
		let len = length(data) + 1;
		if (len > 0x7F) return chr(0x8D) + chr(0x81) + chr(len) + chr(dcs) + data;
		return chr(0x8D) + chr(len) + chr(dcs) + data;
	}

	// ASCII stays 8-bit GSM, anything else goes back as UCS-2.
	function input_tlv(text, qualifier) {
		let codes = utf8_codes(`${text ?? ''}`), ucs2 = (qualifier ?? 0) & 0x02, data = '';
		if (!ucs2)
			for (let c in codes)
				if (c > 0x7F) ucs2 = true;
		if (ucs2) {
			for (let c in codes) {
				if (c > 0xFFFF) c = 0x3F;
				data += chr((c >> 8) & 0xFF) + chr(c & 0xFF);
			}
			return text_tlv(0x08, data);
		}
		for (let c in codes) data += chr(c & 0xFF);
		return text_tlv(0x04, data);
	}

	function send_envelope_menu(slot, item_id) {
		at(slot, sprintf('AT+SPUSATENVECMD="D307820201819001%02X"', item_id & 0xFF));
	}

	function call_setup(slot, accept) {
		at(slot, sprintf('AT+SPUSATCALLSETUP=%d', accept ? 1 : 0));
	}

	function answer_time(s) {
		if (s.cmd?.duration) return s.cmd.duration;
		return s.cmd?.type == CMD_DISPLAY_TEXT ? TEXT_TIMEOUT : UI_TIMEOUT;
	}

	function back_to_menu(st, slot) {
		let s = slot_at(st, slot);
		settle(st, slot);
		s.notify = false;
		s.auto_clear = false;
		s.view = s.menu_known ? 'menu' : 'empty';
	}

	/* ---------- proactive commands ---------- */

	function show_command(s) {
		let type = s.cmd?.type ?? 0;
		s.auto_clear = false;
		if (type == CMD_SELECT_ITEM) s.view = 'select';
		else if (type == CMD_DISPLAY_TEXT) s.view = 'text';
		else if (type == CMD_SET_UP_CALL) s.view = 'call';
		else if (type == CMD_GET_INKEY && ((s.cmd.qualifier ?? 0) & 0x04)) s.view = 'yesno';
		else s.view = 'input';
		if (type == CMD_GET_INKEY && s.view == 'input') s.cmd.min = s.cmd.max = 1;
	}

	function handle_cmd(st, slot, hex) {
		let s = slot_at(st, slot), cmd = parse_proactive_pdu(hex);
		if (!cmd) return null;
		let type = cmd.type, qualifier = cmd.qualifier;
		let pdu = bytes_to_hex(hex_to_bytes(hex));
		if (type == CMD_SET_UP_MENU) {
			s.recovering = false;
			if (cmd.count) {
				s.menu = { title: cmd.title, count: cmd.count, items: cmd.items };
				s.menu_known = true;
				s.no_menu = false;
				s.menu_pdu = pdu;
				save_cached_pdu(s.iccid, pdu);
			} else {
				s.menu = null;
				s.menu_known = false;
				s.no_menu = true;
				s.menu_pdu = '';
				save_cached_pdu(s.iccid, 'none');
			}
			send_tr(slot, cmd.details, TR_OK);
			if (s.view == 'loading' || s.view == 'empty' || s.view == 'menu')
				s.view = s.menu_known ? 'menu' : 'empty';
		} else if (type == CMD_SELECT_ITEM || type == CMD_GET_INPUT || type == CMD_GET_INKEY
		           || type == CMD_DISPLAY_TEXT || type == CMD_SET_UP_CALL) {
			if (s.timed_out && type != CMD_DISPLAY_TEXT && type != CMD_SET_UP_CALL) {
				send_tr(slot, cmd.details, TR_END);
				back_to_menu(st, slot);
				return cmd;
			}
			s.cmd = cmd;
			show_command(s);
			// Text that clears by itself, or asks for an immediate response, is
			// acknowledged at once; the first kind also goes away by itself.
			if (type == CMD_DISPLAY_TEXT && (!(qualifier & 0x80) || cmd.immediate)) {
				settle(st, slot);
				send_tr(slot, cmd.details, TR_OK);
				s.auto_clear = !(qualifier & 0x80);
				s.since = now();
			} else {
				wait_for_user(st, slot, type == CMD_SET_UP_CALL ? 'C' : 'P', pdu);
			}
			// Settling an answer clears it, so this comes last: a command the page
			// is not looking at is the one that has to be brought to the user.
			s.notify = !app_open(st);
		} else if (type == CMD_REFRESH || type == CMD_MORE_TIME || type == CMD_SEND_SMS
		           || type == CMD_SEND_SS || type == CMD_SEND_USSD || type == CMD_SEND_DTMF
		           || type == CMD_LAUNCH_BROWSER || type == CMD_PLAY_TONE || type == CMD_SET_UP_IDLE_TEXT
		           || type == CMD_SET_UP_EVENT_LIST || type == CMD_LANGUAGE_NOTIFICATION) {
			send_tr(slot, cmd.details, TR_OK);
			if (type == CMD_PLAY_TONE && cmd.title) s.toast = cmd.title;
		} else if (type == CMD_PROVIDE_LOCAL_INFO && qualifier == 0x04) {
			send_tr(slot, cmd.details, TR_OK, chr(0x2D) + chr(2) + 'zh');
		} else {
			send_tr(slot, cmd.details, TR_UNABLE);
		}
		return cmd;
	}

	/* ---------- what came on a card's URC ring ---------- */

	function urc_line(st, slot, line) {
		let s = slot_at(st, slot), m;
		if ((m = match(line, /\+SPUSATPROCMDIND:[ \t]*([0-9A-Fa-f]+)/))) {
			handle_cmd(st, slot, m[1]);
			return 'procmd';
		}
		if ((m = match(line, /\+SPUSATSETUPCALL:[ \t]*([0-9A-Fa-f]+)/))) {
			let cmd = parse_proactive_pdu(m[1]);
			if (cmd) {
				s.notify = !app_open(st);
				s.cmd = cmd;
				show_command(s);
				wait_for_user(st, slot, 'C', bytes_to_hex(hex_to_bytes(m[1])));
			}
			return 'call';
		}
		if ((m = match(line, /\+SPUSATDISPLAY:[ \t]*([0-9A-Fa-f]+)/))) {
			let cmd = parse_proactive_pdu(m[1]);
			if (cmd) s.toast = cmd.title || cmd.text;
			return 'display';
		}
		if (index(line, '+SPUSATENDSESSIONIND') >= 0) {
			if (s.view != 'text' || s.pending) back_to_menu(st, slot);
			return 'end';
		}
		return null;
	}

	function ring_data(st, slot, data) {
		let s = slot_at(st, slot);
		s.ring = `${s.ring ?? ''}${data}`;
		for (;;) {
			let nl = index(s.ring, '\n');
			if (nl < 0) break;
			let line = replace(substr(s.ring, 0, nl), /\r/g, '');
			s.ring = substr(s.ring, nl + 1);
			if (line != '') urc_line(st, slot, line);
		}
		if (length(s.ring) > 1200) s.ring = substr(s.ring, length(s.ring) - 1200);
	}

	function unescape_trace(text) {
		let out = '', i = 0, n = length(text);
		while (i < n) {
			let c = substr(text, i, 1);
			i++;
			if (c != '\\' || i >= n) {
				out += c;
				continue;
			}
			let e = substr(text, i, 1);
			i++;
			if (e == 'x') {
				let v = 0, digits = 0;
				while (i < n && digits < 2) {
					let d = hex_value(substr(text, i, 1));
					if (d < 0) break;
					v = v * 16 + d;
					i++;
					digits++;
				}
				out += digits ? chr(v) : 'x';
			} else if (match(e, /[0-7]/)) {
				let v = int(e), digits = 1;
				while (i < n && digits < 3) {
					let d = substr(text, i, 1);
					if (!match(d, /[0-7]/)) break;
					v = v * 8 + int(d);
					i++;
					digits++;
				}
				out += chr(v & 0xFF);
			} else if (trace_escapes[e] != null) {
				out += chr(trace_escapes[e]);
			} else {
				out += e;
			}
		}
		return out;
	}

	function trace_string(line) {
		let at_ = index(line, 'str="');
		if (at_ < 0) return null;
		let i = at_ + 5, n = length(line), raw = '';
		while (i < n) {
			let c = substr(line, i, 1);
			if (c == '\\' && i + 1 < n) {
				raw += c + substr(line, i + 1, 1);
				i += 2;
				continue;
			}
			if (c == '"') return unescape_trace(raw);
			raw += c;
			i++;
		}
		return null;
	}

	// "... ring=0 ... d={0x0000000000000061,...}": the probe's hex words, little-endian.
	function trace_words(line) {
		let at_ = index(line, 'd={');
		if (at_ < 0) return null;
		let end = index(line, '}', at_);
		if (end < 0) return null;
		let out = '';
		for (let word in split(substr(line, at_ + 3, end - at_ - 3), ',')) {
			let w = replace(trim(word), /^0x/i, '');
			if (!match(w, /^[0-9A-Fa-f]+$/)) continue;
			while (length(w) < 16) w = '0' + w;
			w = substr(w, length(w) - 16);
			for (let i = 7; i >= 0; i--) out += chr(unhex_int(substr(w, i * 2, 2)));
		}
		return out;
	}

	function parse_trace_line(line) {
		let m = match(line, /(^|[ \t])ring=([0-9]+)/);
		if (!m) return null;
		let data = trace_string(line);
		if (data == null) data = trace_words(line);
		if (data == null) return null;
		let n = match(line, /(^|[ \t])n=([0-9]+)/);
		if (n && int(n[2]) < length(data)) data = substr(data, 0, int(n[2]));
		return { ring: int(m[2]), data };
	}

	// ring 0 is the first card, ring 3 the second once the modem is in its
	// dual-SIM channel mapping; anything else is nobody's.
	function feed_trace(st, line) {
		let t = parse_trace_line(line);
		let slot = t?.ring == 0 ? 0 : t?.ring == 3 ? 1 : -1;
		if (slot >= 0) ring_data(st, slot, t.data);
	}

	function poll_ring(st) {
		let trace = `${instance}/trace`;
		// Sending a terminal response can make the modem emit the next URC at
		// once; read the buffer again before leaving the request.
		for (let round = 0; round < 4; round++) {
			let text = readfile(trace) ?? '';
			if (index(text, 'ring=') < 0) break;
			writefile(trace, '');
			for (let line in split(text, '\n'))
				if (line != '') feed_trace(st, line);
		}
	}

	// Draining the ring right after the answer catches a URC the modem emits
	// while it processes the terminal response.
	function answer(st, slot, result, extra) {
		let s = slot_at(st, slot), details = s.cmd?.details ?? [0, 0, 0];
		settle(st, slot);
		let b = send_tr(slot, details, result, extra);
		poll_ring(st);
		s.view = 'wait';
		s.since = now();
		return b;
	}

	/* ---------- the tracefs instance behind the URC rings ---------- */

	function csim_reply(line) {
		let m = match(`${line ?? ''}`, /\+CSIM:[^,]*,[ \t]*"?([0-9A-Fa-f]+)/);
		return m ? hex_to_bytes(m[1]) : '';
	}

	function install_sim_service() {
		if (readfile(SIM_SERVICE) != SIM_SERVICE_TEXT) {
			writefile(SIM_SERVICE, SIM_SERVICE_TEXT);
			ctx.run(`chmod 755 ${SIM_SERVICE}`);
		}
		if (!lstat(SIM_RC)) ctx.run(`${SIM_SERVICE} enable`);
	}

	// Until the boot service has set the dual-SIM channel mapping, what the
	// cards send cannot be told apart; a service enabled after this boot
	// waits for the next one.
	function awaiting_restart() {
		if (stat(`${SESSION_DIR}/mapped`)) return false;
		let link = lstat(SIM_RC);
		return !link || link.mtime > time() - int(uptime());
	}

	function find_ring(st) {
		for (let core in lsdir(DEVICE_TREE) ?? []) {
			let core_id = match(core, /^core@([0-9A-Fa-f]+)$/);
			if (!core_id) continue;
			for (let channel in lsdir(`${DEVICE_TREE}/${core}`) ?? []) {
				let channel_id = match(channel, /^channel@([0-9A-Fa-f]+)$/);
				if (!channel_id) continue;
				let label = trim(replace(readfile(`${DEVICE_TREE}/${core}/${channel}/label`) ?? "", "\x00", ""));
				if (label != 'stty_nr') continue;
				st.ring_dst = unhex_int(core_id[1]);
				st.ring_ch = unhex_int(channel_id[1]);
				return;
			}
		}
	}

	function append_file(path, text) {
		let file = fs_open(path, 'a');
		if (!file) return false;
		let ok = file.write(text);
		file.close();
		return ok != null;
	}

	function ensure_trace(st) {
		if (!stat(TRACE_DIR)) return;
		find_ring(st);
		let filter = sprintf("n>0 && dst==%d && ch==%d && (ring==0 || ring==3)\n", st.ring_dst, st.ring_ch);
		if (trim(readfile(`${instance}/events/${probe}/enable`) ?? "") == "1"
		    && readfile(`${instance}/events/${probe}/filter`) == filter)
			return;
		if (!stat(`${TRACE_DIR}/events/${probe}`))
			append_file(`${TRACE_DIR}/kprobe_events`,
				`r:${probe} sipc_core:sbuf_read dst=$arg1:u8 ch=$arg2:u8 ring=$arg3:u32 `
				+ 'n=$retval:s32 d=+0($arg4):x64[32]\n');
		mkdir(`${TRACE_DIR}/instances`, 0700);
		mkdir(instance, 0700);
		writefile(`${instance}/events/${probe}/filter`, filter);
		writefile(`${instance}/events/${probe}/enable`, '1\n');
	}

	/* ---------- the main menu, from the card or its cache ---------- */

	function read_iccid(slot) {
		let m = match(at(slot, 'AT+CCID') ?? '', /\+CCID:[ \t]*"?([0-9A-Fa-f]{1,23})/);
		return m ? uc(m[1]) : null;
	}

	function terminal_profile(st, slot) {
		let s = slot_at(st, slot);
		let profile = replace(s.profile ?? '', /[^0-9A-Fa-f]/g, '');
		if (!profile) return;
		let reply = at(slot, sprintf('AT+CSIM=%d,"80100000%02X%s"', length(profile) + 10,
		                             int(length(profile) / 2), uc(profile)));
		let b = csim_reply(reply);
		let cmd = parse_proactive_pdu(bytes_to_hex(substr(b, 0, max(0, length(b) - 2))));
		if (!cmd) return;
		let tr = tr_bytes(cmd.details, cmd.type == CMD_SET_UP_EVENT_LIST ? TR_OK : TR_UNABLE);
		let apdu = chr(0x80) + chr(0x14) + chr(0) + chr(0) + chr(length(tr)) + tr;
		let hex = bytes_to_hex(apdu);
		at(slot, sprintf('AT+CSIM=%d,"%s"', length(hex), hex));
	}

	function status_poll(st, slot) {
		let s = slot_at(st, slot);
		let b = csim_reply(at(slot, sprintf('AT+CSIM=10,"80F20000%02X"', s.status_le & 0xFF)));
		let n = length(b);
		if (n >= 2 && ord(substr(b, n - 2, 1)) == 0x6C) {
			s.status_le = ord(substr(b, n - 1, 1));
			b = csim_reply(at(slot, sprintf('AT+CSIM=10,"80F20000%02X"', s.status_le & 0xFF)));
		}
		poll_ring(st);
	}

	// Cached menu or not, the card is read again: another card in the slot is
	// another toolkit.
	function recover_slot_menu(st, slot, force) {
		let s = slot_at(st, slot);
		let hint = sim_present_hint(slot);
		if (hint === false) {
			s.present = false;
			s.recovering = false;
			s.view = 'empty';
			return { ok: false, error: 'No SIM card' };
		}
		s.view = 'loading';
		s.since = now();
		s.recovering = true;
		let iccid = read_iccid(slot);
		if (iccid) {
			if (s.iccid && s.iccid != iccid) {
				s.menu_known = false;
				s.no_menu = false;
				s.menu = null;
			}
			s.iccid = iccid;
			s.present = true;
		}
		if (!force) {
			// A menu that came before any ICCID was read is this card's.
			if (s.menu_known && s.menu) {
				save_cached_pdu(s.iccid, s.menu_pdu);
				s.view = 'menu';
				s.recovering = false;
				return { ok: true, cached: true, view: 'menu' };
			}
			let menu = load_cached_menu(s.iccid);
			if (menu) {
				use_cached_menu(s, menu);
				s.recovering = false;
				return { ok: true, cached: true, view: s.view };
			}
		}
		if (!s.iccid) {
			s.recovering = false;
			s.present = false;
			s.menu_known = false;
			s.no_menu = true;
			s.view = 'empty';
			return { ok: false, error: 'No SIM card' };
		}
		at(slot, `AT+CUSATW=0,"${TE_PROFILE}"`);
		let m = match(at(slot, 'AT+SPUSATPROFILE?') ?? '', /\+SPUSATPROFILE:[ \t]*([0-9A-Fa-f]+)/);
		if (m) s.profile = uc(m[1]);
		poll_ring(st);
		if (s.menu_known && s.menu) {
			s.view = 'menu';
			s.recovering = false;
			return { ok: true, cached: false, view: 'menu' };
		}
		settle(st, slot);
		s.cmd = null;
		s.view = "loading";
		terminal_profile(st, slot);
		poll_ring(st);
		if (!s.menu_known) {
			status_poll(st, slot);
			s.polled = now();
		}
		return { ok: true, cached: false, view: s.view };
	}

	function reload_slot_menu(st, slot) {
		let s = slot_at(st, slot);
		settle(st, slot);
		s.cmd = null;
		s.auto_clear = false;
		s.menu_known = false;
		s.no_menu = false;
		s.menu = null;
		return recover_slot_menu(st, slot, true);
	}

	/* ---------- time ---------- */

	function check_timeouts(st) {
		let t = now(), changed = false;
		for (let i = 0; i < 2; i++) {
			let s = slot_at(st, i);
			if (!s.since) continue;
			let idle = t - s.since;
			if (s.pending && idle > answer_time(s)) {
				if (s.view == 'call') {
					call_setup(i, false);
					back_to_menu(st, i);
				} else {
					let timed_out = s.view != 'text';
					answer(st, i, s.view == 'text' ? TR_OK : TR_NO_RESPONSE);
					s.timed_out = timed_out;
				}
				changed = true;
			} else if (s.view == 'wait' && idle > UI_TIMEOUT) {
				back_to_menu(st, i);
				changed = true;
			} else if (s.view == 'text' && s.auto_clear) {
				let limit = s.cmd?.duration ? s.cmd.duration : TEXT_CLEAR_TIMEOUT;
				if (idle > limit) {
					back_to_menu(st, i);
					changed = true;
				}
			} else if (s.view == 'loading' && idle > LOAD_GIVE_UP) {
				s.recovering = false;
				s.menu_known = false;
				s.no_menu = true;
				s.view = 'empty';
				changed = true;
			} else if (s.view == 'loading' && s.recovering && t - (s.polled ?? 0) >= 2000) {
				s.polled = t;
				status_poll(st, i);
				changed = true;
			}
		}
		return changed;
	}

	function disable_stk(st) {
		let t = now();
		for (let i = 0; i < 2; i++) {
			let s = slot_at(st, i);
			if (s.pending) {
				if (s.view == 'call') call_setup(i, false);
				else send_tr(i, s.cmd?.details ?? [0, 0, 0], TR_NO_RESPONSE);
			}
			settle(st, i);
			s.view = 'empty';
			s.recovering = false;
			s.registered = false;
			s.since = t;
		}
		if (stat(`${instance}/events/${probe}/enable`)) writefile(`${instance}/events/${probe}/enable`, "0\n");
		unlink(SIM_RC);
	}

	function sync(st) {
		// Copied into the plugin's setting, so that its settings page does not show the
		// manifest's default.
		if (ctx.uci().get('e5-plugin-stk', 'settings', 'enabled') == null)
			store_setting(setting_enabled());
		if (setting_enabled()) {
			install_sim_service();
			if (awaiting_restart()) return;
			ensure_trace(st);
			// A card that has just appeared is registered with the toolkit once:
			// only then does the modem forward its proactive commands.
			for (let i = 0; i < 2; i++) {
				let hint = sim_present_hint(i), s = slot_at(st, i);
				if (hint === false) {
					s.present = false;
					s.registered = false;
				} else if (hint === true && !s.registered) {
					s.registered = true;
					s.present = true;
					if (!s.iccid) s.iccid = read_iccid(i) ?? "";
					at(i, sprintf("AT+CUSATW=0,\"%s\"", TE_PROFILE));
				}
			}
			poll_ring(st);
		} else if (slot_at(st, 0).pending || slot_at(st, 1).pending ||
		           slot_at(st, 0).registered || slot_at(st, 1).registered || lstat(SIM_RC)) {
			disable_stk(st);
		}
		check_timeouts(st);
	}

	/* ---------- what the page shows ---------- */

	function status_of(st) {
		let slots = [], present = [], t = now();
		for (let i = 0; i < 2; i++) {
			let s = slot_at(st, i), view = s.view ?? 'empty';
			let items = [];
			if (view == 'menu' && s.menu) items = s.menu.items;
			else if (view == 'select' && s.cmd) items = s.cmd.items;
			let qualifier = s.cmd?.qualifier ?? 0;
			let limit = 0;
			if (s.pending) limit = answer_time(s);
			else if (view == 'wait') limit = UI_TIMEOUT;
			else if (view == 'text' && s.auto_clear)
				limit = s.cmd?.duration ? s.cmd.duration : TEXT_CLEAR_TIMEOUT;
			push(slots, {
				slot: i, view,
				pending: !!s.pending,
				present: !!s.present,
				iccid: s.iccid ?? '',
				toast: s.toast ?? '',
				title: view == 'menu' ? (s.menu?.title ?? '') : (s.cmd?.title ?? ''),
				text: index(LIVE_VIEWS, view) >= 0 ? (s.cmd?.text ?? '') : '',
				items: map(items, item => ({ id: item.id, text: item.text })),
				min: s.cmd?.min ?? 0,
				max: s.cmd?.max ?? 0,
				default_item: s.cmd?.default_item ?? 0,
				default_text: s.cmd?.fill ?? '',
				duration: s.cmd?.duration ?? 0,
				secret: !!(qualifier & 0x04),
				digits_only: view == 'input' && !(qualifier & 0x01),
				call_number: view == 'call' ? (s.cmd?.address ?? '') : '',
				auto_clear: !!s.auto_clear,
				remaining: limit ? max(0, limit - (t - s.since)) : 0
			});
			push(present, !!s.present);
		}
		return { ok: true, enabled: setting_enabled(), restart: awaiting_restart(), slot: st.slot, slots,
		         sim_present: present, dual_sim: present[0] && present[1] };
	}

	function notifications_of(st) {
		let out = [], wake = false;
		for (let i = 0; i < 2; i++) {
			let s = slot_at(st, i);
			if (!s.notify || !(s.pending || s.view == "text") || index(LIVE_VIEWS, s.view) < 0) continue;
			wake = true;
			let body = s.cmd?.title || s.cmd?.text
			           || (length(s.cmd?.items ?? []) ? join(" / ", map(slice(s.cmd.items, 0, 3), x => x.text)) : "")
			           || (s.view == 'call' ? 'SIM 卡请求拨打电话' : 'SIM 卡请求');
			push(out, { id: `stk-${i}`, slot: i, wake: true,
			            title: { zh: `SIM ${i + 1} 请求`, en: `SIM ${i + 1} request` }, body });
		}
		return { notifications: out, wake };
	}

	/* ---------- the routes ---------- */

	function restore_sessions(st) {
		for (let i = 0; i < 2; i++) {
			let s = slot_at(st, i);
			if (s.pending || s.view == 'wait' || s.view == 'text') continue;
			let sess = load_slot_session(i);
			if (!sess) continue;
			let cmd = parse_proactive_pdu(sess.pdu);
			if (!cmd) {
				clear_slot_session(i);
				continue;
			}
			s.cmd = cmd;
			if (sess.kind == 'C') {
				s.view = 'call';
				s.auto_clear = false;
			} else {
				show_command(s);
			}
			s.pending = true;
			s.since = sess.since;
			s.notify = !!s.notify;
		}
	}

	// The other card only needs to be known (the tabs show it); its menu is read
	// when it is opened.
	function probe_slot(st, slot) {
		let s = slot_at(st, slot);
		if (s.pending) return;
		let iccid = read_iccid(slot);
		if (!iccid) {
			s.present = false;
			return;
		}
		s.present = true;
		if (s.iccid && s.iccid != iccid) {
			s.menu_known = false;
			s.no_menu = false;
			s.menu = null;
		}
		s.iccid = iccid;
		if (s.menu_known && s.menu) {
			save_cached_pdu(iccid, s.menu_pdu);
			s.view = 'menu';
			return;
		}
		let menu = load_cached_menu(iccid);
		if (menu) use_cached_menu(s, menu);
	}

	function in_session(s) { return s.pending || s.view == "wait" || s.view == "text"; }

	function open_toolkit(slot) {
		let st = load_state();
		st.open = true;
		st.seen_at = now();
		for (let i = 0; i < 2; i++) slot_at(st, i).notify = false;
		if (slot != null) {
			st.slot = slot;
		} else {
			if (sim_present_hint(0) === false && sim_present_hint(1) === true)
				st.slot = 1;
			for (let i = 0; i < 2; i++)
				if (in_session(slot_at(st, i))) st.slot = i;
		}
		slot = st.slot;
		sync(st);
		if (!setting_enabled() || awaiting_restart()) {
			save_state(st);
			return status_of(st);
		}
		restore_sessions(st);
		check_timeouts(st);
		for (let i = 0; i < 2; i++) {
			if (i == slot) continue;
			let other = slot_at(st, i);
			let hint = sim_present_hint(i);
			if (hint === true || hint === false) {
				other.present = hint;
				if (!hint) {
					other.view = 'empty';
					other.recovering = false;
				} else if (!other.pending) {
					let menu = load_cached_menu(other.iccid);
					if (menu) use_cached_menu(other, menu);
				}
			} else {
				probe_slot(st, i);
			}
		}
		let s = slot_at(st, slot);
		if (!in_session(s)) recover_slot_menu(st, slot, false);
		let out = status_of(st);
		for (let i = 0; i < 2; i++) slot_at(st, i).toast = "";
		save_state(st);
		return out;
	}

	function choose(slot, item_id) {
		let st = load_state();
		if (st.open) st.seen_at = now();
		sync(st);
		let s = slot_at(st, slot);
		if (s.view == 'menu' && !s.pending) {
			send_envelope_menu(slot, item_id);
			poll_ring(st);
			s.view = 'wait';
			s.since = now();
		} else if (s.view == 'select' && s.pending) {
			answer(st, slot, TR_OK, chr(0x90) + chr(1) + chr(item_id & 0xFF));
		} else {
			save_state(st);
			return { ok: false, error: 'No list to choose from' };
		}
		save_state(st);
		return { ok: true };
	}

	function send_input(slot, text) {
		let st = load_state();
		if (st.open) st.seen_at = now();
		sync(st);
		let s = slot_at(st, slot);
		if (s.view != 'input' || !s.pending) {
			save_state(st);
			return { ok: false, error: 'No text was requested' };
		}
		answer(st, slot, TR_OK, input_tlv(text, s.cmd?.qualifier ?? 0));
		save_state(st);
		return { ok: true };
	}

	function send_yesno(slot, yes) {
		let st = load_state();
		if (st.open) st.seen_at = now();
		sync(st);
		let s = slot_at(st, slot);
		if (s.view != 'yesno' || !s.pending) {
			save_state(st);
			return { ok: false, error: 'No question was asked' };
		}
		answer(st, slot, TR_OK, chr(0x8D) + chr(2) + chr(0x04) + chr(yes ? 1 : 0));
		save_state(st);
		return { ok: true };
	}

	function ack(slot) {
		let st = load_state();
		if (st.open) st.seen_at = now();
		sync(st);
		let s = slot_at(st, slot);
		if (s.pending) answer(st, slot, TR_OK);
		else back_to_menu(st, slot);
		save_state(st);
		return { ok: true };
	}

	function answer_call(slot, accept) {
		let st = load_state();
		if (st.open) st.seen_at = now();
		sync(st);
		call_setup(slot, accept);
		poll_ring(st);
		settle(st, slot);
		let s = slot_at(st, slot);
		s.view = 'wait';
		s.since = now();
		save_state(st);
		return { ok: true };
	}

	function back(slot) {
		let st = load_state();
		if (st.open) st.seen_at = now();
		sync(st);
		let s = slot_at(st, slot);
		if (s.view == 'call') {
			call_setup(slot, false);
			poll_ring(st);
			settle(st, slot);
			s.view = 'wait';
			s.since = now();
		} else if (s.pending) {
			answer(st, slot, TR_BACK);
		} else {
			back_to_menu(st, slot);
		}
		save_state(st);
		return { ok: true };
	}

	function retry(slot) {
		let st = load_state();
		sync(st);
		let r = reload_slot_menu(st, slot);
		save_state(st);
		return r;
	}

	// What is left on screen stays, and gets NO RESPONSE FROM USER once its
	// time runs out, as it would with the page open.
	function close_toolkit() {
		return with_lock(function() {
			let st = load_state();
			st.open = false;
			st.seen_at = 0;
			for (let i = 0; i < 2; i++) slot_at(st, i).notify = false;
			save_state(st);
			return { ok: true };
		});
	}

	function clear_cache() {
		clear_cached_menu();
		let st = load_state();
		for (let i = 0; i < 2; i++) {
			let s = slot_at(st, i);
			s.menu_known = false;
			s.no_menu = false;
			s.menu = null;
			if (s.view == 'menu') s.view = 'empty';
		}
		save_state(st);
		return { ok: true };
	}

	// Off, nothing is asked of the SIMs and what they sent ends as if the user
	// had gone away.
	function set_enabled(on) {
		let st = load_state();
		store_setting(on);
		sync(st);
		save_state(st);
		return { ok: true, enabled: on };
	}

	return {
		status: function() {
			return with_lock(() => {
				let st = load_state();
				if (st.open) {
					st.seen_at = now();
					for (let i = 0; i < 2; i++) slot_at(st, i).notify = false;
				}
				sync(st);
				let out = status_of(st);
				for (let i = 0; i < 2; i++) slot_at(st, i).toast = "";
				save_state(st);
				return out;
			});
		},
		notifications: function() {
			return with_lock(() => {
				let st = load_state();
				sync(st);
				save_state(st);
				return notifications_of(st);
			});
		},
		open: slot => with_lock(() => open_toolkit(slot)),
		close: close_toolkit,
		choose: (slot, item_id) => with_lock(() => choose(slot, item_id)),
		input: (slot, text) => with_lock(() => send_input(slot, text)),
		yesno: (slot, yes) => with_lock(() => send_yesno(slot, yes)),
		ack: slot => with_lock(() => ack(slot)),
		call: (slot, accept) => with_lock(() => answer_call(slot, accept)),
		back: slot => with_lock(() => back(slot)),
		retry: slot => with_lock(() => retry(slot)),
		clear_cache: () => with_lock(() => clear_cache()),
		set_enabled: on => with_lock(() => set_enabled(on))
	};
};
