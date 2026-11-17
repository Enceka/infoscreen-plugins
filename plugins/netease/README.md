# 网易云音乐 / NetEase Cloud Music

信息屏插件。扫码登录后播放自己的网易云内容。播放由后端的 `mpg123 | pacat`
完成，音频先下到本机缓存 —— 设备上缺 `scaletempo`，浏览器 `<audio>` 放不了。

## 功能

- 五个分类：每日推荐 / 我喜欢 / 私人 / 歌单 / 播客
- 顶栏 `FM` 按钮：私人FM 不是一个分类页，而是"开一个电台"的**动作** ——
  点一下拉歌、立刻起播、直接进沉浸式播放页（播放中按钮变绿）
- **没有自己的标题栏**：信息屏宿主的 `#mobile-toolbar` 已经显示应用名，插件顶部只有
  一行「分类 chips + 账号按钮」；列表说明（多少首 / 哪张歌单）作为列表第一行跟着滚
- 单曲列表点选即播，放完自动下一首
- 底部播放条：封面、歌名、上一首 / 播放暂停 / 下一首 / 播放列表、进度时间
- 点播放条的空白处展开**沉浸式播放页**（模糊封面背景 + 大封面 + 可拖进度 + 控制），
  点左上角箭头收起；点播放条上的按钮不算展开
- 沉浸页**点一下封面/歌名切到歌词页**：逐行滚动、当前行高亮放大，非中文歌下面
  还带一行中文翻译；在歌词页里轻点一下回封面（拖动是翻看，不会退出）
- 沉浸页顶栏：红心 `喜欢`（真接口，状态同步到账号）/ `不想听`（本次移除跳下一首）/ 播放列表
- **点歌手名跳歌手页**：单个歌手直接进，多个（`A / B`）先弹一个选择浮层。
  歌手页是全屏独立页，分「歌曲」「专辑」两栏：
  - 歌曲：热度只给 50 首（代表作），切到时间排序可以一直往下翻到全部
    （Beyond 四万多首也只渲染可视区上下各 50 行，滑动不卡）
  - 专辑：两列封面网格，显示专辑名 / 年份 / 曲目数，点进去是专辑曲目
- 播放列表浮层：当前曲高亮、点哪首跳哪首；播放顺序在沉浸页顶栏切
- 扫码登录（eapi 加密），换号重扫一次即可；账号按钮在分类行最右边
- 退出应用再进来能接上正在放的歌：页面被 e5 整个重载，但队列和序号存在
  `localStorage`，播放进程还在后端，所以界面重挂封面/进度，上一首下一首照样能用

不做自由输入 —— 屏幕上没有键盘（`e5.input()` 是给输入法插件往宿主输入框写字的，
不是让宿主给插件弹键盘），所以用分类代替搜索框。

## 依赖

这个插件本身没有额外依赖，但**信息屏所在系统必须先具备播放 MP3 的能力**，
否则点了没反应、日志里会出现 `no suitable plugins found`。实测在 OpenWrt 25.12.5
（aarch64_generic）上需要补这些包：

```sh
apk add gst1-mod-mpg123          # MP3 解码器
apk add gst1-mod-audioparsers    # mp3parse 等码流解析
apk add gst1-mod-autodetect      # autoaudiosink：自动选输出
apk add gst1-mod-id3demux        # ID3 标签解复用 —— 缺这个会报
                                 #   Missing decoder: ID3 tag (application/x-id3)
apk add gst1-mod-debugutilsbad   # fakevideosink —— WebKit 建播放管线时必需，
                                 #   即使只放音频，缺了整条管线都建不起来
apk add gst1-mod-soup            # souphttpsrc（v0.2 起走本地缓存，其实用不到，留着无害）
apk add gstreamer1-utils         # gst-inspect / gst-launch，排查用
```

另外 `scaletempo` 在本仓库里没有对应包，WebKit 会打一条警告（只影响变速播放），
不影响正常播放。

### 音频输出

