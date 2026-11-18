# 天气（weather）

信息屏上的天气应用：当前天气、逐小时预报、15 天预报、空气质量，背景有跟随天气变化的动画。

## 功能

- **自动定位**：按公网 IP 定到市（自治区按地级市，直辖市按区）
- **手动选城市**：省 → 市 → 区县三级列表，31 省 / 341 市 / 2978 区县，不需要输入法
- **当前天气**：温度、天气、体感、空气质量（AQI + 主要污染物）
- **逐小时**：24 小时温度、天气、AQI
- **15 天预报**：最高低温、天气、降水概率、日出日落
- **详情**：湿度、风向风速、气压、紫外线、能见度
- **背景动画**：按天气类型播放，日/夜两套配色
- **卡片配色**：跟随日夜切换（夜间深色卡片，白天浅色）

## 数据来源

天气数据来自小米天气的公开接口，不需要注册或申请 key：

```
https://weatherapi.market.xiaomi.com/wtr-v3/location/city/geo      经纬度 → 城市
https://weatherapi.market.xiaomi.com/wtr-v3/location/city/search   城市名 → 城市
https://weatherapi.market.xiaomi.com/wtr-v3/weather/all            全部天气数据
```

空气质量来源是中国环境监测总站（CNEMC），随天气接口一起返回。

定位：

- 首选 `myip.ipip.net` —— 给中文地名，精度到市/州
- 兜底 `ipinfo.io` —— 给经纬度

**为什么不用 `ip-api.com`**：实测同一个移动网络 IP，`ip-api` 报的城市与实际位置
相差三千多公里，`ipinfo` 只到运营商的大区中心，`myip.ipip.net` 报的地名最接近。
所以先用 `myip` 拿名字，再拿名字去小米的 `city/search` 换坐标。

## 背景动画

7 种动画，算法和参数移植自 [GeometricWeather](https://github.com/magicmmp/GeometricWeather_Java)
（LGPL-3.0）的 `theme/weatherView/materialWeatherView/implementor/`：

| 天气 | 来源类 | 说明 |
|---|---|---|
| 晴（日） | `SunImplementor` | 三层方块群，3/4/5 秒各转 90° |
| 晴（夜） | `MeteorShowerImplementor` | 15 颗流星 + 50 颗闪烁星点 |
| 雨 | `RainImplementor` | 75 滴胶囊形，整层倾斜 8° |
| 雷雨 | `RainImplementor(TYPE_THUNDERSTORM)` | 90 滴 + 全屏紫闪 |
| 雪 | `SnowImplementor` | 圆形飘落 + 左右摆动 |
| 冰雹 | `HailImplementor` | 45 颗方形冰粒，边落边自转 |
| 风/沙尘 | `WindImplementor` | 160 根横条，整层旋转 -16° |
| 云/阴/雾/霾 | `CloudImplementor` | 6~9 个巨大半透明圆交叠，半径缓慢呼吸 |

**原版是 Android Canvas 逐帧绘制，这里用 HTML5 Canvas 重写** —— `translate`/`rotate`/`fillRect`
语义一致，所以基本能一一对应。参数（个数、速度、尺寸比例、颜色）照抄，代码是 JS 新写的。

背景配色也照抄 `MaterialWeatherThemeDelegate.innerGetBackgroundColor`：

| 天气 | 日间 | 夜间 |
|---|---|---|
| 晴 | `#FDBC4C` | `#141C2C` |
| 多云 | `#9DAFC1` | `#263238` |
| 阴 | `#00A5D9` | `#222D43` |
| 雨 | `#4297E7` | `#264E8F` |
| 雪 | `#68BAFF` | `#1A5B92` |
| 雷 | `#B296BD` | `#231739` |
| 雾 | `#A3AEC2` | `#4F5D68` |
| 霾 | `#E1C899` | `#6C5C49` |
| 风 | `#EACDA3` | `#958675` |

## 依赖

- **网络**：`weatherapi.market.xiaomi.com`、`myip.ipip.net`、`ipinfo.io`
- **`curl`**：目标机型自带，取数据用
- 不需要 `openssl`、`mpg123` 之类的额外二进制，也不需要申请任何 key

## 城市数据

`cities.json` 从国家统计局行政区划整理（省/市/区县三级，45 KB）。结构是：

```json
{
  "广东省": {
    "广州市": ["荔湾区", "越秀区", ...],
    "直辖县级市": []
  }
}
```

直辖市的市级用省名占位（`{"北京市": {"北京市": ["东城区", ...]}}`），
省直辖/自治区直辖的县级市统一归到「直辖县级市」这一类下面。

## 已知限制

- **定位精度只到市**：IP 定位靠运营商出口，移动网络可能偏几十公里。要更准就手动选。
- **小米接口没有公开文档**：`appKey` 和 `sign` 是固定值，哪天失效就得换源。
- **定位接口的精度**：`city/geo` 会返回区县，但那是运营商出口的归属，不代表设备真在那儿。
  所以自动定位时把名字换成市名，不给假精度。

## 调试

- **看某天气的动画**：地址加 `?wx=<代码>`，比如 `?wx=9` 看大雨
- **打开测试面板**：连点温度 5 次
- **强制刷新数据**：`/api/plugins/weather/weather?force=1`

## 许可

本应用使用 **LGPL-3.0**（见 `LICENSE`）。

背景动画的算法、参数与配色移植自 GeometricWeather（LGPL-3.0），
按同一许可发布。其余代码（界面、数据获取、城市选择）为本项目原创。

天气数据版权归小米 / 中国气象局所有，本应用仅做展示。
