# 信息屏应用商店 / Info screen app store

荣悦 E5 OpenWrt 信息屏（[e5-infoscreen](https://github.com/Enceka/e5-infoscreen)）的应用商店。
屏幕上：高级 → 应用管理 → 应用商店。每次推送到 `main`，CI 检查所有应用，打包后发布到
GitHub Pages（`https://enceka.github.io/infoscreen-plugins/index.json`），设备从那里读取。

The app store of the E5 OpenWrt info screen.  On the screen: 高级 -> 应用管理 -> 应用商店.  Each push to
`main` checks every app, packs them and publishes the store on GitHub Pages, where the devices read it.

## 提交一个应用 / Adding an app

1. `plugins/<id>/`：`manifest.json`、页面（默认 `index.html`），需要后台时加 `backend.uc`。
   接口见 e5-infoscreen 的 [docs/API.md](https://github.com/Enceka/e5-infoscreen/blob/main/docs/API.md)
   第 5 节；`plugins/bigclock` 是个最小的例子。
2. 本地检查：`python3 tools/check.py`，打包试试：`python3 tools/build.py`（生成 `dist/`）。
3. 提 Pull Request；CI 通过、审阅之后合并，下一次发布就上架了。改版本时提高 `version`，
   屏幕据此显示“更新”。

## 规则 / The rules (tools/check.py)

* **manifest**：`id` 与目录名相同（小写字母、数字、`-`、`_`，最多 32 个字符）；`api_version`
  是屏幕支持的（目前 1）；`version` 是点分数字；`name` 和 `description` 都要有 `zh` 和 `en`；
  `entry` 是应用里的文件；设置项的 `uci` 用 `e5-plugin-<id>.<section>.<option>`。
* **文件**：只允许 html、js、css、json、uc、svg、txt、md 和常见图片、woff2；没有隐藏文件、
  没有链接；整个应用不超过 2 MB。
* **风格**：UTF-8，LF 换行，文件以换行结尾，行尾没有空格。
* **安全**：前端不加载别的主机的脚本和样式，不直接请求外网（需要时通过后台），不用
  `eval`、`new Function`、`document.write`、带字符串的 `setTimeout`。
* **后台**（`backend.uc`）以 root 运行：检查会列出它执行命令、写删文件、发 AT 指令、改 uci
  的地方，审阅时逐条看过才合并。商店里标明“含后台”。

## 许可 / License

MIT（见 `LICENSE`）；每个应用可在自己的目录里另附许可。