设备上 PulseAudio（`--system`）占用 `hw:CARD=sprdphonesc2730,DEV=3`，
而 `hw:0,0` 那个前端 PCM 没有路由，直接写会 `I/O error`。
GStreamer 只有 alsa 输出插件，所以把 ALSA 默认设备指到能用的那个：

```
# /etc/asound.conf
pcm.!default { type plug  slave.pcm "hw:0,3" }
ctl.!default { type hw    card 0 }
```

PulseAudio 加载了 `module-suspend-on-idle`，空闲会释放声卡，两边可以共存。
副作用：**音乐播放期间来电铃声可能出不来**。

音量交给宿主自己的 `/usr/libexec/e5-volume`（16 档，0 静音 - 15），
它会同时写 uci 和 pactl，所以不会被 `e5-audio` 定时施加的音量覆盖回去：

    level 1 -> 6%   level 5 -> 33%   level 10 -> 66%   level 15 -> 100%

插件以前在顶部做过 `− / 百分比 / ＋`，现在去掉了：音量和亮度的入口都在信息屏
自己的「设置」页里，插件不该再画一套。`/api/plugins/netease/volume` 接口保留着。

**踩过的两个坑**（都表现为"静音反而最大声 / 音量根本不生效"）：

1. 播放最早用 `mpg123 -o alsa` **直连 ALSA**，绕过了 PulseAudio，
   于是 PulseAudio 的音量完全管不到它，永远是硬件满响。
   改成 `mpg123 -o raw | pacat` 走 PulseAudio 才对。
2. 用 `pactl set-sink-volume` 手改音量会被 `e5-audio` 按 uci 里的档位**改回去**。
   必须走 `e5-volume`，它两边一起改。

### 音频输出

设备上 PulseAudio（`--system`）占用 `hw:CARD=sprdphonesc2730,DEV=3`，
而 `hw:0,0` 那个前端 PCM 没有路由，直接写会 `I/O error`。
GStreamer 只有 alsa 输出插件，所以把 ALSA 默认设备指到能用的那个：

```
# /etc/asound.conf
pcm.!default { type plug  slave.pcm "hw:0,3" }
ctl.!default { type hw    card 0 }
```

PulseAudio 加载了 `module-suspend-on-idle`，空闲会释放声卡，两边可以共存。
副作用：**音乐播放期间来电铃声可能出不来**。

注意：信息屏自带的 `e5-volume` 在 PulseAudio 运行时是走 `pactl` 改 sink 音量，
而插件的 `mpg123` 直连 ALSA，绕过了这一层 —— 实测 `e5-volume set 8` 之后
`amixer` 里 `'VBC DAC0 DG Set'` 还是 39，对它完全无效。

所以插件自己直接调**硬件 DAC 增益** `'VBC DAC0 DG Set'`（0-127，上限 39 是
设备自己 Android 媒体播放用的增益，别再往上加）：

    0%   -> raw 0   （静音，-inf dB）
    100% -> raw 39  （-36 dB，与 Android 一致）

这是真正的硬件音量，mpg123 直连 ALSA 也照样受控。
（插件界面上的音量按钮已经删掉，改音量走信息屏的「设置」。）

（中间试过用 ALSA `softvol` 做独立音量，但 0% 时表现不对（反而变响），
已放弃，`/etc/asound.conf` 恢复成单纯的 `plug -> hw:0,3`。）

### 音频输出

设备上 PulseAudio（`--system`）占用 `hw:CARD=sprdphonesc2730,DEV=3`，
而 `hw:0,0` 那个前端 PCM 没有路由，直接写会 `I/O error`。
GStreamer 只有 alsa 输出插件，所以把 ALSA 默认设备指到能用的那个：

```
# /etc/asound.conf
pcm.!default { type plug  slave.pcm "hw:0,3" }
ctl.!default { type hw    card 0 }
```

PulseAudio 加载了 `module-suspend-on-idle`，空闲会释放声卡，两边可以共存。
副作用：**音乐播放期间来电铃声可能出不来**。

