// 天气插件的后端：定位 + 拉天气数据 + 缓存。
//
// 数据源是小米天气的公开接口：
//   /wtr-v3/location/city/geo    经纬度 -> locationKey（区县级）
//   /wtr-v3/weather/all          天气全部数据
// appKey 和 sign 是固定值，不需要申请、不需要登录。
//
// 定位用 ip-api.com（免费，45 次/分钟）。拿不到就用上次缓存的位置，
// 实在没有就退到北京 —— 总比白屏强。

'use strict';

const fs = require('fs');

// backend.uc 的导出是一个 function(ctx)，ctx 只在那个闭包里有效。
// 我们的辅助函数都写在顶层（方便阅读），所以把 ctx 存一份给它们用。
let ctxRef = null;

const BASE = 'https://weatherapi.market.xiaomi.com';
const APP_KEY = 'weather20151024';
const SIGN = 'zUFJoAR2ZVrVfjdw2H+dNQ==';
const UA = 'MIUI-Weather';

const STATE = '/tmp/cx-weather-state.txt';     // 位置 + 上次的天气
const TTL_WEATHER = 1800;                       // 30 分钟
const TTL_LOC = 86400;                          // 位置一天

// 执行 shell 命令。必须用 ctx.sh —— uhttpd 给后端脚本的接口。
// fs.popen 在这台机器的 ucode 上拿不到可读句柄（read() 会报
// "left-hand side is not a function"），而且 ctx 只存在于下面那个闭包里，
// 所以走 ctxRef。
function sh(cmd) {
	if (ctxRef == null) return '';
	return ctxRef.sh(cmd) ?? '';
}

// ucode 的 json() 在解析失败时会**抛异常**，不是返回 null。
// 后端里任何一次网络抖动都可能喂进一段 HTML，所以统一走这里。
function safeJson(text) {
	try { return json(text ?? 'null'); } catch (e) { return null; }
}

function httpGet(url, timeout) {
	let t = timeout ?? 15;
	return sh(`curl -s -m ${t} -H 'User-Agent: ${UA}' '${url}' 2>/dev/null`) ?? '';
}

// ucode 没有内置的 kv 存储，自己拼一个最简单的：每行 key=value
function kvRead(file) {
	let out = {};
	let raw = '';
	try { raw = fs.readfile(file) ?? ''; } catch (e) { raw = ''; }
	for (let line in split(raw, '\n')) {
		line = trim(line);
		if (length(line) < 3) continue;
		let i = index(line, '=');
		if (i <= 0) continue;
		out[substr(line, 0, i)] = substr(line, i + 1);
	}
	return out;
}

function kvWrite(file, obj) {
	let lines = [];
	for (let k in keys(obj)) {
		// 值里可能有换行（缓存的 JSON），编码掉，读的时候再还原
		push(lines, `${k}=${replace(`${obj[k]}`, /\n/g, '\\n')}`);
	}
	try { fs.writefile(file, join('\n', lines) + '\n'); } catch (e) { }
}

function kvGet(obj, k, def) {
	let v = obj[k];
	if (v == null) return def;
	return replace(v, /\\n/g, '\n');
}

