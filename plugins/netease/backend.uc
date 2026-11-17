// 网易云音乐插件的后端：搜索、歌曲详情、下载缓存、以及**在本机播放**。
//
// 为什么播放放在后端，而不是浏览器里的 <audio>：
//   WebKit(WPE) 建音频管线时依赖 GStreamer 的 scaletempo 元素，OpenWrt 的仓库里
//   没有这个包（gst1-mod-scaletempo 不存在），设备又是 musl、没有可用的交叉工具链
//   自己编。缺了它管线直接建不起来，前端只会拿到 MediaError code=4。
//   而 mpg123 / gst-launch playbin 在本机直接跑是正常的（实测有声音），
//   所以改成后端起播放进程，前端只负责界面和状态。
//
// 用到的网易云接口（都不需要 eapi/weapi 加密）：
//   GET /api/search/get/web?s=<kw>&type=1&limit=30&offset=0
//   GET /api/song/detail/?ids=[<id>]        要 URL 编码成 %5B<id>%5D
//   GET /song/media/outer/url?id=<id>.mp3   302 到 CDN
//
// 关键词拼进 shell 前过白名单，避免命令注入。
// 刻意避开可选链 `?.` 和 import 'fs' —— 这台机器的 ucode 版本行为没验证过。

'use strict';

const BASE = 'https://music.163.com';
const UA = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36';
// uhttpd 的根是 /usr/share/e5-infoscreen/www，cache 对外就是
// /plugins/netease/cache/<id>.mp3
const CACHE = '/usr/share/e5-infoscreen/www/plugins/netease/cache';
// 缓存实体放在插件目录**外面**：plugin install 会 rm -rf 整个 netease 目录，
// 放里面的话每装一次插件封面就全没了（歌单/收藏/歌手页一片空白）。
// cache 这个名字仍然保留为软链，URL 前缀 /plugins/netease/cache/ 不用改。
const CACHE_REAL = '/etc/e5-infoscreen/plugins/netease-cache';
const CACHE_MAX = 20;
const MIN_BYTES = 20000;       // 小于这个基本是错误页或试听碎片
const PIDFILE = '/tmp/netease-player.pid';
// 播放状态：页面退出重进时前端靠它恢复界面（播放进程本身不随页面走）
const STATE = '/tmp/netease-state.txt';
const VOLUME = '/usr/libexec/e5-volume';   // 宿主自己的音量工具（uci + pactl 一起改）
const EAPI = '/usr/libexec/cx-eapi';      // eapi 加密请求器（python3 + openssl）
// 包里自带一份，换设备装完插件就能用，不必另外拷 cx-eapi。优先用自带的。
const EAPI_BUNDLED = '/etc/e5-infoscreen/plugins/netease/eapi.py';
let eapiCommand = null;   // 只探一次

// 会话 cookie 放在插件目录**之外** —— 插件目录是软链进 www 的，放里面会被 web 直接读到
const SESSION = '/etc/e5-infoscreen/netease.session';
// 登录后由后端记下 uid —— 前端传的 uid 不可信, 换号后容易查错人
const UIDFILE = '/etc/e5-infoscreen/netease.uid';
// 会员状态（/login/me 时写），后台续播要用它判断 VIP 歌能不能放
const VIPFILE = '/tmp/netease-vip.txt';
// 当前列表的来源：页面随时会被关掉（息屏就关），续播不能靠前端
const PLAN = '/tmp/netease-plan.txt';
// 已喜欢的 id 列表缓存（一次拉全量，10 分钟内复用）和"不喜欢"的本地黑名单
const LIKED = '/tmp/netease-liked.txt';