注意：信息屏自带的 `e5-volume` 在 PulseAudio 运行时是走 `pactl` 改 sink 音量，
而插件的 `mpg123` 直连 ALSA，绕过了这一层，所以**它的音量不生效**。
为此 `pcm.!default` 底下套了一层 ALSA 内置的 `softvol`：

```
pcm.!default { type plug  slave.pcm "cxmusic" }
pcm.cxmusic {
    type softvol
    slave.pcm "hw:0,3"
    control { name "CX Music" }     # amixer -c 0 sget/sset 'CX Music'
    min_dB -51.0
    max_dB 0.0
    resolution 100
}
```

这个控件**要在第一次打开 PCM 之后才存在**，所以刚开机还没放过任何声音时读不到。

## 接口

后端（`backend.uc`，ucode）用 curl 访问网易云，全部是免加密的公开接口：

| 接口 | 作用 |
|---|---|
| `GET /api/plugins/netease/search?q=` | `/api/search/get/web`，中文由 `curl -G --data-urlencode` 编码 |
| `GET /api/plugins/netease/detail?id=` | `/api/song/detail/?ids=%5B<id>%5D`，拿封面 |
| `GET /api/plugins/netease/play?id=` | 下载到本地缓存，返回同源 http 地址 |

### 为什么要把歌下下来

两个原因：

1. 设备上 GStreamer 缺 glib 的 TLS 后端（`/usr/lib/gio/modules` 为空，仓库里也没有
   `glib-networking`），`souphttpsrc` 放不了 https。走 `127.0.0.1` 的 http 绕开 TLS。
2. 插件前端本来就不该直接访问外网（应用商店的规则）。

顺带的好处是同一首歌第二次播放是秒开的。缓存最多保留 20 首，超过删最旧的；
小于 20KB 的下载结果按失败处理（错误页或试听碎片）。

## 播放控制

播放由后端的 `mpg123` 进程完成，前端只发指令：

| 接口 | 作用 |
|---|---|
| `GET /api/plugins/netease/play?id=` | 下载（如未缓存）→ 杀掉上一首 → 起 `mpg123 \| pacat` |
| `GET /api/plugins/netease/pause` | `kill -STOP` 播放进程 |
| `GET /api/plugins/netease/resume` | `kill -CONT` |
| `GET /api/plugins/netease/stop` | `kill -9` 并清 pid 文件 |
| `GET /api/plugins/netease/status` | 有没有 `pacat` 进程 + 状态文件，算出在放/暂停/放完 |
| `GET /api/plugins/netease/seek?pos=<秒>` | 拖进度：停掉旧进程，用 `mpg123 -k <帧>` 跳过前面重开 |
| `GET /api/plugins/netease/volume[?set=0..100]` | 转成 0..15 档交给 `e5-volume` |

进度条是**前端本地计时**（后端不回报播放位置），时长取歌曲详情的 `duration`。

拖动进度只能靠重开进程：`mpg123` 没有按秒 seek，只有 `-k` 跳帧。44.1k 下每帧
1152 采样，正好 38.28125 帧/秒（实测 765 帧 = 19.9 秒，对得上）。代价是松手后
有半秒左右的空档，并且跳过的位置丢了 bit reservoir，起播那几帧会有一点点杂音。

## 播放期间不让 CPU 睡

内核是 `CONFIG_PM_WAKELOCKS=y`，所以挂个名字在 `/sys/power/wake_lock` 里就不会
进 `mem` 睡眠。不挂的话 CPU 一睡，`pacat` 的 DMA 就供不上数据，听感就是"音乐停了"。

- `/play`、`/resume`、`/seek` 之前 `holdWake()`，`/pause`、`/stop` 里 `dropWake()`；
- 一首歌自然放完没人调 `/stop`，所以起一个看门狗：`pacat` 消失后再等 8 秒
  （切歌那一秒的空档不算），还没回来才解锁，然后把 pid 文件删掉；