// 定位。同一个 IP（39.144.196.111）三家给的答案：
//   ip-api.com     广东广州   23.13,113.27   ← 差三千多公里，中国移动的库没跟上
//   ipinfo.io      新疆乌鲁木齐 43.80,87.60  ← 只到运营商注册的大区中心
//   myip.ipip.net  新疆昌吉回族自治州          ← 最准，但是纯文本没坐标
// 所以：先用 myip 拿中文地名（准），再拿这个名字去小米的 city/search 换
// locationKey 和坐标（小米那边坐标是准的，天气也是按它取的）。
function locate() {
	let txt = httpGet('http://myip.ipip.net', 8);
	let m = match(txt ?? '', /来自于[：:]\s*([^\n\r]+)/);
	let cityName = '';
	let region = '';
	if (m != null) {
		// "中国 新疆 昌吉回族自治州  移动" -> 去掉国家和运营商
		let seg = trim(replace(m[1], /移动|联通|电信|铁通|广电|教育网/g, ''));
		let parts = [];
		for (let x in split(seg, ' ')) {
			x = trim(x);
			if (length(x) > 1) push(parts, x);
		}
		if (length(parts) >= 2) { region = parts[0]; cityName = parts[1]; }
		else if (length(parts) == 1) cityName = parts[0];
	}
	// 兜底：myip 挂了就用 ipinfo 的经纬度
	if (length(cityName) < 1) {
		let d = safeJson(httpGet('https://ipinfo.io/json', 10));
		if (d != null && d.loc != null) {
			let p2 = split(`${d.loc}`, ',');
			if (length(p2) >= 2)
				return { city: `${d.city ?? ''}`, region: `${d.region ?? ''}`,
					lat: trim(p2[0]), lon: trim(p2[1]) };
		}
		return null;
	}
	// "昌吉回族自治州" -> "昌吉"：小米那边按简称能搜到
	let short = replace(cityName,
		/回族自治州|蒙古自治州|哈萨克自治州|柯尔克孜自治州|傣族景颇族自治州|藏族自治州|彝族自治州|苗族侗族自治州|布依族苗族自治州|土家族苗族自治州|白族自治州|傣族自治州|傈僳族自治州|哈尼族彝族自治州|壮族苗族自治州|地区|自治州|自治区|省|市$/g, '');
	if (length(short) < 1) short = cityName;
	return { city: cityName, region: region, lat: '', lon: '', shortName: short };
}

// 经纬度 -> locationKey（精确到区县）
function cityByGeo(lat, lon) {
	let url = `${BASE}/wtr-v3/location/city/geo?latitude=${lat}&longitude=${lon}` +
		`&locale=zh_cn&appKey=${APP_KEY}&sign=${SIGN}`;
	let d = safeJson(httpGet(url, 12));
	if (type(d) != 'array' || length(d) < 1) return null;
	let c = d[0];
	if (!c || !c.locationKey) return null;
	return {
		key: `${c.locationKey}`,
		name: `${c.name ?? ''}`,
		affiliation: `${c.affiliation ?? ''}`,
		lat: `${c.latitude ?? lat}`,
		lon: `${c.longitude ?? lon}`
	};
}

