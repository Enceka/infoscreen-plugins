// 网易云 eapi 请求器（ucode 版，加密仍交给 openssl）
//
// 算法（来自 mygo-cloudmusic/egoist internal/netease/eapi.go）：
//   key    = "e82ckenh8dichen8"    AES-128-ECB，固定密钥
//   明文    = path + "-36cd479b6b5-" + json + "-36cd479b6b5-" +
//            md5("nobody" + path + "use" + json + "md5forencrypt")
//   params = 大写十六进制(AES-128-ECB(PKCS7(明文)))
//
// 原来这段在 eapi.py 里（python3 + openssl）。应用商店只收 .uc/.html/... 不收 .py，
// 所以搬到这里。AES 还是走 openssl，只是编排从 python 换成 ucode。

'use strict';

const fs = require('fs');

const EAPI_KEY = 'e82ckenh8dichen8';
const EAPI_KEY_HEX = '653832636b656e683864696368656e38';   // 上面那串的十六进制
const EAPI_DOMAIN = 'https://interfacepc.music.163.com';
const UA = 'NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)';
const DEVICE_FILE = '/etc/e5-infoscreen/plugins/netease/device-id';
const TMP_IN = '/tmp/cx-eapi-in.bin';

// 独立脚本里没有 backend 的 ctx，用 fs.popen 跑命令
function sh(cmd) {
	let f = fs.popen(cmd, 'r');
	if (!f) return '';
	let out = f.read('all');
	f.close();
	return out ?? '';
}
const TMP_OUT = '/tmp/cx-eapi-out.bin';

// ---- 紧凑 JSON ----
// ucode 的 %J 会输出 "{ "a": 1 }" 这种带空格的格式，而 eapi 的 md5 是对
// 紧凑文本算的，多一个空格就校验不过，所以自己拼。
function jsonStr(s) {
	let out = '';
	for (let i = 0; i < length(s); i++) {
		let c = ord(substr(s, i, 1));
		if (c == 34) out += '\\"';
		else if (c == 92) out += '\\\\';
		else if (c == 10) out += '\\n';
		else if (c == 13) out += '\\r';
		else if (c == 9) out += '\\t';
		else if (c == 8) out += '\\b';
		else if (c == 12) out += '\\f';
		else if (c < 32) out += sprintf('\\u%04x', c);
		else out += chr(c);
	}
	return '"' + out + '"';
}

function jsonCompact(v) {
	let t = type(v);
	if (t == 'object') {
		let parts = [];
		for (let k in keys(v)) push(parts, jsonStr(k) + ':' + jsonCompact(v[k]));
		return '{' + join(',', parts) + '}';
	}
	if (t == 'array') {
		let parts = [];
		for (let x in v) push(parts, jsonCompact(x));
		return '[' + join(',', parts) + ']';
	}
	if (t == 'string') return jsonStr(v);
	if (t == 'bool') return v ? 'true' : 'false';
	if (t == 'int') return sprintf('%d', v);
	if (t == 'double') {
		// python 对整数值的 float 输出不带小数点，这里跟着来
		let d = sprintf('%d', v);
		return d;
	}
	return 'null';
}

// ---- 基础 ----
function md5hex(text) {
	fs.writefile(TMP_IN, text);
	return trim(sh(`openssl dgst -md5 -r '${TMP_IN}' 2>/dev/null | cut -d' ' -f1`) ?? '');
}

// 明文 -> 大写 hex 密文
function aesEcbHex(text) {
	let pad = 16 - (length(text) % 16);
	let data = text;
	for (let i = 0; i < pad; i++) data += chr(pad);
	fs.writefile(TMP_IN, data);
	// 命令必须写成一行：模板字符串里的 "\\" 续行在这版 ucode 上会把命令拆坏
	let rc = sh(`openssl enc -aes-128-ecb -K '${EAPI_KEY_HEX}' -nosalt -nopad -in '${TMP_IN}' -out '${TMP_OUT}' 2>/dev/null; echo $?`);
	if (trim(rc ?? '1') != '0') return '';
	let out = '';
	try { out = fs.readfile(TMP_OUT); } catch (e) { return ''; }
	return uc(hexenc(out));
}

// ---- 设备号 ----
// NetEase 会认它见过的设备，所以持久化一个 52 位十六进制串
function deviceId() {
	let v = '';
	try { v = trim(fs.readfile(DEVICE_FILE) ?? ''); } catch (e) { v = ''; }
	if (length(v) == 52) return v;
	v = trim(sh(`od -An -tx1 -N26 /dev/urandom 2>/dev/null | tr -d ' \\n' | tr 'a-f' 'A-F'`) ?? '');
	if (length(v) != 52) v = sprintf('%052d', 0);
	sh(`mkdir -p /etc/e5-infoscreen/plugins/netease 2>/dev/null`);
	try { fs.writefile(DEVICE_FILE, v); } catch (e) { /* ignore */ }
	return v;
}