- 锁名固定 `netease-play`，重复挂/放是幂等的；`/pause` 会主动松手，暂停时不白耗电。

注意这是**系统级**的锁，插件崩了不释放的话机器就睡不着，所以看门狗是必须的。

## 喜欢 / 不想听 / 歌手页

沉浸页顶栏三个按钮：红心（喜欢）、「不想听」、播放列表。

| 接口 | 作用 |
|---|---|
| `GET /like?id=` | 查是否已喜欢（查的是全量喜欢列表的缓存，见下） |
| `GET /like?id=&set=1\|0` | 喜欢 / 取消喜欢，走 `/api/song/like?trackId=&like=&timestamp=` |
| `GET /artist?id=&offset=&limit=` | 歌手歌曲分页（`order=hot`），第一页额外带歌手名/头像/总数 |

**喜欢**是真的写账号：`/api/song/like?trackId=&like=true|false&timestamp=`，红心状态
会同步到 App 的「我喜欢的音乐」。

**喜欢状态怎么查**：网易云没有"单曲是否喜欢"的轻量接口，`/api/song/like/get?trackIds=[id]`
返回的是**全量**已喜欢 id（实测 3254 个）。所以后端把它整份缓存到
`/tmp/netease-liked.txt`（10 分钟有效），单个 id 只在缓存串里查。第一次进沉浸页
可能要多等半秒，之后都是本地查。

**「不想听」只是这次不听**：把当前这首从 `songs` 里删掉、跳下一首，不写任何黑名单，
下次进同一个列表它还在。

> 想要"永远不播这首"的语义做过一版本地黑名单（`/tmp/netease-dislike.txt` + 续播跳过），
> 后来去掉了 —— 普通歌曲网易云没有可用的 dislike 接口（`/api/song/dislike`、`/api/dislike`、
> `/api/v1/dislike`、`/api/radio/dislike`、eapi 走 `/api/dislike` 全是 404），
> 自己造一个黑名单容易让人困惑"这首歌怎么永远不播了"。

**歌手页**借用主列表：`songs` 换成歌手的歌 + `listSrc={kind:'artist',sid}`，
这样播放、自动续播、队列都沿用原来那套，不用再造一个页面。

**分页**：一页 100 首（`/api/v1/artist/songs?id=&offset=&limit=&order=`），列表滚到底
自动续一页，顶部说明显示「已加载 N / 共 M 首」。

**排序**：`order=hot`（热度，默认）/ `order=time`（发行时间）。歌手页时分类行会换成
`[← 返回] [热度/时间] [账号]` 三个按钮，点排序按钮换一种排法并从第一页重载。
两种排序的"已加载"缓存也是分开的两个文件，互不污染。

**返回**：进歌手页时把原列表（songs/index/来源/说明/哪个 tab）存进 `backState`，
点返回原样还原并把 `backState` 清掉；应用重进后没有 `backState`，返回就落到每日推荐。

自动续播要按"同一份顺序"找下一首，但每次重拉整份歌手歌单太重（椎名豪 1578 首），
所以**前端加载过的页会攒在 `/tmp/netease-artist-<id>.txt`**（只存 `id:fee`），
`/_auto` 直接读这份缓存定位；没加载过就拉第一页 200 首兜底。

## 主题（明暗 + 强调色）

插件跑在 iframe 里，拿不到宿主的 CSS 变量，所以自己读一遍配置：

- 后端 `GET /theme` → `uci -q get e5-infoscreen.main.ui_theme / ui_accent`；
- 前端把结果打在 `body[data-theme]` / `body[data-accent]` 上，`documentElement` 的
  `color-scheme` 一起切；
- 样式里所有颜色都走 `var(--*)`，取色跟宿主 mobile.css 对齐：
  深色 `--bg:#0c121b --card:#18212e --line:#283444 --text:#f1f5fa --dim:#96a5b9`，
  浅色 `--bg:#edf2f7 --card:#ffffff --line:#c6d2df --text:#17283b --dim:#50647a`；
  强调色 teal `#85ebcd` / blue `#89c6ff` / violet `#c3adff`，
  浅色下分别是 `#086c57` / `#195ca0` / `#7041a5`；
