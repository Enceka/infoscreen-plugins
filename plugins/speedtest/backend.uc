'use strict';
import { readfile, writefile, unlink, stat, mkdir } from 'fs';

const DIR = '/tmp/run/e5-infoscreen/speedtest';
const PHASES = [ 'IDLE', 'INSTALLING', 'CONNECTING', 'PING', 'DOWNLOAD', 'UPLOAD', 'DONE', 'FAILED' ];
const BUSY = [ 'INSTALLING', 'CONNECTING', 'PING', 'DOWNLOAD', 'UPLOAD' ];

// The same steps as the LVGL interface's (src/speedtest.c). The version comes
// from jsDelivr: the proxies answer releases/latest with a relative redirect
// that uclient-fetch cannot follow. Lines starting with @ name the step for
// the progress dialog.
const GLOBAL_INSTALL = join('\n', [
	'fetch() {',
	'  if command -v curl >/dev/null; then',
	'    [ -n "$3" ] && quiet=-# || quiet=-sS',
	'    curl -fL $quiet --connect-timeout 10 --max-time 300 -o "$2" "$1"',
	'  else',
	'    [ -n "$3" ] && quiet= || quiet=-q',
	'    timeout 300 uclient-fetch $quiet -T 10 -O "$2" "$1"',
	'  fi',
	'}',
	'dir=$(mktemp -d) && trap \'rm -rf "$dir"\' EXIT && cd "$dir" || exit 1',
	'echo @check',
	'fetch https://data.jsdelivr.com/v1/packages/gh/XiaoMengXinX/globalspeedtest-go/resolved latest &&',
	'  version=$(jsonfilter -i latest -e @.version) || exit 1',
	'release=https://github.com/XiaoMengXinX/globalspeedtest-go/releases/download/v$version',
	'name=globalspeedtest-go_${version}_Linux_arm64.tar.gz',
	'for mirror in https://gh-proxy.org/ https://cdn.gh-proxy.org/ https://ghproxy.net/ \'\'; do',
	'  host=${mirror#https://}',
	'  echo "@download $version ${host%/}"',
	'  fetch "$mirror$release/checksums.txt" sums && fetch "$mirror$release/$name" "$name" progress &&',
	'    grep " $name$" sums | sha256sum -c -s || continue',
	'  echo @install',
	'  tar -xzOf "$name" globalspeedtest-go > /usr/bin/globalspeedtest-go.part &&',
	'    chmod 755 /usr/bin/globalspeedtest-go.part &&',
	'    mv /usr/bin/globalspeedtest-go.part /usr/bin/globalspeedtest-go',
	'  exit',
	'done',
	'exit 1'
]) + '\n';

// apk writes its progress as "done/total" lines.
const SPEEDTEST_INSTALL = join('\n', [
	'echo @update',
	'apk update --progress-fd 3 3>&1 >/dev/null 2>&1',
	'echo @add',
	'exec apk add --progress-fd 3 speedtest-go 3>&1 >/dev/null 2>&1'
]) + '\n';

// The test programs print their progress only to a terminal: this runs one on
// a pseudo-terminal, outliving the request, and leaves what it printed and its
// exit code in the job's directory.
const RUNNER = `#!/usr/bin/env python3
import errno
import os
import pty
import subprocess
import sys

work = sys.argv[1]
master, slave = pty.openpty()
child = subprocess.Popen(sys.argv[2:], stdin=slave, stdout=slave, stderr=slave, cwd=work,
                         start_new_session=True, close_fds=True)
os.close(slave)
with open(os.path.join(work, "child.pid"), "w") as f:
    f.write(str(child.pid))
with open(os.path.join(work, "output.log"), "wb", buffering=0) as out:
    while True:
        try:
            data = os.read(master, 4096)
        except OSError as e:
            if e.errno == errno.EIO:
                break
            raise
        if not data:
            break
        out.write(data)
code = child.wait()
# A stopped run has had its pid file taken away.
if os.path.exists(os.path.join(work, "child.pid")):
    with open(os.path.join(work, "exit.code"), "w") as f:
        f.write(str(code))
`;

const backends = {
	global: { program: '/usr/bin/globalspeedtest-go', install: GLOBAL_INSTALL },
	speedtest: { program: '/usr/bin/speedtest-go', install: SPEEDTEST_INSTALL }
};

let ctx;