// 按名字搜城市。返回可能多条（同名区县，比如朝阳区在北京和长春都有），
// 靠 affiliation 区分。
function searchCity(name) {
	// 中文不能直接拼进 URL：curl 对非 ASCII 的处理取决于 locale，
	// 这台机器上会直接把请求打歪。用 -G --data-urlencode 让 curl 编码。
	let safe = replace(name, /'/g, '');
	let sh_cmd = `curl -s -G -m 12 -H 'User-Agent: ${UA}'` +
		` --data-urlencode 'name=${safe}'` +
		` --data-urlencode 'locale=zh_cn'` +
		` --data-urlencode 'appKey=${APP_KEY}'` +
		` --data-urlencode 'sign=${SIGN}'` +
		` '${BASE}/wtr-v3/location/city/search' 2>/dev/null`;
	let d = safeJson(sh(sh_cmd));
	if (type(d) != 'array') return [];
	let out = [];
	for (let x in d) {
		push(out, {
			key: `${x.locationKey ?? ''}`,
			name: `${x.name ?? ''}`,
			affiliation: `${x.affiliation ?? ''}`,
			lat: `${x.latitude ?? ''}`,
			lon: `${x.longitude ?? ''}`
		});
	}
	return out;
}

// 城市名 -> locationKey + 坐标（定位用 myip 拿到名字之后走这里）
function cityByName(name) {
	let list = searchCity(name);
	if (length(list) == 0) return null;
	let c = list[0];
	return {
		key: c.key,
		name: c.name,
		affiliation: c.affiliation,
		lat: c.lat,
		lon: c.lon
	};
}


// 一次拿全部：当前 + 逐小时 + 逐日 + 空气质量 + 生活指数
function fetchWeather(locationKey, lat, lon) {
	let url = `${BASE}/wtr-v3/weather/all?latitude=${lat}&longitude=${lon}` +
		`&isLocated=true&locationKey=${replace(locationKey, ':', '%3A')}` +
		`&days=15&appKey=${APP_KEY}&locale=zh_cn&isGlobal=false&sign=${SIGN}`;
	return httpGet(url, 20);
}

// 取当前位置（缓存一天）
function currentPlace(force) {
	let st = kvRead(STATE);
	let now = time();
	if (!force) {
		let t = int(kvGet(st, 'loc_t', '0'));
		let key = kvGet(st, 'loc_key', '');
		if (t > 0 && now - t < TTL_LOC && length(key) > 4) {
			return { key: key, name: kvGet(st, 'loc_name', ''), affiliation: kvGet(st, 'loc_aff', ''), cached: 1 };
		}
	}
	let loc = locate();
	if (loc == null) {
		// 定位失败：用上次的
		let key = kvGet(st, 'loc_key', '');
		if (length(key) > 4)
			return { key: key, name: kvGet(st, 'loc_name', ''), affiliation: kvGet(st, 'loc_aff', ''), stale: 1 };
		return null;
	}
	// 优先按名字换（myip 给的中文地名比坐标准）；
	// 名字换不到再用坐标（ipinfo 兜底那条路会给经纬度）。
	let city = null;
	if (length(`${loc.shortName ?? ''}`) > 1) city = cityByName(loc.shortName);
	if (city == null && length(loc.lat) > 2) city = cityByGeo(loc.lat, loc.lon);
	if (city == null) {
		let key = kvGet(st, 'loc_key', '');
		if (length(key) > 4)
			return { key: key, name: kvGet(st, 'loc_name', ''), affiliation: kvGet(st, 'loc_aff', ''), stale: 1 };
		return null;
	}
	st['loc_t'] = `${now}`;
	st['loc_key'] = city.key;
	st['loc_name'] = city.name;
	st['loc_aff'] = city.affiliation;
	st['loc_lat'] = loc.lat;
	st['loc_lon'] = loc.lon;
	kvWrite(STATE, st);
	return { key: city.key, name: city.name, affiliation: city.affiliation, cached: 0 };
}

return function(ctx) {
	ctxRef = ctx;

	return {
	// 天气主接口。force=1 跳过缓存（下拉刷新用）
	// 读信息屏的主题设置：ui_theme 是 dark/light，ui_accent 是 blue/violet 这类预设名
	'GET /theme': function(req) {
		let t = trim(sh(`uci -q get e5-infoscreen.main.ui_theme 2>/dev/null`) ?? '');
		let a = trim(sh(`uci -q get e5-infoscreen.main.ui_accent 2>/dev/null`) ?? '');
		return { ok: true, theme: length(t) > 0 ? t : 'dark', accent: length(a) > 0 ? a : 'blue' };
	},

	// 诊断用：看 state 实际读出来什么
	'GET /debug': function(req) {
		let st = kvRead(STATE);
		let out = {};
		for (let k in keys(st)) {
			let v = `${st[k]}`;
			out[k] = (length(v) > 60) ? (substr(v, 0, 60) + '...len=' + length(v)) : v;
		}
		return { ok: true, keys: keys(st), w_t_raw: `${st['w_t'] ?? 'MISSING'}`,
			w_t_int: int(st['w_t'] ?? '0'), now: time(), state: out };
	},

	'GET /weather': function(req) {
		let force = int((req.query ? req.query.force : 0) ?? 0) == 1;
		let st = kvRead(STATE);
		let now = time();

		// 缓存还在就直接返回，别每次都打小米的接口
		if (!force) {
			let t = int(kvGet(st, 'w_t', '0'));
			let raw = kvGet(st, 'w_raw', '');
			if (t > 0 && now - t < TTL_WEATHER && length(raw) > 100) {
				return {
					ok: true, cached: 1, age: now - t, fetchedAt: t,
					place: kvGet(st, 'w_place', ''),
					affiliation: kvGet(st, 'w_aff', ''),
					data: safeJson(raw)
				};
			}
		}

		let place = currentPlace(false);
		if (place == null) return { ok: false, error: '定位失败，检查一下网络' };

		// 空字符串也要兜底：kvGet 只在 key 不存在时给默认值，
		// 而 loc_lat 可能是存在但为空（早期版本写进去的）。
		let lat = kvGet(st, 'loc_lat', '');
		let lon = kvGet(st, 'loc_lon', '');
		if (length(lat) < 2) lat = '43.8';
		if (length(lon) < 2) lon = '87.6';
		let raw = fetchWeather(place.key, lat, lon);
		let d = safeJson(raw);
		if (d == null || type(d) != 'object' || d.current == null) {
			// 拉不到就用上次的数据（标记 stale，前端可以显示"数据较旧"）
			let old = kvGet(st, 'w_raw', '');
			let od = safeJson(old);
			if (od != null)
				return {
					ok: true, cached: 1, stale: 1, age: now - int(kvGet(st, 'w_t', '0')),
					fetchedAt: int(kvGet(st, 'w_t', '0')),
					// 地名用当前定位的，别用缓存里的 —— 刚切了城市但拉取失败时，
					// 显示新城市名 + 旧城市数据，比直接显示旧城市更不容易让人困惑
					place: place.name,
					affiliation: place.affiliation,
					data: od
				};
			return { ok: false, error: '天气数据没取到' };
		}

		st['w_t'] = `${now}`;
		st['w_raw'] = raw;
		st['w_place'] = place.name;
		st['w_aff'] = place.affiliation;
		kvWrite(STATE, st);

		return { ok: true, cached: 0, fetchedAt: now,
			place: place.name, affiliation: place.affiliation, data: d };
	},

	// 搜索城市（前端选城市时用）
	'GET /search': function(req) {
		let name = `${(req.query ? req.query.name : '') ?? ''}`;
		if (length(name) < 1) return { ok: false, error: '要搜什么' };
		return { ok: true, list: searchCity(name) };
	},

	// 手动指定城市。name 是区县/市名，aff 用来在重名里挑对的那个
	'GET /setcity': function(req) {
		let name = `${(req.query ? req.query.name : '') ?? ''}`;
		let aff = `${(req.query ? req.query.aff : '') ?? ''}`;
		if (length(name) < 1) return { ok: false, error: '城市名为空' };
		let list = searchCity(name);
		if (length(list) == 0) return { ok: false, error: '没找到这个城市' };

		let pick = list[0];
		if (length(aff) > 1) {
			// 重名：挑 affiliation 里含目标市名的那条
			for (let c in list) {
				if (index(`${c.affiliation}`, aff) >= 0) { pick = c; break; }
			}
		}

		let st = kvRead(STATE);
		st['loc_key'] = pick.key;
		st['loc_name'] = pick.name;
		st['loc_aff'] = pick.affiliation;
		// 经纬度必须一起写：weather/all 要它们，空着会被小米接口拒掉
		st['loc_lat'] = `${pick.lat ?? ''}`;
		st['loc_lon'] = `${pick.lon ?? ''}`;
		st['loc_t'] = `${time()}`;
		// 缓存连同旧地名一起清：不清的话失败兜底会拿出上一个城市的名字
		st['w_t'] = '0';
		st['w_place'] = '';
		st['w_aff'] = '';
		st['w_raw'] = '';
		kvWrite(STATE, st);
		return { ok: true, place: pick.name, affiliation: pick.affiliation };
	},

	// 回到自动定位
	'GET /autolocate': function(req) {
		let st = kvRead(STATE);
		st['loc_t'] = '0';
		st['w_t'] = '0';
		kvWrite(STATE, st);
		let place = currentPlace(true);
		if (place == null) return { ok: false, error: '定位失败' };
		return { ok: true, place: place.name, affiliation: place.affiliation };
	}
};
};