- 强调色还派生出 `--accent-soft`（选中行底色）和 `--accent-line`（描边），一起给。
- 沉浸页单独一组 `--now-bg/--now-fg`：浅色下把封面模糊层的 `brightness` 从 .32 提到 1.75，
  否则深色字会压在暗背景上。

启动时应用一次，每次打开沉浸页再刷一次（中途在设置里改了主题也能跟上）。

## 播客：名字和封面从队列带进来

播客节目的 `mainSong` 在 `/api/song/detail` 里查不到名字（露出来是空串），
所以只靠 `songDetail` 记状态的话，退出重进应用播放栏就只剩空白。

现在 `/play` 额外接受 `name` / `artist` / `dur`（前端用队列里的值填），
`playSong(id, cov, pid, meta)` 里 **meta 优先于 songDetail**；
后台续播也会把 `songs[next]` 的三个字段传进去。

播客没有"喜欢"这个概念，所以沉浸页在 `pid > 0` 时**直接隐藏喜欢按钮**
（曾经做过"点赞 + 赞过的单集"，但网易云 `/api/dj/program/like` 各种参数都返回 400，
只能存本地、不同步账号，实用性太差，已移除）。

## 播客节目的封面

播客（电台节目）**没有专辑图**：`mainSong.album.picUrl` 指向的是网易云的通用占位图
（`0ju8ET1ApZSXfWacc4w49w==` 那张灰图），所以直接取 `songDetail` 只能拿到占位图。

正确来源是节目自己的 `coverUrl`（和 `radio.picUrl` 一样）。所以：

- `/programs` 归一化时给每一项带上 `cov: coverUrl`；
- 前端 `/play` 带上 `&cov=<urlencoded>`；
- `playSong(id, cov)` 里 **cov 优先于 songDetail 的封面**；
- 后台续播同样把 `songs[next].cov` 传进去。

## 集合封面（歌单/电台/私人推荐）

这几页返回的 `coverImgUrl` / `picUrl` 都是 `http(s)://p1.music.126.net/...`，
web 进程没有 TLS 后端，直接当背景图放不出来 —— 所以后端统一下到
`cache/c/<前缀>-<id>.jpg` 再返回本地路径：

- 一次要几十张，攒成**一条 shell 并行下**（每 20 个 `wait` 一次），不是一张一张等；
- URL 没有 `param=` 的话补 `?param=200y200`：原图 500KB+，缩略图 15KB 左右；
- `cache/c/` 不在 `pruneCache` 的范围内（它只管顶层），单独按数量清到 120 张以上；
- 前缀区分来源：`reco-` / `pl-` / `dj-`。

## 沉浸页背景取色

不再把专辑图整张糊上去，而是取它的主色做渐变：

1. 封面缩到 16×16 画到 canvas，`getImageData` 读像素（图是同源缓存，不会污染 canvas）；
2. 按高 4 位量化成色桶，统计出现次数，取前三个**彼此距离 > 42** 的颜色（跳过纯黑纯白）；
3. 深色主题把颜色 ×0.40 压暗、浅色主题往白里混 82%，写进 `--c1/--c2/--c3`；
4. `#now .bg` 用三个径向渐变叠在 `--now-bg` 上，再 `blur(6px)`。

结果按封面路径缓存（`palSource`），换歌才重算；主题切换时用缓存的原色重新映射一遍。

## 歌词

后端 `GET /lyric?id=` 拉 `https://music.163.com/api/song/lyric?id=<id>&lv=1&kv=1&tv=-1`，
把 `lrc.lyric` 和 `tlyric.lyric`（翻译，非中文歌才有）按时间戳合并成
`[{t: 毫秒, s: 原文, tr: 翻译}]` 返回。