function q(text) {
	return "'" + replace(`${text}`, /'/g, "'\\''") + "'";
}

function write_backend(id) {
	let c = ctx.uci();
	if (!stat('/etc/config/e5-plugin-speedtest')) writefile('/etc/config/e5-plugin-speedtest', '');
	if (c.get('e5-plugin-speedtest', 'settings') == null) c.set('e5-plugin-speedtest', 'settings', 'settings');
	c.set('e5-plugin-speedtest', 'settings', 'backend', id);
	c.commit('e5-plugin-speedtest');
	c.set('e5-infoscreen', 'main', 'speedtest_backend', id);
	c.commit('e5-infoscreen');
}

// Shared with the LVGL interface: the plugin's setting, else the screen's, copied
// into the plugin's so that its settings page does not show the manifest's default.
function read_backend() {
	let c = ctx.uci();
	let id = c.get('e5-plugin-speedtest', 'settings', 'backend');
	if (backends[id])
		return id;
	id = c.get('e5-infoscreen', 'main', 'speedtest_backend');
	id = backends[id] ? id : 'global';
	write_backend(id);
	return id;
}

function installed(id) {
	return stat(backends[id].program) != null;
}

function busy(phase) {
	return index(BUSY, phase) >= 0;
}

function blank() {
	return {
		backend: read_backend(), phase: 'IDLE', mode: null, offset: 0, pending: '',
		ping: 0, jitter: 0, download: 0, upload: 0, current: 0,
		isp: '', ip: '', sponsor: '', server: '',
		install_pct: 0, install_step: '', install_version: '', install_host: ''
	};
}

function read_state() {
	let saved = null;
	try {
		saved = json(readfile(DIR + '/state.json') ?? 'null');
	} catch (e) {}
	return type(saved) == 'object' && backends[saved.backend] ? saved : blank();
}

function save_state(state) {
	writefile(DIR + '/state.json', sprintf('%J\n', state));
	return state;
}

function number_after(line, key) {
	let at = index(line, key);
	let m = at >= 0 ? match(substr(line, at + length(key)), /^[ \t]*([0-9]+(\.[0-9]*)?)/) : null;
	return m ? +m[1] : null;
}

/* "[12687] 6.56km Singapore by SIMBA Telecom" -> "SIMBA Telecom", "Singapore";
 * "[2104002] 大连联通 (中国) by 联通" -> "联通", "大连联通" */
function parse_server(state, text) {
	let place = index(text, '] '), by = index(text, ' by ');
	if (place < 0 || by < place) {
		state.sponsor = text;
		return;
	}
	place += 2;
	let km = index(substr(text, place), 'km ');
	if (km >= 0 && place + km < by)
		place += km + 3;
	let country = index(substr(text, place), ' (');
	let end = country >= 0 && place + country < by ? place + country : by;
	state.sponsor = substr(text, by + 4);
	state.server = substr(text, place, end - place);
}

// False when the test is already past the stage: the program redraws its
// screen, so finished stages keep reappearing.
function reach(state, phase) {
	let at = index(PHASES, state.phase), target = index(PHASES, phase);
	if (at > target)
		return false;
	if (at < target)
		state.current = 0;
	state.phase = phase;
	return true;
}

function parse_line(state, line) {
	let s, v, final = index(line, 'Used:') >= 0;
	if ((s = index(line, 'ISP: ')) >= 0) {
		/* "ISP: 116.86.135.131 (StarHub) [lat, lon]" */
		let m = match(substr(line, s + 5), /^([^(]*) \(([^)]*)\)/);
		if (m) {
			state.ip = m[1];
			state.isp = m[2];
		}
	} else if (index(line, 'Switching to the next server') >= 0) {
		state.phase = 'CONNECTING';
		state.ping = state.jitter = state.download = state.upload = state.current = 0;
	} else if ((s = index(line, 'Test Server: ')) >= 0) {
		parse_server(state, substr(line, s + 13));
		reach(state, 'PING');
	} else if (index(line, 'Download') >= 0) {
		if (reach(state, 'DOWNLOAD') && (v = number_after(line, 'Download:')) != null) {
			if (final)
				state.download = v;
			state.current = v;
		}
	} else if (index(line, 'Upload') >= 0) {
		if (reach(state, 'UPLOAD') && (v = number_after(line, 'Upload:')) != null) {
			if (final)
				state.upload = v;
			state.current = v;
		}
	} else if ((s = index(line, 'Latency: ')) >= 0 && reach(state, 'PING')) {
		line = substr(line, s);
		state.ping = number_after(line, 'Latency: ') ?? 0;
		state.jitter = number_after(line, 'Jitter: ') ?? state.jitter;
	}
}

function parse_install_line(state, line) {
	let m;
	if (line == '@check' || line == '@update' || line == '@install') {
		state.install_step = substr(line, 1);
	} else if (line == '@add') {
		state.install_step = 'add';
		state.install_pct = 0;
	} else if ((m = match(line, /^@download ([^ ]+) ?([^ ]*)/))) {
		state.install_step = 'download';
		state.install_version = m[1];
		state.install_host = m[2];
		state.install_pct = 0;
	} else if ((m = match(line, /^[ \t]*([0-9]+)\/([0-9]+)/)) && +m[2]) {
		state.install_pct = int(+m[1] * 100 / +m[2]);
	} else if ((m = match(line, /([0-9.]+)%[^%]*$/))) {
		/* curl's bar ends "  42.3%"; uclient-fetch's has " 42% |". */
		state.install_pct = int(+m[1]);
	}
}

// What the program printed since the last request, a line at a time; lines
// end at a carriage return too, as redrawn lines do.
function read_output(state) {
	let log = readfile(DIR + '/output.log');
	if (log == null)
		return;
	let text = state.pending + substr(log, state.offset);
	state.offset = length(log);
	let lines = split(replace(text, /\r/g, '\n'), '\n');
	state.pending = pop(lines);
	for (let line in lines) {
		line = replace(line, /\x1b(\[[^A-Za-z]*[A-Za-z]|.)/g, '');
		if (state.phase == 'INSTALLING')
			parse_install_line(state, line);
		else if (length(line))
			parse_line(state, line);
	}
}

function clear_run() {
	for (let name in [ 'output.log', 'exit.code', 'child.pid' ])
		unlink(DIR + '/' + name);
}

function start(state, mode) {
	let b = backends[state.backend];
	state = { ...blank(), backend: state.backend, mode, phase: mode == 'install' ? 'INSTALLING' : 'CONNECTING' };
	clear_run();
	let command = mode == 'install' ? [ '/bin/sh', '-c', b.install ] : [ b.program ];
	if (ctx.run(`python3 ${q(DIR + '/runner.py')} ${q(DIR)} ${join(' ', map(command, q))} >/dev/null 2>&1 &`) != 0) {
		state.phase = 'FAILED';
		state.mode = 'start';
	}
	return save_state(state);
}

function poll_state() {
	mkdir('/tmp/run/e5-infoscreen', 0755);
	mkdir(DIR, 0700);
	if (readfile(DIR + '/runner.py') != RUNNER)
		writefile(DIR + '/runner.py', RUNNER);
	let state = read_state();
	if (!busy(state.phase)) {
		state.backend = read_backend();
		return state;
	}
	read_output(state);
	let code = readfile(DIR + '/exit.code');
	if (code == null)
		return save_state(state);
	code = int(code);
	if (state.mode == 'install') {
		if (code == 0 && installed(state.backend))
			return start(state, 'test');
		state.phase = 'FAILED';
	} else {
		state.phase = code == 0 && state.download > 0 ? 'DONE' : 'FAILED';
	}
	return save_state(state);
}

function stop(state) {
	let pid = trim(readfile(DIR + '/child.pid') ?? '');
	if (match(pid, /^[0-9]+$/))
		ctx.run(`kill -KILL -${pid} 2>/dev/null`);
	clear_run();
	return save_state({ ...blank(), backend: state.backend });
}

function status(state) {
	return {
		installed: installed(state.backend),
		phase: state.phase,
		// What failed: 'install', 'test', or 'start' when the program could not be run.
		failed: state.phase == 'FAILED' ? state.mode : null,
		backend: state.backend,
		isp: state.isp,
		ip: state.ip,
		sponsor: state.sponsor,
		server: state.server,
		ping_ms: state.ping,
		jitter_ms: state.jitter,
		download_mbps: state.download,
		upload_mbps: state.upload,
		current_mbps: state.current,
		install_pct: state.install_pct,
		install_step: state.install_step,
		install_version: state.install_version,
		install_host: state.install_host
	};
}

function fail(error, code) {
	return { status: code, type: 'application/json', body: sprintf('%J', { ok: false, error }) };
}

return function(context) {
	ctx = context;
	return {
		'GET /status': function() {
			return status(poll_state());
		},
		// The test; without its program, the install the user has agreed to.
		'POST /start': function(req) {
			let state = poll_state();
			if (busy(state.phase))
				return fail('busy', 409);
			if (installed(state.backend))
				return status(start(state, 'test'));
			if (req?.body?.install !== true)
				return fail('not installed', 409);
			return status(start(state, 'install'));
		},
		'POST /stop': function() {
			return status(stop(poll_state()));
		},
		'POST /reset': function() {
			let state = poll_state();
			return status(busy(state.phase) ? state : save_state(blank()));
		},
		'POST /backend': function(req) {
			let id = req?.body?.backend;
			if (!backends[id])
				return fail('invalid backend', 400);
			if (busy(poll_state().phase))
				return fail('busy', 409);
			write_backend(id);
			return status(save_state(blank()));
		}
	};
};