return function(ctx) {
	// 所有走这里的请求都带会话 Cookie。匿名请求会被接口限流：
	//   {"code":405,"message":"操作频繁，请稍候再试"}
	// 表现就是"有概率"取不到歌单详情 —— 封面空、歌手空、VIP 判断错，
	// 全是这一条引起的。用 $(cat SESSION) 而不是 readSession()，因为 curl
	// 定义得比它早（ucode 不能前向引用）。
	function curl(extra) {
		let out = ctx.sh(`curl -s -m 15 -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' -H "Cookie: $(cat '${SESSION}' 2>/dev/null)" ${extra} 2>/dev/null`);
		return out ?? '';
	}

	let fs = require('fs');   // 写歌单 id 缓存要用

	// 用 shell 取文件大小（不用 stat()：backend.uc 是按脚本加载的）
	function sizeOf(file) {
		// 注意: stat 失败时输出是空串, int('') 会得到 NaN, 而 NaN < 2000 是 false,
		// 会让"文件不存在就去下载"的判断整个失效。所以这里让 shell 兜底输出 0。
		let out = ctx.sh(`[ -f '${file}' ] && stat -c %s '${file}' 2>/dev/null || echo 0`);
		let s = trim(out ?? '0');
		return length(s) > 0 ? int(s) : 0;
	}

	function safeKeyword(s) {
		if (s == null) return '';
		let t = replace(`${s}`, /[^0-9A-Za-z\u4e00-\u9fa5 _-]/g, '');
		t = trim(t);
		if (length(t) > 40) t = substr(t, 0, 40);
		return t;
	}

	function artistText(song) {
		let list = song.artists;
		if (type(list) != 'array') return '';
		let names = [];
		for (let a in list) {
			let n = a.name;
			if (n != null) push(names, n);
		}
		return join(' / ', names);
	}

	function albumOf(song) {
		let al = song.album;
		if (al == null || type(al) != 'object') return { name: '', cover: null };
		return { name: al.name ?? '', cover: al.picUrl ?? null };
	}

	// 音频放哪：默认和封面在一起（web root 下），但只读 web root 的机型
	// 可以用 `uci set e5-infoscreen.main.netease_audio=/tmp/netease-cache` 指到别处。
	// 封面必须留在 web root —— 浏览器要从 /plugins/netease/cache/... 取图。
	let audioDir = null;
	function aud() {
		if (audioDir == null) {
			let want = trim(ctx.sh(`uci -q get e5-infoscreen.main.netease_audio 2>/dev/null`) ?? '');
			audioDir = length(want) > 0 ? want : CACHE;
			ctx.sh(`mkdir -p '${audioDir}' 2>/dev/null`);
		}
		return audioDir;
	}

	function pruneCache() {
		let dir = aud();
		let mp3 = [];
		for (let line in split(trim(ctx.sh(`ls -1t '${dir}' 2>/dev/null`) ?? ''), '\n')) {
			let f = trim(line);
			if (length(f) > 0 && match(f, '.mp3')) push(mp3, f);
		}
		let img = [];
		for (let line in split(trim(ctx.sh(`ls -1t '${CACHE}' 2>/dev/null`) ?? ''), '\n')) {
			let f = trim(line);
			if (length(f) > 0 && !match(f, '.mp3')) push(img, f);
		}
		// 音频按 CACHE_MAX 清；封面（含预取的）单独给个上限，
		// 否则一次预取 6 张就会把正在放的歌挤出去
		for (let i = CACHE_MAX; i < length(mp3); i++)
			ctx.sh(`rm -f '${dir}/${mp3[i]}' 2>/dev/null`);
		for (let i = 240; i < length(img); i++)
			ctx.sh(`rm -f '${CACHE}/${img[i]}' 2>/dev/null`);
	}

	// 把歌准备好（下载到缓存），返回本地路径；失败返回 null
	function playerPid() {
		let raw = trim(ctx.sh(`cat '${PIDFILE}' 2>/dev/null`) ?? '');
		return int(raw ?? '0') ?? 0;
	}

	// 给整条播放管道的每个进程发信号
	function signalAll(sig) {
		ctx.sh(`for p in $(pgrep mpg123) $(pgrep pacat); do kill -${sig} $p 2>/dev/null; done`);
	}

	// ---- 会话 ----
	function readSession() {
		let v = trim(ctx.sh(`cat '${SESSION}' 2>/dev/null`) ?? '');
		// 只留安全字符，避免拼进 shell 出问题
		return replace(v, /[^A-Za-z0-9_%=; .-]/g, '');
	}

	function saveSession(pairs) {
		let v = replace(pairs, /[^A-Za-z0-9_%=; .-]/g, '');
		if (length(v) < 1) return;
		ctx.sh(`umask 077; printf '%s' '${v}' > '${SESSION}' 2>/dev/null`);
	}

	function readUid() {
		return int(trim(ctx.sh(`cat '${UIDFILE}' 2>/dev/null`) ?? '0') ?? 0);
	}

	function writeUid(uid) {
		ctx.sh(`umask 077; printf '%s' '${int(uid)}' > '${UIDFILE}' 2>/dev/null`);
	}

	// ---- eapi ----
	// 把 {"path","data","cookie"} 通过管道喂给 cx-eapi，返回它解析后的 JSON。
	// dataJson 必须是我们自己拼的、只含数字/字母/冒号的字符串。
	// eapi 加密器：优先用插件自带的 eapi.uc（商店只收 .uc，不收 .py），
	// 没有才退回 python 版。两者输入输出完全一样（stdin 一行 JSON）。
	function eapiTool() {
		if (eapiCommand == null) {
			let ucPath = '/etc/e5-infoscreen/plugins/netease/eapi.uc';
			if (length(ctx.sh(`[ -f '${ucPath}' ] && echo yes`) ?? '') > 0)
				eapiCommand = `ucode '${ucPath}'`;
			else if (length(ctx.sh(`[ -f '${EAPI_BUNDLED}' ] && echo yes`) ?? '') > 0)
				eapiCommand = `/usr/bin/python3 '${EAPI_BUNDLED}'`;
			else
				eapiCommand = EAPI;
		}
		return eapiCommand;
	}

	// eapi 的返回可能很大（每日推荐 91 KB / 歌单详情几十 KB），
	// 用 ctx.sh() 捕获子进程输出会被截断 —— 截断后 json() 解析失败，
	// 外面就只看到"空列表"或"返回异常"。这就是"偶尔加载失败"的真凶：
	// 数据一大就中招。改成让它写文件，再整份读回来。
	function eapiCall(path, dataJson, cookie) {
		let ck = replace(cookie ?? '', /[^A-Za-z0-9_%=; .-]/g, '');
		let req = sprintf('{"path":"%s","data":%s,"cookie":"%s"}', path, dataJson, ck);
		// 临时文件名必须每进程唯一：status 每 500ms 一次，多个请求撞名时
		// A 正在写、B 读到的就是半个文件，json() 失败 → "返回异常"。
		let tmp = trim(ctx.sh(`mktemp /tmp/cx-eapi-XXXXXX.json 2>/dev/null`) ?? '');
		if (length(tmp) < 5) tmp = '/tmp/cx-eapi-fallback.json';
		ctx.sh(`printf '%s' '${req}' | ${eapiTool()} > '${tmp}' 2>/dev/null`);
		let out = '';
		try { out = fs.readfile(tmp) ?? ''; } catch (e) { out = ''; }
		if (length(out) < 2) {
			ctx.sh(`rm -f '${tmp}' 2>/dev/null`);
			return null;
		}
		let parsed = json(out);
		if (parsed == null) {
			// 解析失败：留着文件让人能看（下次成功的请求会覆盖同名？不会，名字唯一）
			ctx.sh(`echo "$(date +%H:%M:%S) eapi bad json len=${length(out)} tmp=${tmp}" >> /tmp/netease-eapi.log 2>/dev/null`);
			return null;
		}
		ctx.sh(`rm -f '${tmp}' 2>/dev/null`);
		return parsed;
	}
	// 解码器落盘。
	// 应用商店的白名单不收可执行文件和 .so，所以 mpg123 和它的两个依赖库
	// 以 base64 存在 assets.txt 里，第一次要播放时再解到 bin/ 下。
	// 返回可用的 bin 目录，失败返回空串。
	function ensureBin() {
		let dir = '/etc/e5-infoscreen/plugins/netease/bin';
		let had = trim(ctx.sh(`[ -x '${dir}/mpg123' ] && [ -f '${dir}/libout123.so.0' ] && [ -f '${dir}/libsyn123.so.0' ] && echo yes`) ?? '');
		if (length(had) > 0) return dir;

		let src = '/etc/e5-infoscreen/plugins/netease/assets.txt';
		let has = trim(ctx.sh(`[ -f '${src}' ] && echo yes`) ?? '');
		if (length(has) < 1) return '';          // 没有资产文件：可能是别的机型自带的包

		let text = '';
		try { text = fs.readfile(src) ?? ''; } catch (e) { return ''; }
		if (length(text) < 100) return '';

		ctx.sh(`mkdir -p '${dir}' 2>/dev/null`);
		let name = '';
		for (let line in split(text, '\n')) {
			let l = trim(line);
			if (substr(l, 0, 4) == '### ') {
				let parts = split(trim(substr(l, 4)), ' ');
				name = parts[0] ?? '';
				continue;
			}
			if (length(name) > 0 && length(l) > 100) {
				let bin = b64dec(l);
				if (bin != null) {
					try { fs.writefile(dir + '/' + name, bin); } catch (e) { }
					// 可执行位：mpg123 要能跑，库不用但不影响
					ctx.sh(`chmod 755 '${dir}/${name}' 2>/dev/null`);
				}
				name = '';
			}
		}
		let ok = trim(ctx.sh(`[ -x '${dir}/mpg123' ] && echo yes`) ?? '');
		return length(ok) > 0 ? dir : '';
	}

	// 上次拿到的试听片段有多少秒（0 = 不是试听）。前端用它摆那个"到此为止"的标记。
	let lastTrialSec = 0;
	// 上一次 ensureFile 是不是因为"只拿到试听片段"才失败。
	// 不靠 vipType 预判（那个字段实测不可靠：会员账号也可能读到 0），
	// 而是看服务端实际给了多大的文件。
	let lastTrial = 0;

	function ensureFile(id, durMs) {
		let file = `${aud()}/${id}.mp3`;
		if (sizeOf(file) >= MIN_BYTES) {
			// 缓存命中也要把"这是试听"的判断带出来 —— 否则第二次播同一首时
			// trial 变成 0，白点消失、进度条又能随便拖，前后不一致。
			let mark = `/tmp/cx-trial-${id}.txt`;
			let sec = int(trim(ctx.sh(`cat '${mark}' 2>/dev/null`) ?? '0') ?? 0);
			if (sec > 0) { lastTrial = 1; lastTrialSec = sec; }
			return file;
		}

		// 每次下载用**各自的**临时文件。原来所有请求共用 ${id}.mp3.part，滑动切歌
		// 时同一首可能被并发请求（手势一次 + 后台续播一次）：A 正在写，B 上来先
		// rm 掉它、再写自己的，A 写完又把 B 的半个文件 mv 成正式文件 —— 于是偶尔
		// 拿到一个几百字节的"音频"，报的就是"拿不到音频（可能是会员专享…）"。
		let salt = trim(ctx.sh(`od -An -tu4 -N4 /dev/urandom 2>/dev/null | tr -d ' '`) ?? '0');
		let tmp = `${file}.${salt}.part`;
		// 带上会话 Cookie：有些歌不带 Cookie 时这个 URL 会回一个 200 的短错误页，
		// 看起来"下载成功"，其实内容不是音频（MIN_BYTES 就是用来兜这个的）。
		// 这里用 $(cat SESSION) 而不是 readSession()，是因为 ensureFile 定义得比它早。
		// 先用 eapi 问真实播放地址。老接口 /song/media/outer/url 对 VIP 歌
		// 只回 30 秒试听——哪怕账号真是会员。eapi 会按账号权限给完整流。
		// 音质从高到低试，第一档没权限（url 为空）就降一档。
		// 不能用 readSession()：它定义在 ensureFile 之后（前向引用会直接报
		// "access to undeclared variable"），这里直接读文件
		let ck = trim(ctx.sh(`cat '${SESSION}' 2>/dev/null`) ?? '');
		// 不要 lossless：那是 FLAC，mpg123 是 MP3 解码器，解不了（实测文件头是 fLaC，
		// 进程一起来就退，表现就是"放不出来"）。这几个档位都是 MP3。
		//
		// 每一档都**真的下载一次**再判断，而不是"拿到 url 就用"：
		// 会员过期后 exhigh 照样返回一个 url、也填了 size，但服务端拒绝给流，
		// curl 下来是 0 字节。只看 url 非空会误判，然后报"拿不到音频"。
		let got = 0;
		let usedLevel = '';
		for (let lv in [ 'exhigh', 'higher', 'standard' ]) {
			let r = eapiCall('/api/song/enhance/player/url/v1',
				sprintf('{"ids":"[%d]","level":"%s","encodeType":"mp3"}', id, lv), ck);
			let body = r ? r.body : null;
			let arr = body ? body.data : null;
			if (type(arr) != 'array' || length(arr) < 1) continue;
			let url = `${arr[0].url ?? ''}`;
			if (length(url) < 20) continue;
			ctx.sh(`curl -sL -m 90 -o '${tmp}' -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' -H "Cookie: $(cat '${SESSION}' 2>/dev/null)" '${url}' 2>/dev/null`);
			got = sizeOf(tmp);
			if (got >= MIN_BYTES) { usedLevel = lv; break; }
			ctx.sh(`rm -f '${tmp}' 2>/dev/null`);
			got = 0;
		}
		// 全都拿不到（接口抽风/未登录）就退回老路，至少能出 30 秒
		if (got < MIN_BYTES) {
			ctx.sh(`curl -sL -m 90 -o '${tmp}' -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' -H "Cookie: $(cat '${SESSION}' 2>/dev/null)" '${BASE}/song/media/outer/url?id=${id}.mp3' 2>/dev/null`);
			got = sizeOf(tmp);
			usedLevel = 'legacy';
		}
		if (got >= MIN_BYTES) ctx.sh(`echo "$(date +%H:%M:%S) id=${id} level=${usedLevel} bytes=${got}" >> /tmp/netease-play.log 2>/dev/null`);
		// 试听检测：靠"实际音频时长 vs 歌曲时长"判断，不看文件大小 ——
		// 大小会被码率和歌曲长度双重影响，短一点的正常歌也会被误杀。
		// 文件足够小才去解码一次验证（省掉大文件的开销）。
		if (got >= MIN_BYTES && int(durMs ?? 0) > 90000 && got < 1500000) {
			// 不能调 mpgCmd()（定义在 ensureFile 之后，前向引用会报错），
			// 这里直接找可用的解码器：系统优先，其次插件自带的
			let realSec = 0;
			// 解码器可能是"按需解压"的（assets.txt），这时 bin/ 还是空的，
			// 所以先确保它被解出来，否则下面 probe 不到，检测直接失效。
			ensureBin();
			// ctx.sh 里跑 if/then/elif 拿不到输出（实测返回空），
			// 换成两次简单的 test
			let sysBin = trim(ctx.sh(`command -v mpg123 2>/dev/null`) ?? '');
			let cmd = '';
			if (length(sysBin) > 1) cmd = 'mpg123';
			else if (length(trim(ctx.sh(`test -x '/etc/e5-infoscreen/plugins/netease/bin/mpg123' && echo 1`) ?? '')) > 0)
				cmd = `LD_LIBRARY_PATH='/etc/e5-infoscreen/plugins/netease/bin' '/etc/e5-infoscreen/plugins/netease/bin/mpg123'`;
			let tag = '';
			if (length(cmd) > 0)
				tag = trim(ctx.sh(`${cmd} -v -t '${tmp}' 2>&1 | grep -oE '\[[0-9]+:[0-9]+\]' | tail -1`) ?? '');
			let c = index(tag, ':');
			if (c > 0) {
				let mm = int(substr(tag, 1, c - 1) ?? '0');
				let ss = int(substr(tag, c + 1, length(tag) - c - 2) ?? '0');
				realSec = mm * 60 + ss;
			}
			let wantSec = int(durMs) / 1000;
			// 实际时长不到歌曲应有的一半，说明服务端只给了试听片段。
			// 这种情况照样播（能听 30 秒总比什么都没有强），只是给前端一个标记，
			// 让它提示"这是试听"。
			if (realSec > 0 && realSec < wantSec * 0.6) {
				lastTrial = 1;
				lastTrialSec = realSec;
				ctx.sh(`printf '%d' '${realSec}' > '/tmp/cx-trial-${id}.txt' 2>/dev/null`);
				ctx.sh(`echo "$(date +%H:%M:%S) id=${id} trial-only bytes=${got} real=${realSec}s want=${wantSec}s" >> /tmp/netease-play.log 2>/dev/null`);
			}
		}
		if (got < MIN_BYTES) {
			// 记一笔再删：200 但字节数不够，多半是回了个错误页/试听碎片。
			// Content-Type 能直接看出是 text/html 还是 audio/mpeg。
			let code = trim(ctx.sh(`curl -sL -o /dev/null -w '%{http_code} %{content_type}' -m 8 -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' -H "Cookie: $(cat '${SESSION}' 2>/dev/null)" '${BASE}/song/media/outer/url?id=${id}.mp3' 2>/dev/null`) ?? '');
			ctx.sh(`echo "$(date +%H:%M:%S) id=${id} http=${code} bytes=${got}" >> /tmp/netease-play.log 2>/dev/null`);
			ctx.sh(`rm -f '${tmp}' 2>/dev/null`);
			return null;
		}
		ctx.sh(`mv -f '${tmp}' '${file}' 2>/dev/null`);
		// 完整文件：清掉可能残留的试听标记
		if (!lastTrial) ctx.sh(`rm -f '/tmp/cx-trial-${id}.txt' 2>/dev/null`);
		pruneCache();
		return sizeOf(file) >= MIN_BYTES ? file : null;
	}


	// weapi 请求器（/usr/libexec/cx-weapi）：AES 双层 + RSA 加密参数。
	// 只有"反馈给推荐"这类接口还只认 weapi，eapi 那边不给。
	// 和 eapi 一样：包里自带一份就用包里的，换机器装完插件就能用（点赞/垃圾桶都靠它）
	const WEAPI_BUNDLED = '/etc/e5-infoscreen/plugins/netease/weapi.py';
	let weapiCommand = null;

	// 商店版本不带 weapi.py（.py 不在白名单），也未必有 /usr/libexec/cx-weapi。
	// 两边都没有时返回空串，调用方据此跳过"上报到云端"这一步 ——
	// 本地把歌从池子里去掉才是关键，云端那步是锦上添花。
	function weapiTool() {
		if (weapiCommand == null) {
			if (length(ctx.sh(`[ -f '${WEAPI_BUNDLED}' ] && echo yes`) ?? '') > 0)
				weapiCommand = `/usr/bin/python3 '${WEAPI_BUNDLED}'`;
			else if (length(ctx.sh(`[ -x /usr/libexec/cx-weapi ] && echo yes`) ?? '') > 0)
				weapiCommand = '/usr/libexec/cx-weapi';
			else
				weapiCommand = '';
		}
		return weapiCommand;
	}

	function weapiCall(path, dataJson, cookie) {
		let tool = weapiTool();
		if (length(tool) < 1) return null;
		let ck = replace(cookie ?? '', /[^A-Za-z0-9_%=; .-]/g, '');
		let req = sprintf('{"path":"%s","data":%s,"cookie":"%s"}', path, dataJson, ck);
		let out = ctx.sh(`printf '%s' '${req}' | ${tool} 2>/dev/null`);
		return json(out ?? 'null');
	}


	// curl 完直接读回文本。
	// **不能**用 ctx.sh() 接返回值：它捕获子进程输出有上限，歌单详情、
	// 歌手全部歌曲、播客节目这些动辄几十上百 KB，超了就被截断，
	// json() 解析失败，外面只看到"空列表"或"返回异常"。
	// 让 curl 写文件，再整份读回来就没有这个问题。
	function curlText(args) {
		let tmp = `/tmp/cx-curl-${int(time())}-${int(trim(ctx.sh(`od -An -tu2 -N2 /dev/urandom | tr -d ' '`) ?? '0')) % 65536}.json`;
		ctx.sh(`curl -s ${args} -o '${tmp}' 2>/dev/null`);
		let out = '';
		try { out = fs.readfile(tmp) ?? ''; } catch (e) { out = ''; }
		ctx.sh(`rm -f '${tmp}' 2>/dev/null`);
		return out;
	}

	// 普通 GET（带会话 cookie），这类接口不需要加密
	function apiGet(path, query) {
		let url = `${BASE}${path}${query ? '?' + query : ''}`;
		let ck = readSession();
		let out = curlText(`-m 15 -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' -H 'Cookie: ${ck}' '${url}'`);
		return json(out ?? 'null');
	}

	// 彻底停掉当前播放：pid 文件里那个 setsid sh 只是外壳，
	// mpg123 和 pacat 是它的子进程，必须按名字再杀一遍，否则切歌会叠着放。
	function stopAll() {
		// 只按名字杀 mpg123/pacat。pid 文件里的 pid 是那个 sh 外壳，
		// 它退出得很快、pid 会被内核回收，照着 pid 去 kill 有可能误杀别的进程
		// （实际踩过：把正在处理 /_auto 的 shell 杀了，续播就地静默失败）。
		signalAll('KILL');
		ctx.sh(`rm -f '${PIDFILE}' 2>/dev/null`);
	}

	// 起播放管道。skip: 从第几秒开始（拖进度条用）。
	// mpg123 没有按秒 seek，只有 -k 跳帧；44.1k 下每帧 1152 采样 = 38.28125 帧/秒，
	// 实测 765 帧差 19.9 秒，跟这个换算对得上。
	// 管道放完（进程退出）会 curl 一下 /_auto 让后端续下一首 —— 页面早关了也照样续。
	// 宿主的地址：前端会把它看到的 origin 传上来（端口可能不是 8088）
	// 拿不到就退回本机 8088（本机默认）。
	function originOf(o) {
		let v = `${o ?? ''}`;
		if (length(v) < 8) return 'http://127.0.0.1:8088';
		return replace(v, /[^A-Za-z0-9.:\/_-]/g, '');
	}

	// 解码器：系统装了 mpg123 就用系统的，否则用包里自带的那份（bin/ 里放了
	// mpg123 和它的 libout123、libsyn123）。干净系统上常常没有 mpg123，而缺它
	// 的现象很迷惑——歌能搜到、能下载、封面和进度都对，就是没声音：管道里没有
	// 一个字节，pacat 立刻退出，而 stderr 又被丢掉了。
	const MPG_BIN = '/etc/e5-infoscreen/plugins/netease/bin';
	let mpgCommand = null;   // 只探一次

	function mpgCmd() {
		if (mpgCommand != null) return mpgCommand;
		ensureBin();          // 第一次用时把解码器解出来
		let r = trim(ctx.sh(`command -v mpg123 >/dev/null 2>&1 && echo sys || { test -x '${MPG_BIN}/mpg123' && echo bin; }`) ?? '');
		if (r == 'sys') return (mpgCommand = 'mpg123');
		if (r == 'bin') return (mpgCommand = `LD_LIBRARY_PATH='${MPG_BIN}' '${MPG_BIN}/mpg123'`);
		return (mpgCommand = '');
	}

	function startPlayer(file, skip, gen, origin) {
		let mpg = mpgCmd();
		if (mpg == '') return -2;      // 没有解码器；上层据此给出明确的提示
		let k = '';
		if (skip > 0) k = `-k ${int(skip * 38.28125)} `;
		let after = `curl -s -m 15 '${originOf(origin)}/api/plugins/netease/_auto?gen=${gen}' >/dev/null 2>&1`;
		// 播放出口：有 PulseAudio 就用 pacat，没有就退到 ALSA 的 aplay（同一份 raw PCM）
		let out = 'pacat --playback --raw --format=s16le --rate=44100 --channels=2 --latency-msec=300';
		if (length(trim(ctx.sh(`command -v pacat 2>/dev/null`) ?? '')) < 1)
			out = 'aplay -q -t raw -f S16_LE -r 44100 -c 2';
		ctx.sh(`setsid sh -c "${mpg} -q ${k}-o raw -r 44100 '${file}' 2>/dev/null | ${out}; ${after}" >/dev/null 2>&1 & echo $! > '${PIDFILE}'`);
		return playerPid();
	}

	// 被打断时暂停：独立守护，盯 ModemManager 的 Call 状态（3=响铃 4=接通）
	// 和蓝牙音频出口是否还在。在放歌时暂停、通话结束恢复、蓝牙断开不恢复。
	// 不能靠前端轮询——页面隐藏时 WebKit 会节流定时器，那样来电就永远发现不了。
	// 商店版是 watch.uc（.sh 不在白名单），老安装还可能是 watch.sh —— 两个都找
	function watchPath() {
		let base = '/etc/e5-infoscreen/plugins/netease/';
		if (length(trim(ctx.sh(`[ -f '${base}watch.uc' ] && echo yes`) ?? '') ) > 0)
			return { file: base + 'watch.uc', cmd: `ucode '${base}watch.uc'`, name: 'netease/watch.uc' };
		if (length(trim(ctx.sh(`[ -f '${base}watch.sh' ] && echo yes`) ?? '') ) > 0)
			return { file: base + 'watch.sh', cmd: `sh '${base}watch.sh'`, name: 'netease/watch.sh' };
		return null;
	}

	function ensureWatch() {
		// 按进程名判断，不用 pid 文件：setsid 的 $! 是包装进程，fork 完就退出了
		let w = watchPath();
		if (w == null) return 0;
		// 从 sh 版升级上来时旧进程还在，两个一起跑会重复暂停 —— 先收掉旧的那个
		if (length(trim(ctx.sh(`ps | grep -c '[n]etease/watch.sh'`) ?? '0')) > 0
			&& trim(ctx.sh(`ps | grep -c '[n]etease/watch.sh'`) ?? '0') != '0')
			ctx.sh(`pkill -f 'netease/watch.sh' 2>/dev/null`);
		let n = int(trim(ctx.sh(`ps | grep -c '[${w.name}]'`) ?? '0') ?? 0);
		if (n > 0) return 1;
		ctx.sh(`setsid ${w.cmd} </dev/null >/dev/null 2>&1 &`);
		return 1;
	}

	// ---- 播放期间按住 CPU 唤醒锁 ----
	// 内核 CONFIG_PM_WAKELOCKS=y，往 /sys/power/wake_lock 里挂个名字就不会进 mem 睡眠。
	// 不挂的话 CPU 一睡，pacat 的 DMA 供不上数据，听感就是"音乐停了"。
	const WAKE_NAME = 'netease-play';
	const WAKE_PID = '/tmp/netease-wake.pid';

	function holdWake() {
		ctx.sh(`echo ${WAKE_NAME} > /sys/power/wake_lock 2>/dev/null`);
	}

	function dropWake() {
		ctx.sh(`echo ${WAKE_NAME} > /sys/power/wake_unlock 2>/dev/null`);
	}

	// 一首歌放完不会有人来调 /stop，锁得自己放掉：
	// pacat 消失后再等 8 秒（切歌那一秒空档不算），还没回来才解锁。
	function wakeWatch() {
		let pid = int(trim(ctx.sh(`cat '${WAKE_PID}' 2>/dev/null`) ?? '0') ?? 0);
		if (pid > 0 && int(trim(ctx.sh(`kill -0 ${pid} 2>/dev/null && echo 1 || echo 0`)) ?? 0) == 1)
			return;
		ctx.sh(`setsid sh -c 'while pgrep -x pacat >/dev/null 2>&1; do sleep 5; done; sleep 8; while pgrep -x pacat >/dev/null 2>&1; do sleep 5; done; echo ${WAKE_NAME} > /sys/power/wake_unlock 2>/dev/null; rm -f ${WAKE_PID}' </dev/null >/dev/null 2>&1 & echo $! > '${WAKE_PID}'`);
	}

		// eapi 的歌曲对象：hr 有值 = 有"超清母带"；fee 才是会员标识
		// fee: 0 免费 / 1 VIP / 4 购买专辑 / 8 低音质免费（不算 VIP 标）
		function hasHr(t) { return type(t.hr) == 'object' ? 1 : 0; }

		// eapi 返回的歌曲结构跟搜索不一样（ar/al/dt 简写），统一成前端用的形状
		function normEapiSongs(list) {
			let out = [];
			if (type(list) != 'array') return out;
			for (let t in list) {
				let artists = [];
				for (let a in (t.ar ?? []))
					push(artists, a.name ?? '');
				let al = t.al;
				push(out, {
					id: t.id,
					name: t.name ?? '',
					artist: join(' / ', artists),
					album: al ? (al.name ?? '') : '',
					duration: t.dt ?? 0,
					fee: t.fee ?? 0,
					hires: hasHr(t)
				});
			}
			return out;
		}

	// ---- 播放状态（key=value 行，值里的单引号和换行会被抹掉） ----
	// 重装插件会把 cache 软链一起删掉，第一次用到封面时补回来。
	// 只在真的不是软链时才动 shell，正常情况下这是一次 stat。
	function ensureCache() {
		ctx.sh(`[ -L '${CACHE}' ] || { mkdir -p '${CACHE_REAL}' 2>/dev/null; ` +
			`rm -rf '${CACHE}' 2>/dev/null; ln -s '${CACHE_REAL}' '${CACHE}' 2>/dev/null; }`);
	}

	// 把封面下到本地并返回路径；已经有就直接用。
	// 单独抽出来是因为它有第二个调用方：status 发现封面文件不见了（被清、或当初没下成）
	// 时也要能补一次 —— 只靠 playSong 的话，歌一直在放就永远等不到下一次下载。
	function ensureCover(id, src) {
		if (id <= 0) return '';
		src = replace(`${src ?? ''}`, /'/g, '%27');
		if (substr(src, 0, 9) == '/plugins/') return src;   // 已经是本地路径
		if (length(src) < 9) return '';
		ensureCache();
		let base = `${CACHE}/cover-${id}`;
		for (let e in [ '.jpg', '.png', '.webp', '.gif' ])
			if (sizeOf(`${base}${e}`) > 2000) return `/plugins/netease/cache/cover-${id}${e}`;
		ctx.sh(`mkdir -p '${CACHE}' 2>/dev/null`);
		ctx.sh(`curl -sL -m 12 -o '${base}.part' -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' '${src}' 2>/dev/null`);
		if (sizeOf(`${base}.part`) > 2000) {
			let magic = trim(ctx.sh(`od -An -tx1 -N4 '${base}.part' 2>/dev/null | tr -d ' \n'`) ?? '');
			let ext = '.jpg';
			if (match(magic, /^89504e47/)) ext = '.png';
			else if (match(magic, /^52494646/)) ext = '.webp';
			else if (match(magic, /^47494638/)) ext = '.gif';
			ctx.sh(`mv -f '${base}.part' '${base}${ext}' 2>/dev/null`);
			return `/plugins/netease/cache/cover-${id}${ext}`;
		}
		ctx.sh(`rm -f '${base}.part' 2>/dev/null`);
		return '';
	}

	function writeState(fields) {
		let args = [];
		for (let k in fields)
			push(args, `'${k}=${replace(`${fields[k]}`, /['\n]/g, ' ')}'`);
		ctx.sh(`umask 077; printf '%s\\n' ${join(' ', args)} > '${STATE}' 2>/dev/null`);
	}

	function readState() {
		let raw = ctx.sh(`cat '${STATE}' 2>/dev/null`) ?? '';
		let out = {};
		for (let line in split(raw, '\n')) {
			let i = index(line, '=');
			if (i > 0) out[substr(line, 0, i)] = substr(line, i + 1);
		}
		return out;
	}

	// 同样的 key=value 格式，给别的状态文件用
	function kvRead(file) {
		let raw = ctx.sh(`cat '${file}' 2>/dev/null`) ?? '';
		let out = {};
		for (let line in split(raw, '\n')) {
			let i = index(line, '=');
			if (i > 0) out[substr(line, 0, i)] = substr(line, i + 1);
		}
		return out;
	}

	function kvWrite(file, fields) {
		let args = [];
		for (let k in fields)
			push(args, `'${k}=${replace(`${fields[k]}`, /['\n]/g, ' ')}'`);
		ctx.sh(`umask 077; printf '%s\\n' ${join(' ', args)} > '${file}' 2>/dev/null`);
	}

	// ---- "下一首播放"的待播队列 ----
	// 以前这条只改前端队列，但后端切歌是按 PLAN（歌单/每日推荐）取顺序的，压根不看
	// 前端队列，所以插进去的歌永远轮不到它放。这里落一个真队列，切歌和自动续播都先问它。
	const NEXTQ = '/tmp/netease-next.txt';

	function nextQRead() {
		let raw = ctx.sh(`cat '${NEXTQ}' 2>/dev/null`) ?? '';
		let out = [];
		// 每行 "id pid"。pid 是播客节目 id，丢了它续播时就分不清是歌还是单集了。
		// ucode 的 for-in 遍历的是**值**，不是下标
		for (let line in split(raw, '\n')) {
			let f = split(trim(line) ?? '', ' ');
			let id = int(f[0] ?? '0');
			let pid = int(f[1] ?? '0');
			if (id > 0) push(out, { id: id, pid: pid });
		}
		return out;
	}

	function nextQWrite(list) {
		let body = '';
		for (let it in list) body += `${int(it.id)} ${int(it.pid)}\n`;
		ctx.sh(`umask 077; printf '%s' '${body}' > '${NEXTQ}' 2>/dev/null`);
	}

	// ucode 没有 rand()，用 urandom 拼一个
	function randInt(n) {		if (n <= 1) return 0;
		let s = trim(ctx.sh('od -An -N2 -tu2 /dev/urandom 2>/dev/null') ?? '0');
		let v = int(s ?? '0') ?? 0;
		if (v < 0) v = -v;
		return v % n;
	}

	// 取单曲详情（名称/艺人/时长/封面），/play 记状态和 /detail 都用它
	function songDetail(id) {
		let raw = curl(`'${BASE}/api/song/detail/?ids=%5B${id}%5D'`);
		let d = json(raw);
		let songs = d ? d.songs : null;
		if (type(songs) != 'array' || length(songs) < 1) return null;
		let x = songs[0];
		let artists = [], pairs = [];
		for (let a in (x.artists ?? [])) {
			push(artists, a.name ?? '');
			push(pairs, { id: a.id, name: a.name ?? '' });
		}
		let al = x.album;
		return {
			id: x.id, name: x.name ?? '',
			artist: join(' / ', artists),
			artists: pairs,
			artistId: (pairs[0] && pairs[0].id) ? pairs[0].id : 0,
			albumId: al ? (al.id ?? 0) : 0,
			album: al ? (al.name ?? '') : '',
			cover: al ? (al.picUrl ?? null) : null,
			duration: x.duration ?? 0,
			fee: x.fee ?? 0
		};
	}

	// ---- 歌词 ----
	// 这台 ucode 对带反斜杠的正则处理不牢靠，所以时间标签全用手写解析
	function tagMs(tag) {
		let c = index(tag, ':');
		if (c <= 0) return -1;
		let mm = substr(tag, 0, c);
		let rest = substr(tag, c + 1);
		if (!match(mm, /^[0-9]+$/)) return -1;
		let dot = index(rest, '.');
		let ss = dot > 0 ? substr(rest, 0, dot) : rest;
		let fr = dot > 0 ? substr(rest, dot + 1) : '';
		if (!match(ss, /^[0-9]+$/)) return -1;
		let ms = int(mm) * 60000 + int(ss) * 1000;
		if (length(fr) > 0 && match(fr, /^[0-9]+$/)) {
			if (length(fr) == 2) ms += int(fr) * 10;
			else if (length(fr) == 1) ms += int(fr) * 100;
			else ms += int(substr(fr, 0, 3));
		}
		return ms;
	}

	// "[00:12.34][00:15.00]词" -> [{t: 12340, s: "词"}, ...]，[by:] 这类头信息自动忽略
	// 逐字歌词（yrc）转普通行：每行形如 [起始ms,时长ms](字起始,字时长,?)字(…)字
	// 有些新歌根本没有 lrc，只有这个 —— 不转的话就是"没有歌词"。
	// 逐字歌词（yrc）：行是 [行起始ms,行时长ms](字起始ms,字时长ms,?)字(…)字…
	// 返回 { t, s, w: [{ t, s }] } —— w 是每个字的起始时间和文字，
	// 前端靠它在行内做逐字填充。
	function parseYrc(text) {
		let out = [];
		for (let raw in split(text ?? '', '\n')) {
			let s = trim(raw);
			if (length(s) < 3 || substr(s, 0, 1) != '[') continue;
			let e = index(s, ']');
			if (e < 0) continue;
			let head = split(substr(s, 1, e - 1), ',');
			let t = int(head[0] ?? '-1');
			if (t < 0) continue;
			let rest = substr(s, e + 1);
			let words = [], plain = '';
			let i = 0;
			while (i < length(rest)) {
				if (substr(rest, i, 1) == '(') {
					let close = index(substr(rest, i), ')');
					if (close < 0) break;
					let meta = split(substr(rest, i + 1, close - 1), ',');
					let wt = int(meta[0] ?? '-1');
					i += close + 1;
					// 后面的文字一直取到下一个 '('
					let nxt = index(substr(rest, i), '(');
					let txt = nxt < 0 ? substr(rest, i) : substr(rest, i, nxt);
					i += length(txt);
					if (length(txt) > 0) {
						push(words, { t: wt, s: txt });
						plain += txt;
					}
				} else i++;
			}
			plain = trim(plain);
			if (length(plain) < 1) continue;
			push(out, { t: t, s: plain, w: words });
		}
		return out;
	}

	function parseLrc(text) {
		let out = [];
		for (let raw in split(text ?? '', '\n')) {
			let s = trim(raw);
			if (length(s) < 1) continue;
			let t = -1;
			while (length(s) > 0 && substr(s, 0, 1) == '[') {
				let e = index(s, ']');
				if (e < 0) break;
				let ms = tagMs(substr(s, 1, e - 1));
				if (ms >= 0) t = ms;
				s = substr(s, e + 1);
			}
			s = trim(s);
			if (t >= 0 && length(s) > 0) push(out, { t: t, s: s });
		}
		return out;
	}

	function stopPlayer() {
		let pid = playerPid();
		if (pid > 0) ctx.sh(`kill -9 ${pid} 2>/dev/null`);
		ctx.sh(`rm -f '${PIDFILE}' 2>/dev/null`);
	}

	// 状态文件里存歌手：id:名字|id:名字（值里不能有换行和引号）
	function artistPairs(list) {
		let out = [];
		for (let a in (list ?? []))
			push(out, `${a.id}:${replace(`${a.name ?? ''}`, /[:|]/g, ' ')}`);
		return join('|', out);
	}

	function artistParse(text) {
		let out = [];
		for (let p in split(`${text ?? ''}`, '|')) {
			let c = index(p, ':');
			if (c > 0) push(out, { id: int(substr(p, 0, c)) ?? 0, name: substr(p, c + 1) });
		}
		return out;
	}

	// 前端加载过的页会攒在这里（只存 id:fee），续播按同一份顺序算下一首
	function artistCacheFile(id, order) {
		return `/tmp/netease-artist-${id}-${order == 'time' ? 'time' : 'hot'}.txt`;
	}

	function artistCacheAppend(id, songs, order) {
		let parts = [];
		for (let s in songs) push(parts, `${s.id}:${int(s.fee ?? 0)}`);
		if (length(parts) < 1) return;
		ctx.sh(`printf '%s\n' '${join(',', parts)}' >> '${artistCacheFile(id, order)}' 2>/dev/null`);
	}

	function artistCached(id, order) {
		// 必须把 order 传下去：漏了这个参数，无论切到哪种排序都会落到 hot 的缓存文件，
		// 表现就是"排序按钮点了没反应"（图省事少传一个参数，结果两边都读热度）。
		let raw = ctx.sh(`cat '${artistCacheFile(id, order)}' 2>/dev/null`) ?? '';
		let out = [], seen = {};
		for (let line in split(raw, '\n')) {
			for (let p in split(line, ',')) {
				let c = index(p, ':');
				if (c <= 0) continue;
				let sid = int(substr(p, 0, c));
				if (int(seen[`${sid}`] ?? 0) == 1) continue;
				seen[`${sid}`] = 1;
				push(out, { id: sid, fee: int(substr(p, c + 1)),
					name: '', artist: '', album: '', duration: 0, hires: 0 });
			}
		}
		return out;
	}

	// ---- 喜欢 / 不喜欢 ----
	// 「我喜欢的音乐」全量 id 一次拉下来缓存 10 分钟，单个 id 判断只查缓存
	function likedList() {
		let raw = ctx.sh(`cat '${LIKED}' 2>/dev/null`) ?? '';
		let nl = index(raw, '\n');
		let ts = 0, body = '';
		if (nl > 0) { ts = int(substr(raw, 0, nl)) ?? 0; body = substr(raw, nl + 1); }
		if (length(body) > 0 && time() - ts < 600 && index(body, 'null') < 0) return body;
		let d = apiGet('/api/song/like/get', 'trackIds=%5B1%5D');
		let ids = d ? d.ids : null;
		if (type(ids) != 'array') return body;      // 取不到就先用旧的
		// 注意：ucode 的 for-in 遍历数组给的是**值**，不是下标
		let parts = [];
		for (let v in ids) push(parts, `${v}`);
		body = join(',', parts);
		ctx.sh(`umask 077; printf '%s\n%s' '${time()}' '${body}' > '${LIKED}' 2>/dev/null`);
		return body;
	}

	// eapi 的 track 数组（ar/al/dt）归一化
	function tracksEapi(tracks) {
		let out = [];
		if (type(tracks) != 'array') return out;
		for (let t in tracks) {
			// 老接口给 artists、新接口给 ar；有些歌 ar 是空数组，不兜底歌手名就没了
			let ar = t.ar;
			if (type(ar) != 'array' || length(ar) < 1) ar = t.artists;
			let artists = [];
			for (let a in (ar ?? [])) push(artists, a.name ?? '');
			let al = t.al;
			// /api/v1/artist/songs 是**老接口**：专辑叫 album、时长叫 duration，
			// 不是新接口的 al / dt。只认新格式的话歌手页除了歌名什么都拿不到
			// （封面、专辑名、时长全空）。
			if (type(al) != 'object') al = t.album;
			push(out, {
				id: t.id, name: t.name ?? '',
				artist: join(' / ', artists),
				album: (type(al) == 'object' && al) ? (al.name ?? '') : '',
				// 封面地址留着：歌手页要按卡片样式渲染，需要每首的专辑图。
				// fillCovers() 之后这个字段会被换成下到本地的 /plugins/... 路径。
				url: (type(al) == 'object' && al) ? (al.picUrl ?? '') : '',
				duration: t.dt ?? t.duration ?? 0, fee: t.fee ?? 0, hires: hasHr(t)
			});
		}
		return out;
	}

	// cache/c 不在 pruneCache 的范围内（它只管顶层），单独按数量清一下
	function pruneCovers() {
		let files = [];
		for (let line in split(trim(ctx.sh(`ls -1t '${CACHE}/c' 2>/dev/null`) ?? ''), '\n')) {
			let f = trim(line);
			if (length(f) > 0) push(files, f);
		}
		// 收藏页一次就可能有几百张专辑，门槛留 120 的话，先下的会被后下的顶掉，
		// 表现就是"部分封面加载不出来"。400 张按每张 15 KB 算约 6 MB，存得下。
		if (length(files) <= 400) return;
		for (let i = 400; i < length(files); i++)
			ctx.sh(`rm -f '${CACHE}/c/${files[i]}' 2>/dev/null`);
	}

	// 歌单/电台封面：https 地址在 web 进程里加载不了，统一下到 cache/c/ 再给本地路径。
	// 一次要几十张，所以攒成一条 shell 并行下，别一张一张等。
	function fillCovers(items, prefix) {
		let jobs = [], outs = [], names = [];
		ensureCache();
		ctx.sh(`mkdir -p '${CACHE}/c' 2>/dev/null`);
		// 目录先列一次。以前每张都调一次 sizeOf()，79 首歌就是 79 次 shell 往返，
		// 歌手页切一次排序要等两秒，用户等不及就会连点。
		let listing = `\n${ctx.sh(`ls -1 '${CACHE}/c' 2>/dev/null`) ?? ''}\n`;
		for (let i = 0; i < length(items); i++) {
			let u = replace(`${items[i].url ?? ''}`, /'/g, '%27');
			if (length(u) > 8 && index(u, 'param=') < 0) u = `${u}?param=200y200`;
			let nm = `${prefix}-${items[i].id}`;
			let ext = match(u, /webp/) ? '.webp' : (match(u, /png/) ? '.png' : '.jpg');
			let file = `${CACHE}/c/${nm}${ext}`;
			let rel = `/plugins/netease/cache/c/${nm}${ext}`;
			items[i].cover = '';
			push(names, nm);
			if (length(u) < 8) { push(outs, ''); continue; }
			push(outs, rel);
			// 用目录列表判断有没有缓存，别再调 sizeOf()（那是又一次 shell 往返）
			if (index(listing, `${nm}.`) >= 0) continue;
			push(jobs, `curl -sL -m 8 -o '${file}.part' -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' '${u}' 2>/dev/null && mv -f '${file}.part' '${file}'`);
		}
		if (length(jobs) > 0) {
			let script = '';
			for (let i = 0; i < length(jobs); i++) {
				script += `( ${jobs[i]} ) & `;
				if ((i + 1) % 20 == 0) script += 'wait; ';
			}
			ctx.sh(script + 'wait');
		}
		// 下载完按**真实字节**校正扩展名。URL 后缀不一定等于真实格式（有的封面其实是
		// PNG / WebP）。扩展名和内容对不上时 uhttpd 会发错 Content-Type，WebKit 可能
		// 直接不解码 —— 透明背景的 PNG 封面最容易撞上这个。顺便把"下回来是错误页"的删掉。
		for (let i = 0; i < length(items); i++) {
			let nm = names[i] ?? '';
			// 已经在目录里的直接按实际扩展名给路径，不再 od 读magic ——
			// 之前每张都要读取文件头，79 首就是 79 次进程创建，这才是切排序卡两秒的大头。
			// 缓存文件当初下载时就校正过扩展名，这里信它。
			let cachedExt = '';
			for (let e in [ '.jpg', '.png', '.webp', '.gif' ])
				if (index(listing, `${nm}${e}\n`) >= 0) { cachedExt = e; break; }
			if (length(cachedExt) > 0) {
				items[i].cover = `/plugins/netease/cache/c/${nm}${cachedExt}`;
				continue;
			}
			let rel = outs[i] ?? '';
			if (length(rel) < 1) { items[i].cover = ''; continue; }
			let ext = substr(rel, length(rel) - 4);
			let file = `${CACHE}/c/${names[i]}${ext}`;
			if (sizeOf(file) < 1000) { items[i].cover = ''; continue; }
			let magic = trim(ctx.sh(`od -An -tx1 -N4 '${file}' 2>/dev/null | tr -d ' \n'`) ?? '');
			let real = '';
			if (match(magic, /^89504e47/)) real = '.png';
			else if (match(magic, /^52494646/)) real = '.webp';
			else if (match(magic, /^ffd8/)) real = '.jpg';
			else if (match(magic, /^47494638/)) real = '.gif';
			if (length(real) < 1) {
				// 不是图片（多半是错误页/占位），别拿它当封面
				ctx.sh(`rm -f '${file}' 2>/dev/null`);
				items[i].cover = '';
				continue;
			}
			if (real != ext) {
				let fixed = `${CACHE}/c/${names[i]}${real}`;
				ctx.sh(`mv -f '${file}' '${fixed}' 2>/dev/null`);
				rel = `/plugins/netease/cache/c/${names[i]}${real}`;
			}
			items[i].cover = rel;
		}
		pruneCovers();
	}

	// 歌手全部歌曲分页：/api/v1/artist/songs?id=&offset=&limit=&order=hot
	function artistPage(id, offset, limit, order) {
		if (id <= 0) return null;
		if (order != 'time') order = 'hot';
		let ck = readSession();
		let raw = curlText(`-m 25 -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' -H 'Cookie: ${ck}' '${BASE}/api/v1/artist/songs?id=${id}&offset=${offset}&limit=${limit}&order=${order}'`);
		let d = json(raw ?? 'null');
		if (d == null) return null;
		return { songs: tracksEapi(d.songs), more: d.more ? 1 : 0 };
	}

	// 歌手页：/api/v1/artist/<id> 一次给全（artist + 50 首热门）
	function artistInfo(id) {
		if (id <= 0) return null;
		let ck = readSession();
		let raw = ctx.sh(`curl -s -m 20 -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' -H 'Cookie: ${ck}' '${BASE}/api/v1/artist/${id}' 2>/dev/null`);
		let d = json(raw ?? 'null');
		if (d == null) return null;
		let a = d.artist;
		return {
			ok: true,
			id: id,
			name: a ? (a.name ?? '') : '',
			pic: a ? (a.picUrl ?? '') : '',
			count: a ? (a.musicSize ?? 0) : 0,
			// 歌手页头部要用的：别名、简介、关注状态、专辑数
			alias: a ? join(' / ', a.alias ?? []) : '',
			brief: a ? (a.briefDesc ?? '') : '',
			followed: a ? (a.followed == true ? 1 : 0) : 0,
			albums: a ? (a.albumSize ?? 0) : 0,
			songs: tracksEapi(d.hotSongs)
		};
	}

	// 列表的唯一入口：前端展示和后台续播都走它，两边看到的顺序才一致
	// 歌单的完整曲目。`playlist/detail` 里的 tracks 是**截断**的（实测只给前 20 首），
	// 完整顺序在 trackIds 里 —— 只能按 id 分批补详情，再按 trackIds 的顺序还原。
	// 少了这一步，歌单永远只显示 20 首。
	function playlistTracks(pl) {
		let ids = [];
		for (let t in (pl.trackIds ?? [])) {
			let id = (type(t) == 'object') ? int(t.id) : int(t);
			if (id > 0) push(ids, id);
		}
		let songs = tracksEapi(pl.tracks);
		if (length(ids) <= length(songs)) return { songs: songs, total: length(songs) };
		let byId = {};
		let i = 0;
		while (i < length(ids)) {
			let chunk = [];
			for (let k = 0; k < 500 && i < length(ids); k++, i++) push(chunk, ids[i]);
			let d = json(curl(`'${BASE}/api/song/detail/?ids=%5B${join(',', chunk)}%5D'`) ?? 'null');
			for (let x in ((d && d.songs) ?? [])) byId[x.id] = x;
		}
		let out = [];
		for (let id in ids) { let x = byId[id]; if (x != null) push(out, x); }
		return { songs: tracksEapi(out), total: length(out) };
	}


	// ---- 歌单：只要 id 顺序，详情按页取 ----
	// `playlist/detail` 的 tracks 只给前 20 首，完整顺序在 trackIds 里。但一次性展开
	// 整张表（8698 首要 18 批、20 秒）既慢又没必要：列表是分页看的，续播也只需要
	// 下一首。所以这里只缓存 id 顺序和歌单名，详情按 offset/limit 现取。
	function plMeta(sid) {
		let file = `/tmp/netease-pl-${sid}.json`;
		try {
			let c = json(fs.readfile(file) ?? 'null');
			if (type(c) == 'object' && int(c.t ?? 0) > 0 && time() - int(c.t) < 21600 &&
			    type(c.ids) == 'array' && length(c.ids) > 0)
				return c;
		} catch (e) { }
		let ck = readSession();
		let raw = curlText(`-m 20 -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' -H 'Cookie: ${ck}' '${BASE}/api/v6/playlist/detail?id=${sid}&n=1000'`);
		let d = json(raw ?? 'null');
		let pl = d ? d.playlist : null;
		if (pl == null) return null;
		let ids = [];
		for (let t in (pl.trackIds ?? [])) {
			let id = (type(t) == 'object') ? int(t.id) : int(t);
			if (id > 0) push(ids, id);
		}
		if (length(ids) < 1) for (let t in (pl.tracks ?? [])) push(ids, int(t.id));
		let meta = { t: time(), name: pl.name ?? '', ids: ids,
			cover: pl.coverImgUrl ?? '', desc: pl.description ?? '',
			creator: (pl.creator && pl.creator.nickname) ? pl.creator.nickname : '',
			count: int(pl.trackCount ?? length(ids)) };
		try { fs.writefile(file, sprintf('%J', meta)); } catch (e) { }
		return meta;
	}

	// 取某一页的歌曲详情。一页 200 首 = 一次 song/detail，避免拼长 URL。
	function plPage(sid, offset, limit) {
		let meta = plMeta(sid);
		if (meta == null) return null;
		let ids = meta.ids;
		let from = offset > 0 ? offset : 0;
		if (from > length(ids)) from = length(ids);
		let to = from + (limit > 0 ? limit : 200);
		if (to > length(ids)) to = length(ids);
		let chunk = [];
		for (let i = from; i < to; i++) push(chunk, ids[i]);
		let songs = [];
		if (length(chunk) > 0) {
			let d = json(curl(`'${BASE}/api/song/detail/?ids=%5B${join(',', chunk)}%5D'`) ?? 'null');
			let byId = {};
			for (let x in ((d && d.songs) ?? [])) byId[x.id] = x;
			let ordered = [];
			for (let id in chunk) { let x = byId[id]; if (x != null) push(ordered, x); }
			songs = tracksEapi(ordered);
		}
		// 详情页要用封面：https 地址在 web 进程里加载不了，换成 cache/c 下的本地路径。
		// 只在第一页取：翻页时封面早就有了，再查一遍是白跑一次 ls。
		let cover = '';
		if (from == 0 && length(meta.cover ?? '') > 8) {
			let one = [{ id: sid, url: meta.cover }];
			fillCovers(one, 'pl');
			cover = one[0].cover ?? '';
		}
		return { name: meta.name, songs: songs, total: length(ids), more: to < length(ids),
			cover: cover, desc: meta.desc ?? '',
			creator: meta.creator ?? '', count: int(meta.count ?? length(ids)) };
	}

	// "我喜欢的音乐"是个 specialType=5 的特殊歌单，id 要先查出来（同样缓存半天）
	function likedPlaylistId() {
		let file = '/tmp/netease-liked-pid.txt';
		let c = kvRead(file);
		if (int(c.t ?? 0) > 0 && time() - int(c.t) < 21600 && int(c.pid ?? 0) > 0) return int(c.pid);
		let uid = readUid();
		if (uid <= 0) return 0;
		let d = apiGet('/api/user/playlist', sprintf('uid=%d&limit=200&offset=0', uid));
		let list = d ? d.playlist : null;
		if (type(list) != 'array') return 0;
		for (let p in list) if (p.specialType == 5) {
			kvWrite(file, { t: time(), pid: p.id });
			return int(p.id);
		}
		return 0;
	}

	// ---- 私人FM 缓冲 ----
	// /api/v1/radio/get 一次只给 3 首，而且是"新"的推荐（正在放的这首不在里面）。
	// 原来每首歌放完都重新拉一次、再随机挑一首，既多一次网络往返（约 1 秒空档），
	// 顺序也和界面上的队列对不上。现在在本地攒一个池子：放一首取一首，
	// 低于 4 首就补，顺序就是推荐给的顺序。
	const FM_POOL = '/tmp/netease-fm.json';
	const FM_TRASH = '/tmp/netease-fm-trash.txt';   // 不喜欢过的 id，逗号分隔

	function fmTrashGet() {
		return trim(ctx.sh(`cat '${FM_TRASH}' 2>/dev/null`) ?? '');
	}

	function fmPoolRead() {
		let d = json(fs.readfile(FM_POOL) ?? 'null');
		return (type(d) == 'object' && type(d.songs) == 'array') ? d.songs : [];
	}

	function fmPoolSave(list) {
		try { fs.writefile(FM_POOL, sprintf('%J', { t: time(), songs: list })); } catch (e) { }
	}

	// 补池子：一次补到 12 首左右，最多发 4 次请求，踩过的不再进来
	function fmRefill() {
		let ck = readSession();
		let pool = fmPoolRead();
		let bad = fmTrashGet();
		let seen = {};
		for (let s in pool) seen[`${s.id}`] = 1;
		for (let k = 0; k < 4 && length(pool) < 12; k++) {
			let r = eapiCall('/api/v1/radio/get', '{}', ck);
			let body = r ? r.body : null;
			let songs = normEapiSongs(body ? body.data : null);
			if (length(songs) < 1) break;
			for (let s in songs) {
				let id = `${s.id}`;
				if (seen[id]) continue;
				if (length(bad) > 0 && index(',' + bad + ',', ',' + id + ',') >= 0) continue;
				seen[id] = 1;
				push(pool, s);
			}
		}
		fmPoolSave(pool);
		return pool;
	}

	// 取下一首：跳过正在放的这首，取到就从池子里删掉
	function fmTake(cur) {
		let pool = fmPoolRead();
		let pick = null;
		for (let round = 0; round < 2 && pick == null; round++) {
			if (length(pool) < 4) pool = fmRefill();
			for (let s in pool) if (int(s.id) != cur) { pick = s; break; }
			if (pick == null) { pool = []; fmPoolSave(pool); }
		}
		if (pick == null) return null;
		let keep = [];
		for (let s in pool) if (int(s.id) != int(pick.id)) push(keep, s);
		fmPoolSave(keep);
		return pick;
	}

	// 心动模式：以某首歌为种子，一次要一首。
	// 接口 `/api/radio/get?songId=` 返回的是老格式（album / duration / artists），
	// limit 传多少都只回一首，所以每切一首就请求一次。
	function radioTake(songId, cur) {
		if (songId <= 0) return null;
		let ck = readSession();
		let raw = ctx.sh(`curl -s -m 20 -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' -H 'Cookie: ${ck}' '${BASE}/api/radio/get?songId=${songId}&limit=5' 2>/dev/null`);
		let d = json(raw ?? 'null');
		if (d == null) return null;
		let list = d.data ?? [];
		for (let t in list) {
			if (int(t.id) == cur) continue;           // 别立刻把刚放完的这首又推一遍
			let one = tracksEapi([ t ]);
			if (length(one) > 0) return one[0];
		}
		return null;
	}

	// 从"我喜欢的"里随机取一首（排除当前这首）。
	// 官方心动模式是"收藏里随机播 + 中间穿插推荐新歌"，这就是那个"收藏里随机"。
	function likedPick(cur) {
		let body = likedList();
		if (length(body) < 1) return null;
		let ids = [];
		for (let x in split(body, ',')) {
			let id = int(trim(x) ?? '0');
			if (id > 0 && id != cur) push(ids, id);
		}
		if (length(ids) < 1) return null;
		let info = songDetail(ids[randInt(length(ids))]);
		if (info == null) return null;
		return info;
	}

	// 心动模式的下一首：官方是"收藏里随机 + 穿插新歌"。
	// 这里按 3:1 的节奏走 —— 每 4 首里有 1 首是从电台新推的，其余都从收藏里随机拿。
	// 计数存在 plan.n 里，跨进程（切歌是新进程）也能接着算。
	function radioNext(plan, cur) {
		let seedId = int(plan.sid ?? 0);
		// 计数单独存一个文件：自动续播（_auto）和手动切歌是两个进程，
		// 都写 plan 的话 n 会互相覆盖，节奏就乱了（实测会突然重置回 1）。
		let NF = '/tmp/netease-radio-n.txt';
		let n = int(trim(ctx.sh(`cat '${NF}' 2>/dev/null`) ?? '0') ?? 0) + 1;
		ctx.sh(`printf '%d' '${n}' > '${NF}' 2>/dev/null`);
		let wantNew = (n % 4 == 0);
		let pick = wantNew ? radioTake(seedId > 0 ? seedId : cur, cur)
			: likedPick(cur);
		// 一边拿不到就用另一边兜底，别让心动模式断在半路
		if (pick == null) pick = wantNew ? likedPick(cur) : radioTake(seedId > 0 ? seedId : cur, cur);
		if (pick == null) return null;
		kvWrite(PLAN, { kind: 'radio', sid: int(pick.id),
			mode: plan.mode ?? 'loop', order: plan.order ?? 'hot' });
		return pick;
	}

	// ---- 收藏（专辑 / 歌手 / 播客 / 歌单）----
	// 四个 kind 的参数字段都不一样，是实测出来的：
	//   album    sub/unsub 都用 id
	//   artist   sub 用 artistId，unsub 用 artistIds=[id]（JSON 数组）
	//   podcast  sub/unsub 都用 id
	//   playlist 要 POST 且带 csrf_token
	const SUBS = '/tmp/netease-subs.json';
	// 标记文件：重装插件清空 cache 时它一起没，用来判断 subs 缓存里那些封面路径还有没有效
	const SUBSTAMP = `${CACHE}/.subs-stamp`;

	function subsLoad(force) {
		if (!force) {
			try {
				let c = json(fs.readfile(SUBS) ?? 'null');
				// 缓存里存的是封面**路径**，文件本体在插件目录的 cache 下。重装插件会
				// rm -rf 整个目录，而这份缓存留在 /tmp 活得好好的 —— 不校验的话，收藏页
				// 就会拿一堆已经不存在的路径去画封面，表现就是"部分封面加载不出来"。
				// stamp 和 cache 同生共死：它没了说明 cache 被清过，缓存作废。
				if (type(c) == 'object' && int(c.t ?? 0) > 0 && time() - int(c.t) < 300 &&
				    sizeOf(SUBSTAMP) > 0)
					return c;
			} catch (e) { }
		}
		let albums = [], artists = [], podcasts = [];
		let a = json(curl(`'${BASE}/api/album/sublist?limit=500&offset=0'`) ?? 'null');
		for (let it in ((a && a.data) ?? []))
			push(albums, { id: int(it.id), name: it.name ?? '',
				sub: (it.artists && it.artists[0]) ? `${it.artists[0].name}` : '',
				url: `${it.picUrl ?? ''}` });
		let r = json(curl(`'${BASE}/api/artist/sublist?limit=500&offset=0'`) ?? 'null');
		for (let it in ((r && r.data) ?? []))
			push(artists, { id: int(it.id), name: it.name ?? '',
				sub: (it.albumSize ?? 0) + ' 张专辑', url: `${it.picUrl ?? ''}` });
		let d = json(curl(`'${BASE}/api/djradio/get/subed?limit=200&offset=0'`) ?? 'null');
		for (let it in ((d && d.djRadios) ?? []))
			push(podcasts, { id: int(it.id), name: it.name ?? '',
				sub: (it.dj && it.dj.nickname) ? `${it.dj.nickname}` : '', url: `${it.picUrl ?? ''}` });
		fillCovers(albums, 'al');
		fillCovers(artists, 'ar');
		fillCovers(podcasts, 'dj');
		let out = { t: time(), albums: albums, artists: artists, podcasts: podcasts };
		try { fs.writefile(SUBS, sprintf('%J', out)); } catch (e) { }
		// 记下"这批封面对应的是当前这份 cache"；重装插件清空 cache 时标记随之消失，
		// 下次进收藏页就会认出来、重新下载，而不是拿死路径去画。
		ctx.sh(`mkdir -p '${CACHE}' 2>/dev/null; : > '${SUBSTAMP}' 2>/dev/null`);
		return out;
	}

	function subsList(kind) {
		let s = subsLoad();
		if (kind == 'album') return s.albums ?? [];
		if (kind == 'artist') return s.artists ?? [];
		if (kind == 'podcast') return s.podcasts ?? [];
		return [];
	}

	function csrfOf(ck) {
		let m = match(ck, /__csrf=([^;]*)/);
		return m ? m[1] : '';
	}

	// 节目的封面：自己的 coverUrl 优先；遇到网易云默认占位图就用电台的封面
	function programCover(p) {
		let c = `${p.coverUrl ?? ''}`;
		let radio = p.radio ? `${p.radio.picUrl ?? ''}` : '';
		if (length(c) < 8 || index(c, '109951169484091680') >= 0) c = radio;
		if (length(c) < 8) c = radio;
		return c;
	}

	function listSongs(kind, sid, order, offset, limit) {
		let ck = readSession();
		if (kind == 'playlist') {
			if (sid <= 0) return { ok: false, songs: [], error: '歌单 id 无效' };
			let raw = curlText(`-m 20 -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' -H 'Cookie: ${ck}' '${BASE}/api/v6/playlist/detail?id=${sid}&n=1000'`);
			let d = json(raw ?? 'null');
			let pl = d ? d.playlist : null;
			if (pl == null) return { ok: false, songs: [], error: '歌单不存在' };
			let full = playlistTracks(pl);
			return { ok: true, name: pl.name ?? '', songs: full.songs, total: full.total };
		}
		if (kind == 'artist') {
			let ord = (order == 'time') ? 'time' : 'hot';
			let cached = artistCached(sid, ord);
			if (length(cached) > 0) return { ok: true, songs: cached };
			let page = artistPage(sid, 0, 200, ord);
			if (page == null) return { ok: false, songs: [], error: '取不到歌手歌曲' };
			artistCacheAppend(sid, page.songs, ord);
			return { ok: true, songs: artistCached(sid, ord) };
		}
		if (kind == 'programs') {
			if (sid <= 0) return { ok: false, songs: [], error: '电台 id 无效' };
			let raw = curlText(`-m 20 -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' -H 'Cookie: ${ck}' '${BASE}/api/dj/program/byradio?radioId=${sid}&limit=50&offset=0'`);
			let d = json(raw ?? 'null');
			let progs = d ? d.programs : null;
			if (type(progs) != 'array') progs = [];
			let out = [];
			for (let p in progs) {
				let m = p.mainSong;
				if (m == null) continue;
				let artists = [];
				for (let a in (m.artists ?? [])) push(artists, a.name ?? '');
				push(out, {
					id: m.id, name: p.name ?? (m.name ?? ''),
					artist: join(' / ', artists),
					album: p.radio ? (p.radio.name ?? '') : '',
					duration: m.duration ?? 0, fee: 0, hires: 0,
					pid: p.id,          // 节目 id（点赞要用它，不是 mainSong 的 id）
					// 播客的 mainSong.album 是个通用占位图，真正该用节目/电台自己的封面。
					// 另外有一批节目本身没设封面，接口给的是网易云的默认占位图
					// （固定资源 109951169484091680，整张纯灰），这种也退回电台封面。
					cov: programCover(p)
				});
			}
			// 播客详情页要和歌单详情一样有封面和简介。电台详情接口（djradio/detail）
			// 已经 404 了，但每个节目里的 radio 对象字段齐全，直接用它，还省一次请求。
			let radio = null;
			for (let p in progs) if (p.radio) { radio = p.radio; break; }
			let cover = '';
			if (radio) {
				let url = `${radio.picUrl ?? ''}`;
				if (length(url) > 8) {
					let one = [{ id: sid, url: url }];
					fillCovers(one, 'dj');
					cover = one[0].cover ?? '';
				}
			}
			// 电台对象的 dj 有时是空的，主播名从节目自己的 dj 兜一下
			let host = (radio && radio.dj && radio.dj.nickname) ? `${radio.dj.nickname}` : '';
			if (length(host) < 1)
				for (let p in progs) if (p.dj && p.dj.nickname) { host = `${p.dj.nickname}`; break; }
			return { ok: true, songs: out,
				name: radio ? `${radio.name ?? ''}` : '',
				cover: cover,
				desc: radio ? `${radio.desc ?? ''}` : '',
				creator: host,
				count: radio ? int(radio.programCount ?? length(out)) : length(out),
				total: radio ? int(radio.programCount ?? length(out)) : length(out),
				subed: (radio && radio.subed == true) ? 1 : 0,
				more: 0 };
		}

		if (length(ck) < 1) return { ok: false, songs: [], need_login: true };

		if (kind == 'daily') {
			// 每日推荐当天不会变，缓存 10 分钟：既省一次 eapi 往返（每次都要
			// openssl + curl 两个进程），也把"网络抖一下就空列表"的概率压下去。
			const DAILY_CACHE = '/tmp/netease-daily.json';
			let cached = json(fs.readfile(DAILY_CACHE) ?? 'null');
			if (type(cached) == 'object' && type(cached.songs) == 'array'
				&& length(cached.songs) > 0 && time() - int(cached.t ?? 0) < 600)
				return { ok: true, songs: cached.songs, cached: 1 };

			// 网络抖动或 openssl/curl 失败时 eapiCall 返回 null，以前这里照样回
			// ok:true + 空数组，前端只能显示"0 首"，看着像"偶尔加载失败"。
			let r = eapiCall('/api/v3/discovery/recommend/songs',
					 '{"offset":0,"limit":50,"total":true,"n":1000}', ck);
			if (r == null) return { ok: false, error: '网络不太好，没能取到每日推荐' };
			let body = r.body;
			if (type(body) != 'object')
				return { ok: false, error: r.error ? ('每日推荐返回异常（' + r.error + '）') : '每日推荐返回异常' };
			let data = body.data;
			let songs = normEapiSongs(data ? data.dailySongs : null);
			if (length(songs) < 1) {
				// 有时接口会给 200 但内容为空（当天还没生成）
				return { ok: false, error: '今天的推荐还没出来，稍后再试' };
			}
			try { fs.writefile(DAILY_CACHE, sprintf('%J', { t: time(), songs: songs })); } catch (e) { }
			return { ok: true, songs: songs };
		}

		if (kind == 'fm') {
			return { ok: true, songs: fmRefill() };
		}

		if (kind == 'liked') {
			// "我喜欢的音乐": 先查 specialType=5 的那个歌单 id，再按页取
			let pid = likedPlaylistId();
			if (pid <= 0) return { ok: false, songs: [], error: '还没有登录' };
			// 一次只取一页。这个列表只下歌单自己的一张封面（下面的 plPage 干的），
			// 不算歌曲封面 —— 紧凑行根本不显示。慢的是 song/detail 批量查详情：
			// 一次 200 个 id 比 50 个多四倍的数据要解析。默认 50，滚到底再要下一页。
			let lim = int(limit ?? 50);
			if (lim <= 0 || lim > 200) lim = 50;
			let page = plPage(pid, int(offset ?? 0), lim);
			if (page == null) return { ok: true, songs: [], total: 0 };
			return { ok: true, songs: page.songs, total: page.total, more: page.more ? 1 : 0 };
		}

		return { ok: false, songs: [], error: '未知列表' };
	}

	// 起播一首：下载 -> 停旧的 -> 起进程 -> 记状态。前端 /play 和后台续播共用
	function playSong(id, cov, progId, meta, origin) {
		// 先确认音频拿得到，再动状态：取不到就原样返回，
		// 不然一次失败的尝试会把 auto 关掉，正在放的那首放完就不续了。
		lastTrial = 0;
		lastTrialSec = 0;
		// 前端调 /play?id= 时常常不带 dur，拿不到时长就没法判断"是不是只有试听"。
		// 这里自己补一次 songDetail —— 反正后面也要用它取封面和名字。
		let preInfo = null;
		let durMs = meta ? int(meta.dur ?? 0) : 0;
		if (durMs < 1000) {
			preInfo = songDetail(id);
			if (preInfo) durMs = int(preInfo.duration ?? 0);
		}
		let file = ensureFile(id, durMs);
		if (file == null) return { ok: false, error: '拿不到音频（可能是会员专享或版权受限）' };

		// gen 区分"这一次播放"：被 kill 的旧进程回调里带的是旧 gen，不会乱续
		let gen = int(time()) * 1000 + randInt(1000);
		let old = readState();
		old.auto = 0;          // 先关掉续播，免得旧回调抢先跳一首
		writeState(old);

		stopAll();
		holdWake();            // 先把锁挂上再起进程，别在起进程的缝里睡过去
		let pid = startPlayer(file, 0, gen, origin);
		if (pid == -2) { dropWake(); return { ok: false, error: '缺少 mpg123 解码器（系统和插件自带的都没找到）' }; }
		if (pid <= 0) { dropWake(); return { ok: false, error: '播放进程没起来' }; }
		wakeWatch();
		ensureWatch();

		// 记下"在放什么、从什么时候开始"，页面重进时靠它恢复。
		// 队列里带来的 name/artist/duration 比 songDetail 准（播客的 mainSong 查不到名字）
		let info = songDetail(id);
		// 播客节目：song/detail 往往查不到（名字/封面都是空或占位图）。
		// 只要知道节目 id，就补一次节目详情 —— 名字、主播、封面都以它为准。
		let prog = null;
		let needProg = progId > 0 &&
			(length(`${(meta && meta.name) ? meta.name : ''}`) < 1 ||
			 length(`${cov ?? ''}`) < 9 ||
			 index(`${cov ?? ''}`, '109951169484091680') >= 0);
		if (needProg) {
			let pd = json(curl(`'${BASE}/api/dj/program/detail?id=${progId}'`) ?? 'null');
			prog = pd ? pd.program : null;
		}
		let progName = prog ? `${prog.name ?? ''}` : '';
		let progHost = (prog && prog.dj && prog.dj.nickname) ? `${prog.dj.nickname}`
			: ((prog && prog.radio && prog.radio.name) ? `${prog.radio.name}` : '');
		let progDur = (prog && prog.mainSong && prog.mainSong.duration) ? int(prog.mainSong.duration) : 0;

		let nm = (meta && length(`${meta.name ?? ''}`) > 0) ? `${meta.name}`
			: (length(progName) > 0 ? progName : (info ? info.name : ''));
		let ar = (meta && length(`${meta.artist ?? ''}`) > 0) ? `${meta.artist}`
			: (length(progHost) > 0 ? progHost : (info ? info.artist : ''));
		let du = (meta && int(meta.dur ?? 0) > 0) ? int(meta.dur)
			: (progDur > 0 ? progDur : (info ? info.duration : 0));

		// 封面同样要下到本地：web 进程没有 TLS 后端，https 的封面加载不出来
		let coverLocal = '';
		// 播客节目给了 cov 就用它（mainSong 的专辑图是通用占位图）
		let src = (length(`${cov ?? ''}`) > 8) ? `${cov}` : (info ? (info.cover ?? '') : '');
		if (prog && (length(src) < 9 || index(src, '109951169484091680') >= 0)) {
			let real = `${prog.coverUrl ?? ''}`;
			if (length(real) > 8 && index(real, '109951169484091680') < 0) src = real;
		}
		src = replace(src, /'/g, '%27');
		// 传过来的已经是本地路径（赞过的单集存的就是本地封面）就直接用
		if (substr(src, 0, 9) == '/plugins/') {
			coverLocal = src;
		} else if (length(src) > 8) {
			// 扩展名按**真实字节**定，不按 URL 猜：链接写 .jpg、实际返回 PNG 的情况
			// 很常见，存成 .jpg 的话 uhttpd 会按 image/jpeg 发，WebKit 可能不解码。
			let base = `${CACHE}/cover-${id}`;
			let mark = `${base}.src`;
			// 记着这张图是从哪个地址下的：续播先拿到的是网易云默认占位图，
			// 等真正点播时 src 变了，但"文件已存在"会让我们跳过下载，占位图就一直留着。
			let used = trim(ctx.sh(`cat '${mark}' 2>/dev/null`) ?? '');
			if (used != src)   // 没有记录也当作"来源不明"，重下一次把老的占位图换掉
				ctx.sh(`rm -f '${base}.jpg' '${base}.png' '${base}.webp' '${base}.gif' 2>/dev/null`);
			let have = '';
			for (let e in ['.jpg', '.png', '.webp', '.gif'])
				if (sizeOf(`${base}${e}`) > 2000) { have = e; break; }
			if (length(have) < 1) {
				ensureCache();
				ctx.sh(`mkdir -p '${CACHE}' 2>/dev/null`);
				ctx.sh(`curl -sL -m 30 -o '${base}.part' -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' '${src}' 2>/dev/null`);
				if (sizeOf(`${base}.part`) > 2000) {
					let magic = trim(ctx.sh(`od -An -tx1 -N4 '${base}.part' 2>/dev/null | tr -d ' \n'`) ?? '');
					let ext = '.jpg';
					if (match(magic, /^89504e47/)) ext = '.png';
					else if (match(magic, /^52494646/)) ext = '.webp';
					else if (match(magic, /^47494638/)) ext = '.gif';
					ctx.sh(`mv -f '${base}.part' '${base}${ext}' 2>/dev/null`);
					have = ext;
				} else {
					ctx.sh(`rm -f '${base}.part' 2>/dev/null`);
				}
			}
			// 老缓存可能是"PNG 存成了 .jpg"，顺手纠正一次
			if (length(have) > 0) {
				let magic = trim(ctx.sh(`od -An -tx1 -N4 '${base}${have}' 2>/dev/null | tr -d ' \n'`) ?? '');
				let real = '';
				if (match(magic, /^89504e47/)) real = '.png';
				else if (match(magic, /^52494646/)) real = '.webp';
				else if (match(magic, /^ffd8/)) real = '.jpg';
				else if (match(magic, /^47494638/)) real = '.gif';
				if (length(real) > 0 && real != have) {
					ctx.sh(`mv -f '${base}${have}' '${base}${real}' 2>/dev/null`);
					have = real;
				}
				coverLocal = `/plugins/netease/cache/cover-${id}${have}`;
				ctx.sh(`printf '%s' '${src}' > '${mark}' 2>/dev/null`);
			}
		}

		writeState({
			id: id,
			name: nm,
			artist: ar,
			cover: coverLocal,   // 存本地路径, 前端直接能用
			duration: du,
			artists: artistPairs(info ? info.artists : []),   // 点歌手名跳转用
			file: file,          // 拖进度时要拿它重开进程
			origin: originOf(origin),   // 宿主地址，_auto/seek 续播回调要用
			start: time(),
			paused_total: 0,
			paused_at: 0,
			gen: gen,
			auto: 1,
			// 这一首是不是只有试听片段。自动续播（后端 /_auto）换歌时前端拿不到
			// /play 的返回值，只能从 status 里读，所以状态里必须存一份 ——
			// 否则白点会一直挂在那儿，切到普通歌也不消失。
			trial: lastTrial ? 1 : 0,
			trial_sec: lastTrialSec,
			pid: int(progId ?? 0)     // 播客节目才有
		});
		// trial: 这次拿到的只是试听片段（会员歌 + 无权限），前端据此提示一句
		return { ok: true, id: id, pid: pid, trial: lastTrial ? 1 : 0,
			trialSec: lastTrialSec, cover: coverLocal };
	}

	// 取出"下一首播放"队列的队首并播放；没有排队的返回 null。
	// 放在 playSong 之后定义 —— ucode 不允许前向引用。
	function takeQueued(origin) {
		let q = nextQRead();
		if (length(q) < 1) return null;
		let id = int(q[0].id);
		let pid = int(q[0].pid);
		let rest = [];
		for (let i = 1; i < length(q); i++) push(rest, q[i]);
		nextQWrite(rest);
		let info = songDetail(id);
		if (info == null) return null;     // 拿不到详情就当这首不存在，别把队列堵死
		let r = playSong(id, `${info.cover ?? ''}`, pid,
			{ name: `${info.name ?? ''}`, artist: `${info.artist ?? ''}`, dur: int(info.duration ?? 0) },
			`${origin ?? ''}`);
		return (r && r.ok) ? r : null;
	}

	// 耳机按键的上一首/下一首。耳机只给一个"下一首"，没有列表概念，所以这里按当前
	// 播放来源（PLAN）重新取一遍顺序、按 id 定位再走一步 —— 和续播用的是同一套逻辑。
	// 播放顺序（只要 id）。歌单/喜欢走缓存里的完整顺序，其余列表本来就小，直接展开。
	function orderItems(kind, sid, order) {
		if (kind == 'playlist' || kind == 'liked') {
			let pid = (kind == 'liked') ? likedPlaylistId() : sid;
			let meta = pid > 0 ? plMeta(pid) : null;
			let out = [];
			if (meta) for (let id in meta.ids) push(out, { id: id });
			return out;
		}
		let songs = listSongs(kind, sid, order).songs;
		let out = [];
		for (let s in songs)
			push(out, { id: int(s.id), cov: s.cov, pid: int(s.pid ?? 0),
				name: s.name ?? '', artist: s.artist ?? '', dur: int(s.duration ?? 0) });
		return out;
	}

	function stepTrack(dir) {
		let st = readState();
		let cur = int(st.id ?? 0);
		if (cur <= 0) return { ok: false, error: '当前没有播放中的歌曲' };
		// "下一首播放"排队的优先，排在 PLAN 顺序前面
		if (dir > 0) {
			let q = takeQueued(`${st.origin ?? ''}`);
			if (q != null) return q;
		}
		let plan = kvRead(PLAN);
		let kind = plan.kind ?? '';
		if (length(kind) < 1) return { ok: false, error: '播放来源未知' };
		// 电台没有"上一首"这个概念，两个方向都当"再来一首"
		if (kind == 'radio') {
			let pick = radioNext(plan, cur);
			if (pick == null) return { ok: false, error: '取不到下一首' };
			let r = playSong(int(pick.id), `${pick.cover ?? ''}`, 0,
				{ name: `${pick.name ?? ''}`, artist: `${pick.artist ?? ''}`, dur: int(pick.duration ?? 0) });
			return (r && r.ok) ? r : { ok: false, error: '这首放不了' };
		}
		if (kind == 'fm') {
			let pick = fmTake(cur);
			if (pick == null) return { ok: false, error: '取不到下一首' };
			let r = playSong(int(pick.id), `${pick.cov ?? ''}`, 0,
				{ name: `${pick.name ?? ''}`, artist: `${pick.artist ?? ''}`, dur: int(pick.duration ?? 0) });
			return (r && r.ok) ? r : { ok: false, error: '这首放不了' };
		}
		// 顺序从缓存的 id 列表来，详情只取被选中的那一首 —— 几千首的歌单
		// 不该为了切一首歌去展开整张表。
		let items = orderItems(kind, int(plan.sid ?? 0), plan.order ?? 'hot');
		let n = length(items);
		if (n < 1) return { ok: false, error: '列表为空' };
		let pos = -1;
		for (let i = 0; i < n; i++) if (int(items[i].id) == cur) { pos = i; break; }
		if (pos < 0) pos = dir > 0 ? -1 : 0;
		let vip = int(kvRead(VIPFILE).vip ?? 0);
		let idx = pos, tries = 0;
		while (tries < n && tries < 10) {
			idx = (idx + dir + n) % n;
			let item = items[idx];
			let info = songDetail(int(item.id));
			let fee = int(info ? (info.fee ?? 0) : 1);
			if (info == null && int(item.pid ?? 0) > 0) fee = 0;
			let blocked = (info == null && int(item.pid ?? 0) < 1) || ((vip < 1) && (fee == 1 || fee == 4));
			if (!blocked) {
				let r = playSong(int(item.id), `${info ? (info.cover ?? '') : (item.cov ?? '')}`, int(item.pid ?? 0),
					{ name: `${item.name ?? (info ? info.name : '')}`,
					  artist: `${item.artist ?? (info ? info.artist : '')}`,
					  dur: int(item.dur ?? (info ? info.duration : 0)) });
				if (r && r.ok) return r;
			}
			tries++;
		}
		return { ok: false, error: '没有可播放的歌曲' };
	}

	return {
		'GET /search': function(req) {
			let kw = safeKeyword(req.query ? req.query.q : null);
			if (length(kw) < 1) return { keyword: '', songs: [] };

			let raw = curl(`-G --data-urlencode 's=${kw}' --data 'type=1&limit=30&offset=0' '${BASE}/api/search/get/web'`);
			let d = json(raw);
			let result = d ? d.result : null;
			let songs = result ? result.songs : null;
			if (type(songs) != 'array') songs = [];

			let out = [];
			for (let s in songs) {
				let al = albumOf(s);
				push(out, {
					id: s.id,
					name: s.name ?? '',
					artist: artistText(s),
					album: al.name,
					duration: s.duration ?? 0,
					fee: s.fee ?? 0,
					hires: hasHr(s)
				});
			}
			return { keyword: kw, songs: out };
		},

		// 预取封面：给接下来几首把专辑图先下到本地，切歌时就不用等网络。
		// 一次 song/detail 拿多首的 picUrl，再用一条 shell 并行下。
		'GET /prefetch': function(req) {
			let ids = [];
			for (let p in split(`${(req.query ? req.query.ids : '') ?? ''}`, ',')) {
				let v = int(trim(p)) ?? 0;
				if (v > 0 && length(ids) < 8) push(ids, v);
			}
			if (length(ids) < 1) return { ok: true, n: 0 };
			let d = json(curl(`'${BASE}/api/song/detail/?ids=%5B${join(',', ids)}%5D'`) ?? 'null');
			let songs = d ? d.songs : null;
			if (type(songs) != 'array') return { ok: true, n: 0 };
			let jobs = [];
			for (let x in songs) {
				let url = (x.album && x.album.picUrl) ? x.album.picUrl : '';
				if (length(url) < 8) continue;
				// 预取只要 300×300：原图动辄几百 KB，切歌时解码也慢
				if (index(url, 'param=') < 0) url = `${url}?param=300y300`;
				let name = `cover-${x.id}.jpg`;
				if (match(url, /webp/)) name = `cover-${x.id}.webp`;
				else if (match(url, /png/)) name = `cover-${x.id}.png`;
				let target = `${CACHE}/${name}`;
				if (sizeOf(target) > 2000) continue;
				push(jobs, `curl -sL -m 25 -o '${target}.part' -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' '${url}' 2>/dev/null && mv -f '${target}.part' '${target}'`);
			}
			if (length(jobs) > 0) {
				ctx.sh(`mkdir -p '${CACHE}' 2>/dev/null`);
				let script = '';
				for (let i = 0; i < length(jobs); i++) script += `( ${jobs[i]} ) & `;
				ctx.sh(script + 'wait');
			}

			// audio=1 时顺便把前两首的音频也下下来 —— 切歌慢主要是因为要等整首
			// mp3 下完（~1.5s）。预取两首就够用，再多会跟正在放的抢带宽。
			let audio = 0;
			if (`${(req.query ? req.query.audio : '') ?? ''}` == '1') {
				for (let i = 0; i < length(ids) && i < 2; i++)
					if (ensureFile(ids[i]) != null) audio++;
			}
			return { ok: true, n: length(jobs), audio: audio };
		},

		// 主题：信息屏自己的设置（uci），前端拿它切明暗和强调色
		'GET /theme': function(req) {
			let t = trim(ctx.sh(`uci -q get e5-infoscreen.main.ui_theme 2>/dev/null`) ?? '');
			let a = trim(ctx.sh(`uci -q get e5-infoscreen.main.ui_accent 2>/dev/null`) ?? '');
			if (t != 'light') t = 'dark';
			if (a != 'blue' && a != 'violet') a = 'teal';
			return { ok: true, theme: t, accent: a };
		},

		// 歌手页：GET /artist?id=&offset=0&limit=100，翻页就改 offset
		// 歌手专辑列表，按发行时间倒序（接口只支持这一种顺序）。
		'GET /albums': function(req) {
			let id = int((req.query ? req.query.id : 0) ?? 0);
			if (id <= 0) return { ok: false, error: '歌手 id 无效' };
			let off = int((req.query ? req.query.offset : 0) ?? 0);
			let lim = int((req.query ? req.query.limit : 50) ?? 50);
			if (lim <= 0 || lim > 200) lim = 50;
			let ord = `${(req.query ? req.query.order : '') ?? ''}` == 'hot' ? 'hot' : 'time';
			let ck = readSession();

			let raw = curlText(`-m 25 -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' -H 'Cookie: ${ck}' '${BASE}/api/artist/albums/${id}?limit=${lim}&offset=${off}'`);
			let d = json(raw ?? 'null');
			if (d == null) return { ok: false, error: '网络不太好，专辑没取到' };
			let arr = d.hotAlbums;
			if (type(arr) != 'array') return { ok: false, error: '专辑返回异常' };

			let raw2 = [];
			for (let a in arr) {
				push(raw2, {
					id: int(a.id ?? 0),
					name: `${a.name ?? ''}`,
					url: `${a.picUrl ?? ''}`,
					pub: int(a.publishTime ?? 0),
					size: int(a.size ?? 0),
					company: `${a.company ?? ''}`
				});
			}
			// 封面统一走 fillCovers：它用目录列表判断缓存，不会每张都 shell 往返
			fillCovers(raw2, 'alb');
			let out = [];
			for (let a in raw2) {
				push(out, {
					id: a.id, name: a.name, pic: a.cover,
					pub: a.pub, size: a.size, company: a.company
				});
			}
			// 不提供热度排序：/api/artist/albums 只按发行时间倒序，
			// order / sorter 参数都不认（实测三种写法返回完全一样），
			// 也没有播放量字段可以拿来做真实热度。就按接口给的时间序。
			return { ok: true, albums: out, more: d.more ? 1 : 0,
				total: (d.artist && d.artist.albumSize) ? int(d.artist.albumSize) : 0, order: ord };
		},

		'GET /artist': function(req) {
			let id = int((req.query ? req.query.id : 0) ?? 0);
			if (id <= 0) return { ok: false, error: '歌手 id 无效' };
			let off = int((req.query ? req.query.offset : 0) ?? 0);
			let lim = int((req.query ? req.query.limit : 100) ?? 100);
			if (lim <= 0 || lim > 200) lim = 100;
			let ord = `${(req.query ? req.query.order : '') ?? ''}` == 'time' ? 'time' : 'hot';
			if (off == 0) ctx.sh(`rm -f '${artistCacheFile(id, ord)}' 2>/dev/null`);   // 从头加载就重来

			let page = artistPage(id, off, lim, ord);
			if (page == null) return { ok: false, error: '取不到歌手歌曲' };
			artistCacheAppend(id, page.songs, ord);
			// 歌手页按卡片样式显示，每首要一张封面。已有的会跳过，只补缺的。
			fillCovers(page.songs, 'sg');

			let out = { ok: true, songs: page.songs, more: page.more, offset: off, order: ord };
			if (off == 0) {
				let info = artistInfo(id);       // 名字/头像/总数只在第一页取
				out.name = info ? info.name : '';
				out.count = info ? info.count : 0;
				out.alias = info ? (info.alias ?? '') : '';
				out.brief = info ? (info.brief ?? '') : '';
				out.followed = info ? int(info.followed ?? 0) : 0;
				out.albums = info ? int(info.albums ?? 0) : 0;
				// 头像也 https，web 进程加载不了 —— 跟封面一样下到本地再给路径
				let head = [{ id: id, url: info ? `${info.pic ?? ''}` : '' }];
				fillCovers(head, 'art');
				out.pic = head[0].cover ?? '';
			}
			return out;
		},

		// 喜欢：GET /like?id= 查状态；GET /like?id=&set=1|0 设置
		// 长按菜单要用的单曲信息：歌手 id / 专辑 id
		'GET /songinfo': function(req) {
			let id = int((req.query ? req.query.id : 0) ?? 0);
			if (id <= 0) return { ok: false, error: '歌曲 id 无效' };
			let d = songDetail(id);
			if (d == null) return { ok: false, error: '没有这首歌的信息' };
			return { ok: true, id: d.id, name: d.name, artist: d.artist,
				// artists 是 [{id,name}] 数组：长按菜单要靠它判断"这首歌有几个歌手"，
				// 只有拼接字符串的话多歌手会被当成一个人去打开。
				artists: d.artists ?? [],
				artistId: d.artistId ?? 0, album: d.album, albumId: d.albumId ?? 0,
				cover: d.cover ?? '', fee: d.fee ?? 0 };
		},

		// 专辑页：和歌单一样是个子页，一次给完（专辑通常十几到几十首）
		'GET /album': function(req) {
			let id = int((req.query ? req.query.id : 0) ?? 0);
			if (id <= 0) return { ok: false, songs: [], error: '专辑 id 无效' };
			let d = json(curl(`'${BASE}/api/v1/album/${id}'`) ?? 'null');
			let al = d ? d.album : null;
			if (al == null) return { ok: false, songs: [], error: '专辑不存在' };
			let songs = tracksEapi(d.songs);
			let cover = '';
			if (length(`${al.picUrl ?? ''}`) > 8) {
				let one = [{ id: id, url: `${al.picUrl}` }];
				fillCovers(one, 'al');
				cover = one[0].cover ?? '';
			}
			return { ok: true, name: al.name ?? '', songs: songs, total: length(songs),
				more: 0, cover: cover,
				creator: (al.artist && al.artist.name) ? `${al.artist.name}` : '',
				desc: `${al.description ?? ''}`, count: length(songs) };
		},

		// 收藏到歌单：把一首歌加进指定歌单（只能加进自己的歌单）
		'GET /addto': function(req) {
			let id = int((req.query ? req.query.id : 0) ?? 0);
			let pid = int((req.query ? req.query.pid : 0) ?? 0);
			if (id <= 0 || pid <= 0) return { ok: false, error: '参数无效' };
			let ck = readSession();
			if (length(ck) < 1) return { ok: false, need_login: true };
			let raw = ctx.sh(`curl -s -m 15 -X POST -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' -H 'Cookie: ${ck}' '${BASE}/api/playlist/manipulate/tracks?op=add&pid=${pid}&trackIds=%5B${id}%5D&imme=true' 2>/dev/null`);
			let d = json(raw ?? 'null');
			if (d == null) return { ok: false, error: '操作失败（网络）' };
			if (int(d.code ?? 0) != 200) return { ok: false, error: '操作失败（可能是歌单权限或歌曲版权）' };
			return { ok: true };
		},

		'GET /like': function(req) {
			let id = int((req.query ? req.query.id : 0) ?? 0);
			if (id <= 0) return { ok: false, error: '歌曲 id 无效' };
			let set = (req.query ? req.query.set : null);
			if (set == null) {
				let body = likedList();
				let hit = index(',' + body + ',', ',' + id + ',') >= 0;
				return { ok: true, liked: hit ? 1 : 0 };
			}
			let on = `${set}` == '1' ? 1 : 0;
			let ck = readSession();
			let raw = ctx.sh(`curl -s -m 15 -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' -H 'Cookie: ${ck}' '${BASE}/api/song/like?trackId=${id}&like=${on ? 'true' : 'false'}&timestamp=${time()}000' 2>/dev/null`);
			let d = json(raw ?? 'null');
			if (d == null || int(d.code ?? 0) != 200)
				return { ok: false, error: '操作失败（可能没登录）' };
			ctx.sh(`rm -f '${LIKED}' 2>/dev/null`);   // 下次重新拉
			return { ok: true, liked: on };
		},

		// 歌词：原文 + 翻译（tlyric，非中文歌的中文翻译）。同一个时间戳对上就合并
		'GET /lyric': function(req) {
			let id = int((req.query ? req.query.id : 0) ?? 0);
			if (id <= 0) return { ok: false, error: '歌曲 id 无效' };
			let ck = readSession();
			let raw = ctx.sh(`curl -s -m 15 -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' -H 'Cookie: ${ck}' '${BASE}/api/song/lyric?id=${id}&lv=-1&kv=-1&tv=-1&yv=-1&ytv=-1' 2>/dev/null`);
			let d = json(raw ?? 'null');
			if (d == null) return { ok: false, error: '歌词取不到' };

			let lines = parseLrc(d.lrc ? d.lrc.lyric : '');
			// 有逐字数据就用它（行文本一样，但多了每个字的起始时间）。
			// 只有 lrc 的歌照旧逐行高亮。
			let y = d.yrc ? (d.yrc.lyric ?? '') : '';
			if (length(y) > 8) {
				let yl = parseYrc(y);
				if (length(yl) > 0) lines = yl;
			}
			if (length(lines) < 1) {
				// 再兜一层：卡拉OK 版里也有文字
				let k = d.klyric ? (d.klyric.lyric ?? '') : '';
				if (length(k) > 8) lines = parseLrc(k);
			}
			let trl = parseLrc(d.tlyric ? (d.tlyric.lyric ?? '') : '');
			let tr = {};
			for (let x in trl) tr[`${x.t}`] = x.s;

			let out = [];
			let has_tr = 0;
			for (let i = 0; i < length(lines); i++) {
				let x = lines[i];
				let t = tr[`${x.t}`] ?? '';
				if (t == x.s) t = '';        // 翻译跟原文一模一样的没意义
				if (length(t) > 0) has_tr = 1;
				// w 是逐字时间，别在这一步丢了（丢了前端就只能整行高亮）
				push(out, x.w ? { t: x.t, s: x.s, tr: t, w: x.w }
					: { t: x.t, s: x.s, tr: t });
			}
			return { ok: true, lines: out, has_tr: has_tr };
		},

		'GET /detail': function(req) {
			let id = int((req.query ? req.query.id : 0) ?? 0);
			if (id <= 0) return { ok: false, error: '歌曲 id 无效' };
			let d = songDetail(id);
			if (d == null) return { ok: false, error: '没有这首歌的信息' };
			let out = { ok: true };
			for (let k in d) out[k] = d[k];
			return out;
		},

		// 开始播放：下载 -> 停掉上一首 -> 起 mpg123
		'GET /play': function(req) {
			let id = int((req.query ? req.query.id : 0) ?? 0);
			if (id <= 0) return { ok: false, error: '歌曲 id 无效' };
			let q = req.query ?? {};
			return playSong(id, `${q.cov ?? ''}`, int(q.pid ?? 0), {
				name: `${q.name ?? ''}`, artist: `${q.artist ?? ''}`, dur: int(q.dur ?? 0)
			}, `${q.self ?? ''}`);
		},

		// 前端告诉后端"当前列表是从哪儿来的"，续播时后端按同一个接口重拉一遍。
		// 只传来源，不传整个列表 —— 息屏后页面就没了，后端得能自己再取到同一份顺序。
		'GET /plan': function(req) {
			let kind = `${(req.query ? req.query.kind : '') ?? ''}`;
			// none = 清掉来源。私人FM 里点"下一首播放"会走这条：电台停了，只剩这一首，
			// 后端不该再按 FM 池子往下取，否则续播又会冒出别的歌。
			if (kind == 'none') {
				kvWrite(PLAN, { kind: '', sid: 0, mode: 'loop', order: 'hot' });
				return { ok: true };
			}
			if (kind != 'daily' && kind != 'liked' && kind != 'fm' && kind != 'radio' &&
			    kind != 'playlist' && kind != 'programs' && kind != 'artist')
				return { ok: false, error: 'kind 不支持' };
			let sid = int((req.query ? req.query.sid : 0) ?? 0);
			let mode = `${(req.query ? req.query.mode : '') ?? 'loop'}`;
			if (mode != 'loop' && mode != 'one' && mode != 'shuffle' && mode != 'order') mode = 'loop';
			let order = `${(req.query ? req.query.order : '') ?? ''}` == 'time' ? 'time' : 'hot';
			kvWrite(PLAN, { kind: kind, sid: sid, mode: mode, order: order });
			return { ok: true };
		},

		// 播放管道退出后自己 curl 这里（带 gen）。gen 对不上 = 这一路已经被新的播放顶掉了。
		'GET /_auto': function(req) {
			let gen = int((req.query ? req.query.gen : 0) ?? 0);
			let st = readState();
			if (int(st.auto ?? 0) != 1) return { ok: true, stop: 1 };
			if (gen != int(st.gen ?? 0)) return { ok: true, stale: 1 };

			let plan = kvRead(PLAN);
			let kind = plan.kind ?? '';
			let mode = plan.mode ?? 'loop';
			let cur = int(st.id ?? 0);
			if (length(kind) < 1 || cur <= 0) return { ok: true, stop: 1 };

			// 自动续播也先看"下一首播放"队列，不然插进来的歌一辈子轮不到
			let queued = takeQueued(`${st.origin ?? ''}`);
			if (queued != null) return queued;

			// 心动模式：种子是**'推到哪儿了'**，不是'你现在在听哪首'。
			// 每推一首就把种子前进到那首（写回 plan.sid），这样：
			//   · 一路往下听 → 种子跟着漂移，越推越远
			//   · 回退到前面某首 → 种子不动，继续从最新前沿往外推，
			//     而不是把已经听过的方向再推一遍
			if (kind == 'radio') {
				let pick = radioNext(plan, cur);
				if (pick == null) return { ok: true, stop: 1 };
				let r = playSong(int(pick.id), `${pick.cover ?? ''}`, 0,
					{ name: `${pick.name ?? ''}`, artist: `${pick.artist ?? ''}`, dur: int(pick.duration ?? 0) },
					`${st.origin ?? ''}`);
				return (r && r.ok) ? r : { ok: true, stop: 1 };
			}

			// 私人FM 走池子：取一首、顺序就是推荐给的顺序，不再随机
			if (kind == 'fm') {
				let pick = fmTake(cur);
				if (pick == null) return { ok: true, stop: 1 };
				let r = playSong(int(pick.id), `${pick.cov ?? ''}`, 0,
					{ name: `${pick.name ?? ''}`, artist: `${pick.artist ?? ''}`, dur: int(pick.duration ?? 0) },
					`${st.origin ?? ''}`);
				return (r && r.ok) ? r : { ok: true, stop: 1 };
			}

			// 只要顺序，详情等选中那一首再取 —— 几千首的歌单不该每首都展开一次
			let items = orderItems(kind, int(plan.sid ?? 0), plan.order ?? 'hot');
			let n = length(items);
			if (n < 1) return { ok: true, stop: 1 };

			// 私人FM 是"流"：每次拉回来都是新的一批，当前曲找不到是正常的，随机起一首接着放
			if (kind == 'fm') mode = 'loop';

			// 按 id 找当前位置：比记 index 稳，列表刷新过也对得上
			let pos = -1;
			for (let i = 0; i < n; i++) if (int(items[i].id) == cur) { pos = i; break; }

			let next = 0;
			if (pos < 0) {
				if (kind != 'fm') return { ok: true, stop: 1 };
				next = randInt(n);
			}
			else if (mode == 'one') next = pos;
			else if (mode == 'shuffle') next = randInt(n);
			else if (pos + 1 >= n) next = 0;
			else next = pos + 1;

			// 非会员别去碰 VIP / 购买专辑的歌；真去下了却失败（版权/试听限制）也往后跳。
			// 最多试 10 首，别在没网的时候一路空转。
			let vip = int(kvRead(VIPFILE).vip ?? 0);
			let idx = next, tries = 0;
			while (tries < n && tries < 10) {
				let item = items[idx];
				let info = songDetail(int(item.id));
				let fee = int(info ? (info.fee ?? 0) : 1);
				// 播客节目的 mainSong 在 song/detail 里经常查不到，名字只能用列表里的
				if (info == null && int(item.pid ?? 0) > 0) fee = 0;
				let blocked = (info == null && int(item.pid ?? 0) < 1) || ((vip < 1) && (fee == 1 || fee == 4));
				if (!blocked) {
					let r = playSong(int(item.id), `${info ? (info.cover ?? '') : (item.cov ?? '')}`, int(item.pid ?? 0),
						{ name: `${item.name ?? (info ? info.name : '')}`,
						  artist: `${item.artist ?? (info ? info.artist : '')}`,
						  dur: int(item.dur ?? (info ? info.duration : 0)) },
						`${st.origin ?? ''}`);
					if (r && r.ok) return r;
				}
				if (mode == 'one') break;          // 单曲循环但放不了 → 停
				idx = (idx + 1) % n;
				tries++;
			}

			// 一首都没成：把 auto 关掉，免得下次回调又空转
			let st2 = readState();
			st2.auto = 0;
			writeState(st2);
			return { ok: true, stop: 1 };
		},

		// 拖进度：进程播放没有 seek，只能停掉重开，用 -k 跳过前面的帧。
		// 重开会有半秒左右的空档，认了。
		'GET /seek': function(req) {
			let pos = int((req.query ? req.query.pos : -1) ?? -1);
			if (pos < 0) return { ok: false, error: '位置无效' };
			let st = readState();
			let file = st.file ?? '';
			if (length(file) < 1) return { ok: false, error: '没有在播放' };
			let dur = int(st.duration ?? 0);
			// 别贴到最后 1 秒，不然刚起就播完了
			if (dur > 2000 && pos * 1000 > dur - 1000) pos = int(dur / 1000) - 1;
			if (pos < 0) pos = 0;

			let gen = int(time()) * 1000 + randInt(1000);
			st.auto = 0;
			writeState(st);          // 先关续播，旧管道被 kill 时的回调不会跳歌
			stopAll();
			holdWake();
			let sp = startPlayer(file, pos, gen, `${st.origin ?? ''}`);
			if (sp == -2) { dropWake(); return { ok: false, error: '缺少 mpg123 解码器（系统和插件自带的都没找到）' }; }
			if (sp <= 0) { dropWake(); return { ok: false, error: '播放进程没起来' }; }
			wakeWatch();
			ensureWatch();
			st.start = time() - pos;
			st.paused_total = 0;
			st.paused_at = 0;
			st.gen = gen;
			st.auto = 1;
			writeState(st);
			return { ok: true, pos: pos };
		},

		// 暂停/继续/停止：管道里有两个进程（mpg123 和 pacat），两个都要动才有效。
		// 不能用 pkill（busybox 的 -x 不按预期匹配），改成 pgrep 取 pid 再 kill。
		// 心动模式：取一首推荐歌给前端插进队列（前端管队列，后端只负责"推荐什么"）
		'GET /radiopick': function(req) {
			let id = int((req.query ? req.query.id : 0) ?? 0);
			if (id <= 0) return { ok: false, error: '种子无效' };
			let pick = radioTake(id, id);
			if (pick == null) return { ok: false, error: '取不到推荐' };
			return { ok: true, song: pick };
		},

		'GET /next': function(req) { return stepTrack(1); },
		'GET /prev': function(req) { return stepTrack(-1); },

		// "下一首播放"：把 id 排进待播队列。多次添加按添加顺序依次播放。
		// 前端也把它插进自己的队列，但那个只影响界面显示 —— 真正决定播什么的是这里。
		'GET /nextadd': function(req) {
			let id = int((req.query ? req.query.id : 0) ?? 0);
			if (id <= 0) return { ok: false, error: '歌曲 id 无效' };
			let pid = int((req.query ? req.query.pid : 0) ?? 0);
			let q = nextQRead();
			push(q, { id: id, pid: pid });
			nextQWrite(q);
			return { ok: true, n: length(q) };
		},

		'GET /pause': function(req) {
			signalAll('STOP');
			dropWake();   // 暂停时不用按住 CPU
			let st = readState();
			if (st.start != null && int(st.paused_at ?? 0) == 0) {
				st.paused_at = time();
				writeState(st);
			}
			return { ok: true };
		},

		'GET /resume': function(req) {
			signalAll('CONT');
			holdWake();
			wakeWatch();
			let st = readState();
			let pa = int(st.paused_at ?? 0);
			if (pa > 0) {
				st.paused_total = int(st.paused_total ?? 0) + (time() - pa);
				st.paused_at = 0;
				writeState(st);
			}
			return { ok: true };
		},

		'GET /stop': function(req) {
			let st = readState();
			st.auto = 0;             // 手动停就别让回调再续一首
			writeState(st);
			stopAll();
			dropWake();
			return { ok: true };
		},

		// ---- 个性化（都要求已登录） ----
		// 每日推荐
		'GET /daily': function(req) {
			return listSongs('daily', 0);
		},

		// 我喜欢的音乐
		// 不要用 /api/song/like/get 拿 id 再批量查详情 —— 详情接口会漏掉不可用的歌,
		// 顺序也不一定对, 跟 App 里看到的对不上。
		// 正确做法是找到"我喜欢的音乐"那个特殊歌单(specialType=5), 直接读它的详情。
		'GET /liked': function(req) {
			return listSongs('liked', int((req.query ? req.query.uid : 0) ?? 0), '',
				int((req.query ? req.query.offset : 0) ?? 0),
				int((req.query ? req.query.limit : 50) ?? 50));
		},

		// 我的歌单 + 收藏的歌单（subscribed=true 的是收藏的）
		'GET /mylists': function(req) {
			let ck = readSession();
			if (length(ck) < 1) return { ok: false, need_login: true };
			let uid = readUid();
			if (uid <= 0) uid = int((req.query ? req.query.uid : 0) ?? 0);
			if (uid <= 0) return { ok: false, error: '还没有登录' };

			let d = apiGet('/api/user/playlist', sprintf('uid=%d&limit=200&offset=0', uid));
			if (d == null) return { ok: false, error: '网络不太好，歌单没取到' };
			let list = d ? d.playlist : null;
			if (type(list) != 'array') return { ok: false, error: '歌单返回异常' };
			if (type(list) != 'array') list = [];

			let made = [], saved = [];
			for (let p in list) {
				// specialType 5 是"我喜欢的音乐", 已经在"我喜欢"那页了, 这里不重复列
				if (p.specialType == 5) continue;
				let item = {
					id: p.id, name: p.name ?? '', url: p.coverImgUrl ?? '',
					count: p.trackCount ?? 0,
					creator: p.creator ? (p.creator.nickname ?? '') : ''
				};
				if (p.subscribed === true) push(saved, item); else push(made, item);
			}
			fillCovers(made, 'pl');
			fillCovers(saved, 'pl');
			return { ok: true, made: made, saved: saved };
		},

		// 官方私人定制歌单（私人雷达、每日推荐歌单等）
		'GET /reco': function(req) {
			let ck = readSession();
			if (length(ck) < 1) return { ok: false, need_login: true };
			let d = apiGet('/api/v1/discovery/recommend/resource', '');
			if (d == null) return { ok: false, error: '网络不太好，推荐歌单没取到' };
			let list = d ? d.recommend : null;
			if (type(list) != 'array') return { ok: false, error: '推荐歌单返回异常' };
			let out = [];
			for (let p in list) {
				push(out, {
					id: p.id, name: p.name ?? '', url: p.picUrl ?? '',
					count: p.trackCount ?? 0, creator: p.copywriter ?? ''
				});
			}
			fillCovers(out, 'reco');
			return { ok: true, lists: out };
		},

		// 歌单里的歌
		// 歌单分页：点开先给第一页（200 首），滑到底再要下一页。
		// 一次性展开整张表在几千首的歌单上要十几秒，而且用户根本看不到后面。
		'GET /playlist': function(req) {
			let id = int((req.query ? req.query.id : 0) ?? 0);
			if (id <= 0) return { ok: false, songs: [], error: '歌单 id 无效' };
			let off = int((req.query ? req.query.offset : 0) ?? 0);
			let lim = int((req.query ? req.query.limit : 200) ?? 200);
			if (lim < 1 || lim > 500) lim = 200;
			let page = plPage(id, off, lim);
			if (page == null) return { ok: false, songs: [], error: '歌单不存在' };
			return { ok: true, name: page.name, songs: page.songs, total: page.total,
				more: page.more ? 1 : 0, cover: page.cover, desc: page.desc,
				creator: page.creator, count: page.count };
		},

		// 收藏的播客（电台）
		'GET /podcasts': function(req) {
			let ck = readSession();
			if (length(ck) < 1) return { ok: false, need_login: true };
			let d = apiGet('/api/djradio/get/subed', 'limit=50&offset=0');
			let list = d ? d.djRadios : null;
			if (type(list) != 'array') list = [];
			let out = [];
			for (let r in list) {
				push(out, {
					id: r.id, name: r.name ?? '', url: r.picUrl ?? '',
					count: r.programCount ?? 0,
					creator: r.dj ? (r.dj.nickname ?? '') : ''
				});
			}
			fillCovers(out, 'dj');
			return { ok: true, lists: out };
		},

		// 播客里的节目（mainSong 就是要播的曲目）
		'GET /programs': function(req) {
			return listSongs('programs', int((req.query ? req.query.id : 0) ?? 0));
		},

		// 私人 FM
		// 单集点赞 / 取消：Netease 的"点赞节目"是给节目的评论线程点赞，
		// threadId = A_DJ_1_<节目id>，走 weapi（eapi 不给这个接口）。
		'GET /program/like': function(req) {
			let id = int((req.query ? req.query.id : 0) ?? 0);
			let on = `${(req.query ? req.query.on : '1') ?? '1'}` == '1' ? 1 : 0;
			if (id <= 0) return { ok: false, error: '节目 id 无效' };
			let ck = readSession();
			if (length(ck) < 1) return { ok: false, need_login: true };
			let r = weapiCall(on ? '/weapi/resource/like' : '/weapi/resource/unlike',
				sprintf('{"threadId":"A_DJ_1_%d"}', id), ck);
			if (!r || int(r.code ?? 0) != 200)
				return { ok: false, error: '操作失败（可能没登录）' };
			return { ok: true, on: on };
		},

		// 收藏页：专辑/歌手/播客一次给全（服务端缓存 5 分钟）
		'GET /subs': function(req) {
			let ck = readSession();
			if (length(ck) < 1) return { ok: false, need_login: true };
			let s = subsLoad(`${(req.query ? req.query.refresh : '') ?? ''}` == '1');
			return { ok: true, albums: s.albums ?? [], artists: s.artists ?? [],
				podcasts: s.podcasts ?? [] };
		},

		// 某一项是否已收藏（子页按钮的状态）
		'GET /substate': function(req) {
			let kind = `${(req.query ? req.query.kind : '') ?? ''}`;
			let id = int((req.query ? req.query.id : 0) ?? 0);
			if (id <= 0) return { ok: false, error: 'id 无效' };
			if (kind == 'playlist') {
				let uid = readUid();
				let d = json(curl(`'${BASE}/api/user/playlist?uid=${uid}&limit=500&offset=0'`) ?? 'null');
				for (let it in ((d && d.playlist) ?? []))
					if (int(it.id) == id) return { ok: true, on: (it.subscribed == true) ? 1 : 0 };
				return { ok: true, on: 0 };
			}
			let list = subsList(kind);
			for (let x in list) if (int(x.id) == id) return { ok: true, on: 1 };
			return { ok: true, on: 0 };
		},

		// 收藏 / 取消收藏
		'GET /sub': function(req) {
			let kind = `${(req.query ? req.query.kind : '') ?? ''}`;
			let id = int((req.query ? req.query.id : 0) ?? 0);
			let on = `${(req.query ? req.query.on : '1') ?? '1'}` == '1' ? 1 : 0;
			if (id <= 0) return { ok: false, error: 'id 无效' };
			let ck = readSession();
			if (length(ck) < 1) return { ok: false, need_login: true };
			let url = '', method = 'GET';
			if (kind == 'album')
				url = on ? `/api/album/sub?id=${id}` : `/api/album/unsub?id=${id}`;
			else if (kind == 'artist')
				url = on ? `/api/artist/sub?artistId=${id}` : `/api/artist/unsub?artistIds=%5B${id}%5D`;
			else if (kind == 'podcast')
				url = on ? `/api/djradio/sub?id=${id}` : `/api/djradio/unsub?id=${id}`;
			else if (kind == 'playlist') {
				let csrf = csrfOf(ck);
				url = on ? `/api/playlist/subscribe?id=${id}&csrf_token=${csrf}`
					: `/api/playlist/unsubscribe?id=${id}&csrf_token=${csrf}`;
				method = 'POST';
			} else return { ok: false, error: '不支持的收藏类型' };
			let raw = ctx.sh(`curl -s -m 15 -X ${method} -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' -H 'Cookie: ${ck}' '${BASE}${url}' 2>/dev/null`);
			let d = json(raw ?? 'null');
			let code = d ? int(d.code ?? 0) : 0;
			ctx.sh(`rm -f '${SUBS}' 2>/dev/null`);   // 列表缓存作废，下次重拉
			if (code != 200)
				return { ok: false, code: code,
					error: (d && (d.message ?? d.msg)) ? `${d.message ?? d.msg}` : '操作失败' };
			return { ok: true, on: on };
		},

		// 不喜欢（私人FM）：记进本地黑名单，补池子时过滤掉，池子里也立刻删掉。
		// 官方"反馈给推荐算法"的接口是 weapi 加密的，实测现已 404，所以只能做到
		// "本机不再推荐这首"，影响不到云端算法。
		'GET /fm/skip': function(req) {
			let id = int((req.query ? req.query.id : 0) ?? 0);
			if (id <= 0) return { ok: false, error: '歌曲 id 无效' };
			let list = [], seen = {};
			for (let p in split(fmTrashGet(), ',')) {
				let v = int(trim(p) ?? '0');
				if (v > 0 && !seen[v]) { seen[v] = 1; push(list, v); }
			}
			if (!seen[id]) push(list, id);
			if (length(list) > 200) {
				let cut = [];
				for (let i = length(list) - 200; i < length(list); i++) push(cut, list[i]);
				list = cut;
			}
			ctx.sh(`printf '%s' '${join(',', list)}' > '${FM_TRASH}' 2>/dev/null`);
			let pool = fmPoolRead(), keep = [];
			for (let s in pool) if (int(s.id) != id) push(keep, s);
			fmPoolSave(keep);
			// 告诉云端"这首别推了"。路径是 /weapi/radio/trash/add?alg=RT&songId=&time=，
			// 不是老版本的 /weapi/radio/trash/<id>（那个已经 404）。
			let ck = readSession();
			let cloud = 0;
			if (length(ck) > 0) {
				let r = weapiCall(sprintf('/weapi/radio/trash/add?alg=RT&songId=%d&time=25', id),
					sprintf('{"songId":%d}', id), ck);
				if (r && int(r.code ?? 0) == 200) cloud = 1;
			}
			return { ok: true, cloud: cloud };
		},

		'GET /fm': function(req) {
			return listSongs('fm', 0);
		},

		// ---- 登录（扫码） ----
		// GET /login/qr -> {ok, key, url, svg}  svg 直接插到页面里显示
		'GET /login/qr': function(req) {
			let r = eapiCall('/api/login/qrcode/unikey', '{"type":3}', '');
			let body = r ? r.body : null;
			if (body == null || body.unikey == null)
				return { ok: false, error: '取二维码失败（网络或接口变动）' };
			let key = replace(`${body.unikey}`, /[^A-Za-z0-9-]/g, '');
			if (length(key) < 8) return { ok: false, error: '二维码 key 异常' };
			let url = `https://music.163.com/login?codekey=${key}`;
			let svg = ctx.sh(`qrencode -t SVG -o - '${url}' 2>/dev/null`) ?? '';
			return { ok: true, key: key, url: url, svg: svg, logged: length(readSession()) > 0 };
		},

		// GET /login/check?key= -> {ok, code, nickname, avatar}
		//   800 过期 801 待扫 802 已扫待确认 803 成功
		'GET /login/check': function(req) {
			let key = replace(`${(req.query ? req.query.key : '') ?? ''}`, /[^A-Za-z0-9-]/g, '');
			if (length(key) < 8) return { ok: false, error: 'key 无效' };

			let r = eapiCall('/api/login/qrcode/client/login',
					 sprintf('{"key":"%s","type":3}', key), '');
			let body = r ? r.body : null;
			if (body == null) return { ok: false, error: '查询登录状态失败' };

			let code = int(body.code ?? 0);
			if (code == 803) {
				let parts = [];
				for (let c in (r.set_cookie ?? []))
					push(parts, `${c.name}=${c.value}`);
				if (length(parts) > 0) saveSession(join('; ', parts));
			}
			return {
				ok: true, code: code,
				nickname: body.nickname ?? '',
				avatar: body.avatarUrl ?? ''
			};
		},

		// GET /login/me -> 当前登录的账号（没登录则 logged:false）
		// 清缓存：只删歌曲和封面，头像/登录态不动
		'GET /clearcache': function(req) {
			ensureCache();
			let before = int(trim(ctx.sh(`du -sk '${CACHE}' 2>/dev/null | cut -f1`) ?? '0') ?? 0);
			ctx.sh(`rm -f '${CACHE}'/*.mp3 '${CACHE}'/*.part 2>/dev/null`);
			// 单曲封面也在根目录（cover-*.jpg/png + .src），头像 avatar-* 保留
			ctx.sh(`rm -f '${CACHE}'/cover-* '${CACHE}'/*.src 2>/dev/null`);
			ctx.sh(`rm -rf '${CACHE}/c' 2>/dev/null`);
			// 试听标记跟着缓存一起清：歌都删了，标记留着会让下次误判成试听
			ctx.sh(`rm -f /tmp/cx-trial-*.txt 2>/dev/null`);
			let after = int(trim(ctx.sh(`du -sk '${CACHE}' 2>/dev/null | cut -f1`) ?? '0') ?? 0);
			return { ok: true, freed: before > after ? before - after : 0 };
		},

		'GET /login/me': function(req) {
			if (length(readSession()) < 1) return { ok: true, logged: false };
			let d = apiGet('/api/nuser/account/get', '');
			let p = d ? d.profile : null;
			if (p == null) {
				// 会话过期了，清掉
				ctx.sh(`rm -f '${SESSION}' '${UIDFILE}' 2>/dev/null`);
				return { ok: true, logged: false };
			}
			writeUid(p.userId ?? 0);
			// vipType: 0 普通 / 10、11 音乐包 / 110 黑胶 VIP。非 0 就算会员。
			let vt = int(p.vipType ?? 0);
			kvWrite(VIPFILE, { vip: vt > 0 ? 1 : 0 });

			// 头像也要下到本地：web 进程没有 TLS，https 的地址直接放不出来
			let uid = int(p.userId ?? 0);
			let avatar = '';
			let url = replace(`${p.avatarUrl ?? ''}`, /'/g, '%27');
			if (uid > 0 && length(url) > 8) {
				let name = `avatar-${uid}.jpg`;
				let target = `${CACHE}/${name}`;
				if (sizeOf(target) < 1000) {
					ctx.sh(`mkdir -p '${CACHE}' 2>/dev/null`);
					ctx.sh(`curl -sL -m 20 -o '${target}.part' -H 'Referer: ${BASE}' -H 'User-Agent: ${UA}' '${url}' 2>/dev/null`);
					if (sizeOf(`${target}.part`) > 1000)
						ctx.sh(`mv -f '${target}.part' '${target}' 2>/dev/null`);
					else
						ctx.sh(`rm -f '${target}.part' 2>/dev/null`);
				}
				if (sizeOf(target) > 1000) avatar = `/plugins/netease/cache/${name}`;
			}

			return { ok: true, logged: true, uid: uid,
				 nickname: p.nickname ?? '', avatar: avatar,
				 vip: vt > 0 ? 1 : 0, vip_type: vt };
		},

		'GET /logout': function(req) {
			// 退出登录：后端也要负责收尾，不能只靠前端清界面 ——
			// 否则页面一重进，/status 还把上一个账号那首歌报成"在放"
			let st = readState();
			st.auto = 0;
			writeState(st);
			stopAll();
			dropWake();
			ctx.sh(`rm -f '${SESSION}' '${UIDFILE}' '${VIPFILE}' '${PLAN}' '${LIKED}' '${STATE}' 2>/dev/null`);
			return { ok: true };
		},

		// 音乐音量。交给宿主自己的 /usr/libexec/e5-volume：
		// 它同时写 uci 和 pactl，所以不会被 e5-audio 定时施加的音量覆盖回去。
		// 16 档（0 静音 - 15），映射到我们界面的 0..100%。
		//   GET /volume            读
		//   GET /volume?set=0..100 设
		'GET /volume': function(req) {
			let want = req.query ? req.query.set : null;
			if (want != null) {
				let n = int(want);
				if (n < 0) n = 0;
				if (n > 100) n = 100;
				let lv = (n * 15 + 50) / 100;
				ctx.sh(`${VOLUME} set ${lv} >/dev/null 2>&1`);
			}
			let out = trim(ctx.sh(`${VOLUME} 2>/dev/null`) ?? '');
			let d = json(out);
			if (d == null || d.level == null) return { ok: false, volume: -1 };
			let lv = int(d.level);
			let pct = (lv * 100 + 7) / 15;
			if (pct > 100) pct = 100;
			return { ok: true, volume: pct, level: lv };
		},

		// 前端启动/回到前台时读它，用来恢复界面
		'GET /status': function(req) {
			let st = readState();
			// pid 文件里存的 setsid 包装进程 fork 完就退出了，所以按 pacat 进程判断在不在放
			let n = int(trim(ctx.sh(`pgrep -x pacat | wc -l`) ?? '0') ?? 0);
			let alive = n > 0;
			let paused = int(st.paused_at ?? 0) > 0;
			if (!alive && st.start == null) return { ok: true, playing: false };

			let start = int(st.start ?? 0);
			let dur = int(st.duration ?? 0);
			let pt = int(st.paused_total ?? 0);
			let pa = int(st.paused_at ?? 0);
			let now = time();

			// 正在暂停就冻结在暂停那一刻
			let elapsed = (pa > 0 ? pa : now) - start - pt;
			if (elapsed < 0) elapsed = 0;
			let done = dur > 0 && elapsed * 1000 >= dur;

			return {
				ok: true,
				// 三个字段各有分工，别混用：
				//   active  = 会话还在（进程活着、没放完）。暂停时仍然是 true，
				//             前端靠它决定"要不要把界面接回来 / 要不要当成还在放"。
				//   playing = 真的在出声。暂停是 SIGSTOP，进程还挂着，所以必须排除 paused。
				//   paused  = 被暂停了。
				// 以前只有 playing 一个字段兼着前两个含义，于是暂停时会同时报
				// playing:true 和 paused:true，接口语义自相矛盾。
				active: alive && !done,
				playing: alive && !paused && !done,
				paused: paused,
				id: int(st.id ?? 0),
				name: st.name ?? '',
				artist: st.artist ?? '',
				artists: artistParse(st.artists),
				pid: int(st.pid ?? 0),
				trial: int(st.trial ?? 0),
				trialSec: int(st.trial_sec ?? 0),
				// 封面文件可能已经不在了（重装插件会清 cache，或者当初就没下成）。
				// 发个死路径给前端只会静默 404，底栏就是一片空白，而且歌一直在放，
				// 永远不会再走 playSong —— 所以这里补一次下载。
				// 限频 10 秒，别让每秒一次的 status 去打网易的接口。
				cover: (function () {
					let c = `${st.cover ?? ''}`;
					if (length(c) > 0 && sizeOf(replace(c, '/plugins/netease/cache', CACHE)) > 0)
						return c;
					let id = int(st.id ?? 0);
					if (id <= 0) return '';
					let stamp = `/tmp/netease-coverfix-${id}`;
					let last = int(trim(ctx.sh(`cat '${stamp}' 2>/dev/null`) ?? '0') ?? 0);
					if (last > 0 && time() - last < 10) return '';
					ctx.sh(`printf '%d' '${time()}' > '${stamp}' 2>/dev/null`);
					let info = songDetail(id);
					return ensureCover(id, info ? `${info.cover ?? ''}` : '');
				})(),
				duration: dur,
				elapsed: elapsed
			};
		}
	};
};