- LRC 解析全手写：这台 ucode 对带反斜杠的正则（`\d`、`\s`）会处理错，
  所以 `[mm:ss.xxx]` 是逐字符切的；`[by:]`、`[ti:]` 这类头信息自然被跳过；
- 翻译跟原文完全一样的会置空，免得重复显示；
- 前端只在歌词页可见时按 `posMs` 找当前行，切行时把该行滚到中间（260ms 缓动）；
- 用户手动滚过之后 3.5 秒内不抢滚动位置，只更新高亮。

## 私人FM

它不是一个分类页，而是**沉浸式播放的快捷入口**：顶栏那个 `FM` 按钮点一下就拉一批歌、
立刻从第一首起播、并直接打开沉浸式播放页；播放期间这个按钮是绿底高亮，
表示"现在放的是 FM 流"。

（早先它是分类行里的一个 tab，后来改成按钮 —— 因为它压根没有列表页的意义。）

- 沉浸页里**没有播放列表入口**（FM 没有队列可言），只剩 `红心 / 不想听 / 上下首 / 暂停`；
  底栏那个队列按钮在 FM 模式下也一起隐藏（`paintModeChrome()` 统一管）。
- 接口 `/api/v1/radio/get` 一次只给 3 首左右，前端连拉 3 拨去重后凑一屏，上一首/下一首才有点余地。
- 续播是"流"的语义：后端发现当前曲**不在**新拉回来的批次里（FM 每次都换一批），
  就随机挑一首接着放，而不是停住；`mode` 在 FM 下强制当 `loop`。

## 放完自动下一首（由后端负责）

息屏会把信息屏的浏览器会话整个关掉，前端计时器根本活不到一首歌放完，所以续播
不能放在页面里。现在的分工是：

1. 前端切列表/切播放顺序时调 `GET /plan?kind=daily|liked|fm|playlist|programs&sid=&mode=`，
   只告诉后端"列表是哪来的"，不传整个列表；
2. 播放管道执行完（`mpg123 | pacat` 退出）后会自己 `curl /_auto?gen=<gen>`；
3. `/auto` 按同一份接口把列表重新拉一遍、按 id 找到刚才那首的位置，按播放顺序取下一首；
4. 每首歌的 `gen` 都不一样：被 kill 的旧管道回调带的是旧 gen，对不上就忽略，
   避免切歌/拖进度时被旧回调顶掉。

前端因此不再自己计时切歌，改成每 2 秒问一次 `/status` 对账：id 变了就把界面换过去，
连续两次 `playing:false` 才认为停了（切歌那一秒空档不算）。

## 非会员跳过 VIP 歌曲

`/login/me` 会带 `vip`（`vipType > 0` 就算会员，实测黑胶是 110，音乐包是 10/11）。

- 非会员时，`fee` 为 1（VIP）或 4（购买专辑）的歌在列表里压暗；
- 点到或自动切到这类歌，不报错停下，直接跳到下一首能放的，底栏提示一句
  "《xxx》是会员歌曲，已跳过"；整个列表都没得放才停。
- 后端续播时同样跳过；**下下来了却失败**（版权/试听限制）的也往后跳，最多试 10 首。

## index.html 只是跳板（绕开 WPE 缓存）

改完插件在信息屏上重进应用还是旧界面 —— uhttpd 只给 `ETag` / `Last-Modified`、不给
`Cache-Control`，WPE 于是走启发式缓存，同 URL 直接被命中。

所以真正的页面叫 **`main.html`**，`index.html` 只有几行：

```js
location.replace('main.html?t=' + Date.now() + (q ? '&' + q : ''));
```

每次 URL 都带新的时间戳，磁盘/内存缓存都命不中；跳板本身几乎不改，被缓存也无所谓。
`?lang=zh` 会一起转发过去。

**改插件时记得两个文件都要拷**：