// ---- 加密 ----
function encrypt(path, payload) {
	let text = jsonCompact(payload);
	let digest = md5hex('nobody' + path + 'use' + text + 'md5forencrypt');
	let plain = path + '-36cd479b6b5-' + text + '-36cd479b6b5-' + digest;
	return aesEcbHex(plain);
}

// ---- 请求 ----
// req: { path, data, cookie }  ->  { ok, body, set_cookie, http }
function call(req) {
	let path = req.path ?? '';
	let data = req.data ?? {};
	let cookie = req.cookie ?? '';

	let header = {
		osver: 'Microsoft-Windows-10-Professional-build-19045-64bit',
		deviceId: deviceId(),
		os: 'pc',
		appver: '3.1.17.204416',
		versioncode: '140',
		mobilename: '',
		buildver: sprintf('%d', time()),
		resolution: '1920x1080',
		channel: 'netease',
		requestId: sprintf('%d_%04d', time() * 1000, (time() * 1000) % 1000),
		__csrf: ''
	};
	// 会话 cookie 同时进 header（客户端就是这么带的）
	for (let part in split(cookie ?? '', ';')) {
		let p = trim(part);
		if (length(p) < 1 || index(p, '=') <= 0) continue;
		let k = substr(p, 0, index(p, '='));
		let v = substr(p, index(p, '=') + 1);
		if (k == 'MUSIC_U' || k == 'NMTID' || k == '__csrf') header[k] = v;
	}

	data.header = header;
	data.e_r = false;
	let text = jsonCompact(data);
	let digest = md5hex('nobody' + path + 'use' + text + 'md5forencrypt');
	let plain = path + '-36cd479b6b5-' + text + '-36cd479b6b5-' + digest;
	let params = aesEcbHex(plain);
	if (length(params) < 16)
		return { ok: false, error: 'encrypt failed',
			dbg: { textLen: length(text), digest: digest, plainLen: length(plain),
				paramsLen: length(params), json: substr(text, 0, 120) } };

	let url = (substr(path, 0, 5) == '/api/')
		? EAPI_DOMAIN + '/eapi/' + substr(path, 5)
		: EAPI_DOMAIN + '/eapi/' + path;

	let ckParts = [];
	for (let k in keys(header)) push(ckParts, k + '=' + header[k]);
	let ck = join('; ', ckParts);

	// 把 params 写文件再 --data-urlencode 读，避免命令行过长
	fs.writefile('/tmp/cx-eapi-params.txt', 'params=' + params);
	// 偶发拿不到东西（DNS 抖动、连接被重置），表现为空 body，
	// 上层看到的就是"每日推荐返回异常"。重试两次，间隔 0.4 / 0.8 秒。
	let body = '';
	for (let attempt = 0; attempt < 3; attempt++) {
		if (attempt > 0) sleep(attempt * 400);
		body = sh(`curl -s -m 20 -X POST -H 'User-Agent: ${UA}' -H 'Cookie: ${ck}' -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode 'params=${params}' -D /tmp/cx-eapi-headers '${url}' 2>/dev/null`) ?? '';
		if (length(trim(body)) > 2) break;
	}

	let out = { ok: true, body: null, set_cookie: [], http: 0 };
	let parsed = null;
	try { parsed = json(body); } catch (e) { parsed = null; }
	if (parsed == null && length(trim(body ?? '')) > 0) {
		// 不是 JSON：把开头一小段带回去，好判断是风控页、截断还是空响应
		out.error = 'non-json: ' + substr(trim(body), 0, 120);
		out.raw_len = length(body);
	}
	out.body = parsed;

	// Set-Cookie 里捞 MUSIC_U / __csrf
	let heads = '';
	try { heads = fs.readfile('/tmp/cx-eapi-headers') ?? ''; } catch (e) { heads = ''; }
	for (let line in split(heads, '\n')) {
		let low = lc(line);
		if (substr(low, 0, 11) != 'set-cookie:') continue;
		let kv = trim(substr(line, 11));
		kv = substr(kv, 0, index(kv, ';') > 0 ? index(kv, ';') : length(kv));
		if (index(kv, '=') <= 0) continue;
		let k = substr(kv, 0, index(kv, '='));
		let v = substr(kv, index(kv, '=') + 1);
		if (k == 'MUSIC_U' || k == '__csrf' || k == 'NMTID')
			push(out.set_cookie, { name: k, value: v });
	}
	return out;
}

// ---- 入口 ----
// 和原来的 eapi.py 一样：stdin 读一行 JSON，stdout 写一行 JSON。
// 这样 backend.uc 那边不用改调用方式，仍然是
//   printf '%s' '<json>' | ucode eapi.uc
function main() {
	let raw = trim(fs.stdin.read('all') ?? '');
	let req = null;
	try { req = json(raw); } catch (e) { req = null; }
	if (type(req) != 'object')
		return { ok: false, error: 'bad input' };
	try {
		return call(req);
	} catch (e) {
		return { ok: false, error: 'eapi failed: ' + e };
	}
}

print(sprintf('%J', main()), '\n');