```sh
cat > /etc/e5-infoscreen/plugins/netease/index.html < plugins/netease/index.html
cat > /etc/e5-infoscreen/plugins/netease/main.html  < plugins/netease/main.html
```

页面启动日志现在是 `[netease] ready ... q=?t=...&lang=zh ver=2026-11-03T14-14`，
`ver` 和行号一起看就知道跑的是不是新版。

## 播放队列 vs 正在浏览的列表

这两份数据在很长一段时间里是同一个 `songs`，于是有个很烦的 bug：去看别的歌单/歌手，
再点"下一首"，队列就被当前页那个列表整个顶掉了。

现在分开：

| | 变量 | 什么时候变 |
|---|---|---|
| 播放队列 | `songs` / `index` | 点列表里某一首（`startQueue`）、不想听、FM 起播、后端续播 |
| 正在浏览 | `viewSongs` / `viewSrc` | 切分类、进歌单、进歌手页、翻页 |

- `renderSongs()` 渲染 `viewSongs`，高亮靠**按 id 比对**队列当前曲（不在这页里就没高亮）；
- 浏览只是浏览：不写 localStorage、不改 `/plan`（续播计划），所以看别的列表不会影响正在放的东西；
- 点列表里任意一首才 `songs = viewSongs.slice()` 并把 `listSrc = viewSrc`，这时才 `saveQueue` + `syncPlan`；
- 歌手页的返回、排序按钮看 `viewSrc`；FM 高亮看 `listSrc`（放的是不是电台流，跟你在看哪页无关）。

## 播放列表和播放顺序

- 底栏最右边和沉浸页右上角都能打开播放列表：当前曲目高亮，点哪首跳哪首。
- 播放顺序四种，点列表头的按钮循环切换，存在 `localStorage`：
  列表循环（默认）/ 单曲循环 / 随机播放 / 顺序播放（放完最后一首停）。
- 随机播放时"上一首"按走过的历史往回退（`hist` 栈），不是再随机一次。

## 已知限制

- 只有 128k 码率（`song/media/outer/url` 的上限）
- 「我喜欢」只取前 1000 首（接口分页没做，3254 首的歌单会截断）
- 会员专享/版权受限的歌会解析失败，界面上会提示
- 拖动进度会重开播放进程，松手有半秒空档，跳点开头几帧可能有轻微杂音
- 只有沉浸页能拖进度，底栏那条 4px 的进度条只能看
- 硬件的音量键没有接到这里，改音量走信息屏「设置」页里的音量档位
- 歌词只有整行（LRC），没有逐字（yrc）

## 安装

```sh
mkdir -p /etc/e5-infoscreen/plugins/netease
cp manifest.json index.html backend.uc /etc/e5-infoscreen/plugins/netease/
ln -sfn /etc/e5-infoscreen/plugins/netease \
        /usr/share/e5-infoscreen/www/plugins/netease     # 没有这个链接，应用列表里看不到
/etc/init.d/e5-infoscreen restart
```

## 歌单为什么是分页的（2026-11-05）

`/api/v6/playlist/detail` 返回的 `playlist.tracks` 只给**前 20 首**，完整顺序在
`playlist.trackIds` 里。所以：

- 后端 `plMeta(sid)` 只缓存 **id 顺序 + 歌单名**（`/tmp/netease-pl-<sid>.json`，
  6 小时有效），不展开整张表；
- `GET /playlist?id=&offset=&limit=`（默认 200、上限 500）按页取详情，
  返回 `{songs, total, more}`；
- 前端点开歌单只拿第一页，滑到底再要下一页（和歌手页共用 `loadMoreList()`）；
- 续播（`/_auto`）和上下一首（`/next` `/prev`）走 `orderItems()`：只按缓存里的
  id 顺序找下一首，再单独取那一首的详情，不再每首歌把整张歌单展开一遍。

一个 8698 首的歌单：第一页 2 秒（缓存后 0 秒），末页 98 首，`total=8698` 完整。
早先一次性展开要 20 秒，而且因为分批丢失只回来 3612 首。
