#!/usr/bin/env bash
# starhub-proxy 懒人一键部署 (公用版 / public) — 单文件自带全部代码, 无需下载其他文件
# 用法 / Usage: bash starhub-install.sh   (或 curl -sSL <本文件地址> | bash)
# 首次运行会先询问: 新加坡 socks5 代理地址 (回车跳过 = 直连) -> 对外端口, 然后才开始部署。
set -e

APP_DIR=/opt/starhub-proxy

ask() { # ask <prompt> <default>
  local prompt="$1" def="${2:-}" ans=""
  if [ -r /dev/tty ]; then
    printf "%s" "$prompt" > /dev/tty
    read -r ans < /dev/tty || true
  fi
  echo "${ans:-$def}"
}

echo "==> starhub-proxy 一键部署 / One-click deploy"

# 1) 首次配置向导 (仅当 .env 不存在时)
if [ ! -f "$APP_DIR/.env" ]; then
  echo
  echo "源站只认新加坡出口: 服务器不在新加坡时, 上游请求必须走一个新加坡代理。"
  echo "The origin only accepts Singapore egress; use an SG proxy unless this server is in SG."
  echo
  PROXY_URL=$(ask "代理地址 (粘贴完整 socks5 地址, 如 socks5://账号:密码@IP:端口; 没有可直接回车跳过): " "")
  if [ -n "$PROXY_URL" ] && [[ "$PROXY_URL" != *"://"* ]]; then
    PROXY_URL="socks5://${PROXY_URL}"
  fi
  PORT_IN=$(ask "对外端口 (默认 9281, 直接回车保持默认): " "9281")
  mkdir -p "$APP_DIR"
  printf "UPSTREAM_PROXY=%s\nPORT=%s\n" "$PROXY_URL" "$PORT_IN" > "$APP_DIR/.env"
  echo
  if [ -n "$PROXY_URL" ]; then
    echo "==> 已选择: 代理模式 (代理地址已写入 .env, 不会显示)"
  else
    echo "==> 已选择: 直连模式"
  fi
  echo "==> 端口: $PORT_IN"
else
  echo "==> 检测到已有 .env, 沿用现有配置(不再询问)"
fi

# 2) Docker
if ! command -v docker >/dev/null 2>&1; then
  echo "==> 未检测到 Docker, 正在安装..."
  curl -fsSL https://get.docker.com | sh
fi
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  echo "缺少 docker compose, 请先安装后重试" >&2; exit 1
fi

# 3) 写入内嵌代码
echo "==> 写入代码到 $APP_DIR"
mkdir -p "$APP_DIR"
cat > "$APP_DIR/app.py" <<'__APP_PY_END__'
#!/usr/bin/env python3
"""starhub-proxy: StarHub TV+ (bpk-tv) DASH 转流代理。

实测结论: shtvgo-prod.gcdn.co 上的清单与分片只需新加坡出口即可
裸拉, 不需要 StarHub 账号登录。ucdn.starhubgo.com 有更严的 ACL
(403), 仅作兜底。内置 94 个频道, 2026-10-22 逐台验证清单可达且
清单 KID 与 keys.json 一致。

职责:
- /playlist.m3u  生成给面板的播放列表(条目指向本容器的 /mpd/<channel>)
- /mpd/<channel> 拉上游清单, 把 <BaseURL> 改写回本容器
- /seg/<channel>/<path>  逐个转发分片(支持 Range)
- /fetch?u=<base64url>   转发清单里出现的绝对地址(兜底)

上游请求统一走环境变量 UPSTREAM_PROXY(http:// 或 socks5://)。
频道 ClearKey 的 KID:KEY 从 keys.json 读, 只用于生成播放列表时的
KODIPROP, 代理本身不解密。
"""
import asyncio
import base64
import json
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone
import xml.etree.ElementTree as ET

from aiohttp import web, ClientSession, ClientTimeout

try:
    from aiohttp_socks import ProxyConnector
except ImportError:  # socks 支持缺失时仅 http 代理可用
    ProxyConnector = None

UPSTREAM_PROXY = os.environ.get("UPSTREAM_PROXY", "").strip()
PORT = int(os.environ.get("PORT", "9281"))
# 默认 UA(内置, 免去播放端逐条加 UA); 可用环境变量 UA 覆盖
DEFAULT_UA = ("Mozilla/5.0 (Linux; Android 10; SM-AXSO0 Build/QTZCS200912.005) "
              "AppleWebKit/537.36 (KHTML, like Gecko) "
              "Chrome/92.0.4515.159 Safari/537.36")
UA = os.environ.get("UA", "").strip() or DEFAULT_UA

# EPG: EPGShare 新加坡节目单(播放列表以 url-tvg 形式带出, 播放器自动加载)
EPG_URL = "https://epgshare01.online/epgshare01/epg_ripper_SG1.xml.gz"
EPG_API = "https://waf-starhub-metadata-api-p001.sh-ifs.com/v3.1/epg/schedules"
EPG_DAYS = 3            # 节目单覆盖天数
EPG_REFRESH = 6 * 3600  # 刷新间隔(秒)
SGT = timezone(timedelta(hours=8))

# channel -> (gcdn slug, ucdn slug, display name, group, logo, fallback-tvg-id, epg uuid); 大小写敏感, 2026-10-22 逐台实测
CHANNELS = {
    "preview": ("Preview", "Preview", "Preview Channel", "综合", "https://poster.starhubgo.com/Linear_channels2/101_1920x1080_HTV.png", "", "7c9126e4-f92c-42d6-a381-3ba640da04b9"),
    "hubecity": ("HubECityHD", "HubECityHD", "Hub E City", "综合", "https://poster.starhubgo.com/Linear_channels2/111_1920x1080_HTV.png", "", "3181b9a2-f8f4-489c-b8fd-d19f923c6f62"),
    "abcaustralia": ("ABCAustralia", "ABCAustralia", "ABC Australia", "综合", "https://poster.starhubgo.com/Linear_channels2/447_1920x1080_HTV.png", "", "64da91df-f088-48ae-9994-99a846e0c1f8"),
    "cctv4": ("CCTV4", "CCTV4", "CCTV4", "综合", "https://poster.starhubgo.com/Linear_channels2/801_1920x1080_HTV.png", "", "04c1e33b-520d-42b7-8d83-dc8650b758c0"),
    "phoenixchinese": ("PCCHD", "PCCHD", "Phoenix Chinese Channel", "综合", "https://poster.starhubgo.com/Linear_channels2/805_1920x1080_HTV.png", "", "3d4b11b5-c883-44ae-921b-4d7e07fe852f"),
    "nhkworld": ("NHKWORLDJAPAN", "NHKWORLDJAPAN", "NHK World", "综合", "https://poster.starhubgo.com/Linear_channels2/812_1920x1080_HTV.png", "", "7b781d20-7138-4ffb-bd9d-6b12e473043b"),
    "kbsworld": ("KBSWorldHD", "KBSWorldHD", "KBS World", "综合", "https://poster.starhubgo.com/Linear_channels2/815_1920x1080_HTV.png", "", "52a80589-3613-4021-bcf6-6abb1c80bff4"),
    "arirang": ("ArirangTV", "ArirangTV", "Arirang", "综合", "https://poster.starhubgo.com/Linear_channels2/817_1920x1080_HTV.png", "", "4c25cb31-4a19-4d5b-9926-a51a8b289ae5"),
    "hubecity825": ("HubECityHD825", "HubECityHD825", "Hub E City (825)", "综合", "https://poster.starhubgo.com/Linear_channels2/825_1920x1080_HTV.png", "", "aa5a523d-562b-499b-b04b-1d75fbbc88f5"),
    "tvbsasia": ("TVBSAsia", "TVBSAsia", "TVBS Asia", "综合", "https://poster.starhubgo.com/Linear_channels2/828_1920x1080_HTV.png", "", "e1b53e0d-f371-4918-8cbd-6e99a4d79c76"),
    "dragontv": ("DragonTV", "DragonTV", "Dragon TV", "综合", "https://poster.starhubgo.com/Linear_channels2/832_1920x1080_HTV.png", "", "69303210-3157-4dd2-b923-809c5ce2371a"),
    "anc": ("ANC", "ANC", "ANC", "新闻", "https://poster.starhubgo.com/Linear_channels2/143_1920x1080_HTV.png", "", "5711b532-844b-441d-841a-18bdb1ef1094"),
    "dw": ("DW", "DW", "DW English", "新闻", "https://poster.starhubgo.com/Linear_channels2/153_1920x1080_HTV.png", "", "37494f1f-0748-4150-bfbc-eb24b0bf1a34"),
    "bbcnews": ("BBCWorldNewsHD", "BBCWorldNewsHD", "BBC News", "新闻", "https://poster.starhubgo.com/Linear_channels2/701_1920x1080_HTV.png", "", "1312f58d-752b-4d8a-879e-33a43de2d941"),
    "foxnews": ("FNCHD", "FNCHD", "Fox News Channel", "新闻", "https://poster.starhubgo.com/Linear_channels2/702_1920x1080_HTV.png", "", "eb856acf-437e-470f-9161-eabd52e3de02"),
    "skynews": ("SkyNewsHD", "SkyNewsHD", "Sky News", "新闻", "https://poster.starhubgo.com/Linear_channels2/703_1920x1080_HTV.png", "", "36453e0d-85cc-4ee7-816c-2e147541cecf"),
    "euronews": ("Euronews", "Euronews", "Euronews", "新闻", "https://poster.starhubgo.com/Linear_channels2/704_1920x1080_HTV.png", "", "f948f494-b2bd-4b92-8752-878938966e49"),
    "cnbc": ("CNBCHD", "CNBCHD", "CNBC", "新闻", "https://poster.starhubgo.com/Linear_channels2/707_1920x1080_HTV.png", "", "173fc873-1c01-4782-b0ee-f322fe23ef33"),
    "bloomberg": ("BloombergTelevisionHD", "BloombergTelevisionHD", "Bloomberg Television", "新闻", "https://poster.starhubgo.com/Linear_channels2/708_1920x1080_HTV.png", "", "f946f3d4-96c3-4e0f-924d-edac62433fd2"),
    "cnn": ("CNNHD", "CNNHD", "CNN International", "新闻", "https://poster.starhubgo.com/Linear_channels2/711_1920x1080_HTV.png", "", "8339731a-4928-4ff0-bf9d-9202ae59aea7"),
    "cgtn": ("CGTN", "CGTN", "CGTN", "新闻", "https://poster.starhubgo.com/Linear_channels2/722_1920x1080_HTV.png", "", "b4554ec6-37d5-4936-943d-229e9df528e8"),
    "france24": ("France24", "France24", "France 24", "新闻", "https://poster.starhubgo.com/Linear_channels2/724_1920x1080_HTV.png", "", "64864046-76a0-4de0-a65b-53fea57ee6bd"),
    "phoenixinfonews": ("PINCHD", "PINCHD", "Phoenix InfoNews Channel", "新闻", "https://poster.starhubgo.com/Linear_channels2/806_1920x1080_HTV.png", "", "d440ee6e-6f9a-4d78-b37b-5be89051145a"),
    "tvbsnews": ("TVBSNews", "TVBSNews", "TVBS News", "新闻", "https://poster.starhubgo.com/Linear_channels2/808_1920x1080_HTV.png", "", "ea2a19ac-da50-4e86-8083-d8938112641f"),
    "hubsports1": ("HubSports1HDnew1", "HubSports1HDnew1", "Hub Sports 1", "体育", "https://poster.starhubgo.com/Linear_channels2/201_1920x1080_HTV.png", "", "b5c3d45b-e2c9-462b-bcf1-06a149d68f25"),
    "hubsports2": ("HubSports2HD", "HubSports2HD", "Hub Sports 2", "体育", "https://poster.starhubgo.com/Linear_channels2/202_1920x1080_HTV.png", "", "347fa620-e966-423c-8d46-98469f0fc974"),
    "hubsports3": ("HubSports3HDNEW", "HubSports3HDNEW", "Hub Sports 3", "体育", "https://poster.starhubgo.com/Linear_channels2/203_1920x1080_HTV.png", "", "4ff7b357-9338-41a3-b7be-ede530555279"),
    "hubsports4": ("HubSports4HDnew", "HubSports4HDnew", "Hub Sports 4", "体育", "https://poster.starhubgo.com/Linear_channels2/204_1920x1080_HTV.png", "", "753b50fe-262e-48da-9b5e-3fd9894ff531"),
    "hubsports5": ("HubSports5HD", "HubSports5HD", "Hub Sports 5", "体育", "https://poster.starhubgo.com/Linear_channels2/205_1920x1080_HTV.png", "", "38df8124-1bcd-49b6-abb3-ee230a1f40d2"),
    "hubsports6": ("HubSports6", "HubSports6", "Hub Sports 6", "体育", "https://poster.starhubgo.com/Linear_channels2/206_1920x1080_HTV.png", "", "e314dd8c-3ed8-4e70-b16c-5133e0759513"),
    "hubsports7": ("HubSports7", "HubSports7", "Hub Sports 7", "体育", "https://poster.starhubgo.com/Linear_channels2/207_1920x1080_HTV.png", "", "f40a770e-36a0-4dcf-9e1f-7decbf2120cb"),
    "hubsports8": ("HubSports8", "HubSports8", "Hub Sports 8", "体育", "https://poster.starhubgo.com/Linear_channels2/207_1920x1080_HTV.png", "Hub.Sports.8.HD.sg", ""),
    "spotv": ("SPOTVNEW", "SPOTVNEW", "SPOTV", "体育", "https://poster.starhubgo.com/Linear_channels2/209_1920x1080_HTV.png", "", "e90f7070-37bc-431d-ae30-137a5ec5e8e4"),
    "spotv2": ("SPOTV2NEW", "SPOTV2NEW", "SPOTV 2", "体育", "https://poster.starhubgo.com/Linear_channels2/210_1920x1080_HTV.png", "", "0e9c2522-9489-43d9-ba57-cc8750937972"),
    "bein2": ("beINSportsHD2", "beINSportsHD2", "beIN Sports 2", "体育", "https://poster.starhubgo.com/Linear_channels2/211_1920x1080_HTV.png", "", "6fb02848-2b74-4803-9661-ab4ff642764b"),
    "bein1": ("BeINSportsHD", "BeINSportsHD", "beIN Sports 1", "体育", "https://poster.starhubgo.com/Linear_channels2/213_1920x1080_HTV.png", "", "9f3a21bb-b934-4147-bfb9-888057ec0657"),
    "bein3": ("beINSports3NEW", "beINSports3NEW", "beIN Sports 3", "体育", "https://poster.starhubgo.com/Linear_channels2/214_1920x1080_HTV.png", "", "249f5236-ca5d-416d-98b2-7e6961f1bccd"),
    "bein4": ("beINSports4", "beINSports4", "beIN Sports 4", "体育", "https://poster.starhubgo.com/Linear_channels2/215_1920x1080_HTV.png", "beIN.SPORTS.4.(HD).sg", ""),
    "bein5": ("beINSports5", "beINSports5", "beIN Sports 5", "体育", "https://poster.starhubgo.com/Linear_channels2/216_1920x1080_HTV.png", "beIN.SPORTS.5.(HD).sg", ""),
    "hubpremier1": ("HubPremier1", "HubPremier1", "Hub Premier 1", "体育", "https://poster.starhubgo.com/Linear_channels2/221_1920x1080_HTV.png", "", "5cee1079-1bb5-4054-ae02-0322144a248b"),
    "hubpremier2": ("HubPremier12", "HubPremier12", "Hub Premier 2", "体育", "https://poster.starhubgo.com/Linear_channels2/222_1920x1080_HTV.png", "", "6f186614-28de-416a-b8a6-02fa5c579aa7"),
    "hubpremier3": ("HubPremier3", "HubPremier3", "Hub Premier 3", "体育", "https://poster.starhubgo.com/Linear_channels2/223_1920x1080_HTV.png", "", "248a8c09-1327-44cc-b652-a66715cfc26d"),
    "hubpremier4": ("HubPremier4", "HubPremier4", "Hub Premier 4", "体育", "https://poster.starhubgo.com/Linear_channels2/224_1920x1080_HTV.png", "", "a8bfda3d-d820-4c40-ab75-2f8b9e905862"),
    "hubpremier5": ("HubPremier5", "HubPremier5", "Hub Premier 5", "体育", "https://poster.starhubgo.com/Linear_channels2/225_1920x1080_HTV.png", "", "197b3e19-3bd0-4d1f-b531-d2c244587d89"),
    "hubpremier6": ("HubPremier6", "HubPremier6", "Hub Premier 6", "体育", "https://poster.starhubgo.com/Linear_channels2/226_1920x1080_HTV.png", "", "e2a12638-8168-44e7-8e2a-6c436186a085"),
    "fashiontv": ("FashionTV", "FashionTV", "FashionTV", "娱乐", "https://poster.starhubgo.com/Linear_channels2/443_1920x1080_HTV.png", "", "a253b74a-ab9d-4545-9cdd-d81e2d9a056d"),
    "rockentertainment": ("BlueAntEntertainmentHD", "BlueAntEntertainmentHD", "ROCK Entertainment", "娱乐", "https://poster.starhubgo.com/Linear_channels2/509_1920x1080_HTV.png", "", "ca5c1396-7135-426f-baf3-23e9eaef335e"),
    "axn": ("AXNHD", "AXNHD", "AXN", "娱乐", "https://poster.starhubgo.com/Linear_channels2/511_1920x1080_HTV.png", "", "89ca2356-f022-4bc6-9ef4-be30d427988f"),
    "lifetime": ("LifetimeHD", "LifetimeHD", "Lifetime", "娱乐", "https://poster.starhubgo.com/Linear_channels2/514_1920x1080_HTV.png", "", "09e8b069-9fce-4a8d-b0cd-2bf77a8a71ba"),
    "hits": ("HITSHD", "HITSHD", "HITS", "娱乐", "https://poster.starhubgo.com/Linear_channels2/519_1920x1080_HTV.png", "", "afde6766-acb5-4c69-b147-dd8b98dea9d2"),
    "animax": ("AnimaxHD", "AnimaxHD", "Animax", "娱乐", "https://poster.starhubgo.com/Linear_channels2/532_1920x1080_HTV.png", "", "57100d1f-5351-475e-bfef-bd9ae5793684"),
    "onetvasia": ("ONEHD", "ONEHD", "ONE TV Asia", "娱乐", "https://poster.starhubgo.com/Linear_channels2/823_1920x1080_HTV.png", "ONE.HD.(Mandarin).sg", ""),
    "tvbjade": ("TVBJadeHD", "TVBJadeHD", "TVB Jade", "娱乐", "https://poster.starhubgo.com/Linear_channels2/838_1920x1080_HTV.png", "", "38251a1a-9368-410c-9dc5-ab806d74420f"),
    "hubvvdrama": ("HubVVDramaHD", "HubVVDramaHD", "Hub VV Drama", "娱乐", "https://poster.starhubgo.com/Linear_channels2/855_1920x1080_HTV.png", "", "792aa2b5-cb06-45b9-bf37-e919c27c097e"),
    "tvbxinghe": ("TVBXingHeChannel", "TVBXingHeChannel", "TVB Xing He", "娱乐", "https://poster.starhubgo.com/Linear_channels2/859_1920x1080_HTV.png", "", "8a0cfe88-6627-49e8-8eed-a2f73e609b5d"),
    "zeecinema": ("ZeeCinema", "ZeeCinema", "Zee Cinema", "电影", "https://poster.starhubgo.com/Linear_channels2/130_1920x1080_HTV.png", "", "5f52f2b3-e45a-40a5-bcf3-2dd75a5543f8"),
    "sonymax": ("SonyMAX", "SonyMAX", "Sony Max", "电影", "https://poster.starhubgo.com/Linear_channels2/131_1920x1080_HTV.png", "", "0a9604e3-35dc-4c90-a9e4-39ea7f39c9d6"),
    "asianetmovies": ("AsianetMov", "AsianetMov", "Asianet Movies", "电影", "https://poster.starhubgo.com/Linear_channels2/140_1920x1080_HTV.png", "", "aeac111e-e284-41d9-b6b5-ae13f6dbe67b"),
    "cinemaone": ("CinemaOne", "CinemaOne", "Cinema One Global", "电影", "https://poster.starhubgo.com/Linear_channels2/145_1920x1080_HTV.png", "", "50b86b7f-084e-4ea1-8610-22e86c733c1c"),
    "hitsmovies": ("HitsMoviesHD", "HitsMoviesHD", "Hits Movies", "电影", "https://poster.starhubgo.com/Linear_channels2/512_1920x1080_HTV.png", "", "f25d2d07-0303-4c95-be02-e9569d6c4f54"),
    "hbo": ("HBOHD", "HBOHD", "HBO", "电影", "https://poster.starhubgo.com/Linear_channels2/601_1920x1080_HTV.png", "", "dea58cb4-eba4-4d53-a1c4-ff8e501e2adf"),
    "hbosignature": ("HBOSignatureHD", "HBOSignatureHD", "HBO Signature", "电影", "https://poster.starhubgo.com/Linear_channels2/603_1920x1080_HTV.png", "", "0ef9316c-9b57-42fb-80d2-49297d7a7bac"),
    "hbofamily": ("HBOFamilyHD", "HBOFamilyHD", "HBO Family", "电影", "https://poster.starhubgo.com/Linear_channels2/604_1920x1080_HTV.png", "", "dddf00c0-b347-472d-bc30-d44fd837cde2"),
    "hbohits": ("HBOHitsHD", "HBOHitsHD", "HBO Hits", "电影", "https://poster.starhubgo.com/Linear_channels2/605_1920x1080_HTV.png", "", "d5fa461f-bbfc-4706-9b72-9ea67c946394"),
    "cinemax": ("CinemaxHD", "CinemaxHD", "Cinemax", "电影", "https://poster.starhubgo.com/Linear_channels2/611_1920x1080_HTV.png", "", "3c85588c-262b-43de-b9c3-0f0fd51466d9"),
    "celestialmovies": ("CelestialMoviesHD", "CelestialMoviesHD", "Celestial Movies", "电影", "https://poster.starhubgo.com/Linear_channels2/868_1920x1080_HTV.png", "", "b8b921c8-3798-40b7-aab9-cb2eca3a5159"),
    "celestialclassicmovies": ("CCM", "CCM", "Celestial Classic Movies", "电影", "https://poster.starhubgo.com/Linear_channels2/869_1920x1080_HTV.png", "", "d2bac03e-7024-48be-83b2-d56cc3852a7c"),
    "cbeebies": ("CbeebiesHD", "CbeebiesHD", "CBeebies", "少儿", "https://poster.starhubgo.com/Linear_channels2/303_1920x1080_HTV.png", "", "219cc587-57ab-4b55-baf3-03810f46deeb"),
    "nickjr": ("NickJr", "NickJr", "Nick Jr.", "少儿", "https://poster.starhubgo.com/Linear_channels2/304_1920x1080_HTV.png", "", "29d2b788-ae5c-4307-8ac8-dd0c5911ea38"),
    "dreamworks": ("DreamworksHD", "DreamworksHD", "DreamWorks Channel", "少儿", "https://poster.starhubgo.com/Linear_channels2/606_1920x1080_HTV.png", "", "824bd5da-016e-4e10-9c8e-2c33fbc179d4"),
    "nickelodeon": ("NickelodeonHD", "NickelodeonHD", "Nickelodeon", "少儿", "https://poster.starhubgo.com/Linear_channels2/314_1920x1080_HTV.png", "", "c873d8db-2f77-4482-8074-b1d477455e91"),
    "cartoonnetwork": ("CartoonNetwork", "CartoonNetwork", "Cartoon Network", "少儿", "https://poster.starhubgo.com/Linear_channels2/316_1920x1080_HTV.png", "", "753cf54a-a4a2-4723-8709-c8ce14ec8254"),
    "history": ("HistoryHD", "HistoryHD", "History", "纪录", "https://poster.starhubgo.com/Linear_channels2/401_1920x1080_HTV.png", "", "ded93a12-883b-4ee0-9eaf-d137ebfe2da9"),
    "crimeinvestigation": ("CrimeplusInvestigationHD", "CrimeplusInvestigationHD", "Crime+Investigation", "纪录", "https://poster.starhubgo.com/Linear_channels2/403_1920x1080_HTV.png", "", "8a1f4f2d-29a7-4914-9214-40131ecb8d69"),
    "bbcearth": ("BBCEarthHD", "BBCEarthHD", "BBC Earth", "纪录", "https://poster.starhubgo.com/Linear_channels2/407_1920x1080_HTV.png", "", "f4658135-f4b4-4185-be9a-2ff976b54a8f"),
    "discovery": ("DiscoveryCh", "DiscoveryCh", "Discovery Channel", "纪录", "https://poster.starhubgo.com/Linear_channels2/422_1920x1080_HTV.png", "", "d298c58f-9710-4a8d-b802-d799cb064aff"),
    "travelxp": ("TravelxpHD", "TravelxpHD", "Travelxp", "纪录", "https://poster.starhubgo.com/Linear_channels2/427_1920x1080_HTV.png", "", "f2c840ad-38ec-46d1-9b7b-b4d534da3c88"),
    "bbclifestyle": ("BBCLifestyleHD", "BBCLifestyleHD", "BBC Lifestyle", "纪录", "https://poster.starhubgo.com/Linear_channels2/432_1920x1080_HTV.png", "", "047b3a4a-5094-4802-82d4-b3863b6e2cdf"),
    "hgtv": ("HGTV", "HGTV", "HGTV", "纪录", "https://poster.starhubgo.com/Linear_channels2/437_1920x1080_HTV.png", "", "ca306145-694d-41c8-9f34-c2ce62eb06e9"),
    "citra": ("CitraEntertainment", "CitraEntertainment", "Citra Entertainment", "国际", "https://poster.starhubgo.com/Linear_channels2/115_1920x1080_HTV.png", "", "f8b64a5d-438f-47e7-b516-2a902d7bc21d"),
    "karisma": ("Karisma", "Karisma", "Karisma", "国际", "https://poster.starhubgo.com/Linear_channels2/116_1920x1080_HTV.png", "", "9394fd45-230a-40cc-b19b-e1ba30972c04"),
    "astrowarna": ("Astro_warna_new", "Astro_warna_new", "Astro Warna", "国际", "https://poster.starhubgo.com/Linear_channels2/118_1920x1080_HTV.png", "", "1419f892-2abd-4717-a9e9-b2299fee00f5"),
    "sensasi": ("HubSensasiHD", "HubSensasiHD", "Astro Sensasi", "国际", "https://poster.starhubgo.com/Linear_channels2/123_1920x1080_HTV.png", "", "ee4fe8fa-b213-4dd7-8ccf-541065bb8d12"),
    "zeetv": ("ZeeTV", "ZeeTV", "Zee TV", "国际", "https://poster.starhubgo.com/Linear_channels2/125_1920x1080_HTV.png", "", "051b7938-b79f-4fd2-80d3-ebf3ebcea931"),
    "sonyent": ("SonyEntertainmentTelevision", "SonyEntertainmentTelevision", "Sony Entertainment Television", "国际", "https://poster.starhubgo.com/Linear_channels2/127_1920x1080_HTV.png", "", "d66e833d-4c36-4989-83f7-777e7773d4bd"),
    "colors": ("COLORS", "COLORS", "Colors", "国际", "https://poster.starhubgo.com/Linear_channels2/128_1920x1080_HTV.png", "", "c170ab01-3fe1-453e-850f-815b29931ff7"),
    "colorstamil": ("COLORSTamilHD", "COLORSTamilHD", "Colors Tamil", "国际", "https://poster.starhubgo.com/Linear_channels2/132_1920x1080_HTV.png", "", "32897913-6eff-45db-90e9-948b56bddbb6"),
    "suntv": ("SunTV", "SunTV", "Sun TV", "国际", "https://poster.starhubgo.com/Linear_channels2/133_1920x1080_HTV.png", "", "2a2b35a1-fbc2-44f0-8234-136fd6429b68"),
    "sunmusic": ("SunMusic", "SunMusic", "Sun Music", "国际", "https://poster.starhubgo.com/Linear_channels2/134_1920x1080_HTV.png", "", "9fbf2a7c-878f-4659-91c3-0b20db468d91"),
    "vijaytv": ("VijayTV", "VijayTV", "Vijay TV", "国际", "https://poster.starhubgo.com/Linear_channels2/135_1920x1080_HTV.png", "", "c7fec37a-8cbe-4b56-84e2-1428c82910a4"),
    "zeethirai": ("ZeeThirai", "ZeeThirai", "Zee Thirai", "国际", "https://poster.starhubgo.com/Linear_channels2/137_1920x1080_HTV.png", "", "e0483b3c-33fe-442e-b0bd-8747f6f04f6e"),
    "zeetamil": ("ZeeTamil", "ZeeTamil", "Zee Tamil", "国际", "https://poster.starhubgo.com/Linear_channels2/138_1920x1080_HTV.png", "", "aebb3170-e2ec-42cd-ae26-af914bf34045"),
    "asianet": ("Asianet", "Asianet", "Asianet", "国际", "https://poster.starhubgo.com/Linear_channels2/139_1920x1080_HTV.png", "", "385da56a-d445-4711-a6a0-6a3a80daa9a8"),
    "tv5monde": ("TV5MONDEAsieHD", "TV5MONDEAsieHD", "TV5Monde Asie", "国际", "https://poster.starhubgo.com/Linear_channels2/152_1920x1080_HTV.png", "", "0c28c445-abad-467d-9559-211174718745"),
}
GCDN = "https://shtvgo-prod.gcdn.co/bpk-tv/{slug}/output/manifest.mpd"
UCDN = "https://ucdn.starhubgo.com/bpk-tv/{slug}/output/manifest.mpd"
SOURCES = ((UCDN, 1), (GCDN, 0))  # ucdn 优先, gcdn 兜底

KEYS = {}
for _p in ("/app/keys.json", os.path.join(os.path.dirname(__file__), "keys.json")):
    if os.path.exists(_p):
        with open(_p, encoding="utf-8") as f:
            KEYS = json.load(f)
        break

_session = None


async def session():
    global _session
    if _session is None:
        timeout = ClientTimeout(total=30)
        if UPSTREAM_PROXY.startswith("socks") and ProxyConnector is not None:
            # python-socks 不认 socks5h, 归一化为 socks5(其默认远程解析 DNS)
            url = UPSTREAM_PROXY.replace("socks5h://", "socks5://", 1)
            connector = ProxyConnector.from_url(url, limit=64)
            _session = ClientSession(timeout=timeout, connector=connector)
        else:
            _session = ClientSession(timeout=timeout)
    return _session


def proxy_kw():
    if UPSTREAM_PROXY and not UPSTREAM_PROXY.startswith("socks"):
        return {"proxy": UPSTREAM_PROXY}
    return {}


def upstream_urls(channel, suffix="output/manifest.mpd"):
    g_slug, u_slug = CHANNELS[channel][0], CHANNELS[channel][1]
    out = []
    for tpl, idx in SOURCES:
        slug = (g_slug, u_slug)[idx]
        out.append(tpl.format(slug=slug).replace("output/manifest.mpd", suffix))
    return out


async def get_manifest(channel):
    last = None
    s = await session()
    for url in upstream_urls(channel):
        try:
            async with s.get(url, headers={"User-Agent": UA}, **proxy_kw()) as r:
                if r.status == 200:
                    text = await r.text()
                    if "<MPD" in text:
                        return text
                last = f"{url} -> HTTP {r.status}"
        except Exception as e:  # noqa: BLE001
            last = f"{url} -> {e!r}"
    raise web.HTTPBadGateway(text=f"upstream manifest failed: {last}")


BASEURL_RE = re.compile(r"(<BaseURL>)([^<]*)(</BaseURL>)")
ABS_ATTR_RE = re.compile(r'(\b(?:src|href)\s*=\s*")(https?://[^"]+)(")')


def rewrite_manifest(text, channel):
    def bu_repl(m):
        val = m.group(2).strip()
        if val.startswith(("http://", "https://", "/")):
            return m.group(0)
        return f"{m.group(1)}/seg/{channel}/{val}{m.group(3)}"

    out = BASEURL_RE.sub(bu_repl, text)

    def abs_repl(m):
        enc = base64.urlsafe_b64encode(m.group(2).encode()).decode().rstrip("=")
        return f"{m.group(1)}/fetch?u={enc}{m.group(3)}"

    return ABS_ATTR_RE.sub(abs_repl, out)


async def handle_mpd(request):
    channel = request.match_info["channel"]
    if channel not in CHANNELS:
        raise web.HTTPNotFound(text="unknown channel")
    text = await get_manifest(channel)
    return web.Response(text=rewrite_manifest(text, channel),
                        content_type="application/dash+xml")


async def stream_through(request, upstream_url):
    headers = {"User-Agent": UA}
    rng = request.headers.get("Range")
    if rng:
        headers["Range"] = rng
    s = await session()
    upstream = await s.get(upstream_url, headers=headers, **proxy_kw())
    if upstream.status not in (200, 206):
        body = await upstream.read()
        upstream.release()
        return web.Response(status=upstream.status, body=body,
                            content_type=upstream.headers.get("Content-Type"))
    resp = web.StreamResponse(status=upstream.status, headers={
        k: v for k, v in upstream.headers.items()
        if k.lower() in ("content-type", "content-length", "content-range",
                         "accept-ranges", "cache-control", "etag", "last-modified")
    })
    await resp.prepare(request)
    try:
        async for chunk in upstream.content.iter_chunked(65536):
            await resp.write(chunk)
    finally:
        upstream.release()
    await resp.write_eof()
    return resp


async def handle_seg(request):
    channel = request.match_info["channel"]
    path = request.match_info["path"]
    if channel not in CHANNELS:
        raise web.HTTPNotFound(text="unknown channel")
    last_exc = None
    for url in upstream_urls(channel, suffix="output/" + path):
        try:
            resp = await stream_through(request, url)
            if resp.status in (200, 206):
                return resp
        except Exception as e:  # noqa: BLE001
            last_exc = e
    if last_exc:
        raise web.HTTPBadGateway(text=f"segment failed: {last_exc!r}")
    raise web.HTTPBadGateway(text="segment failed on all upstreams")


async def handle_fetch(request):
    enc = request.query.get("u", "")
    try:
        url = base64.urlsafe_b64decode(enc + "=" * (-len(enc) % 4)).decode()
    except Exception:
        raise web.HTTPBadRequest(text="bad u")
    if not url.startswith(("http://", "https://")):
        raise web.HTTPBadRequest(text="bad url")
    return await stream_through(request, url)


async def handle_playlist(request):
    # 条目格式: http://<服务器IP>:<端口>/<频道>
    base = str(request.url.origin())
    lines = [f'#EXTM3U url-tvg="{base}/epg.xml,{EPG_URL}"']
    for ch, (_, _, disp, grp, logo, fb_id, uuid) in CHANNELS.items():
        pair = KEYS.get(ch, "")
        _kv = pair.split(":", 1)
        if len(_kv) == 2 and _kv[0] and _kv[1]:
            lines.append("#KODIPROP:inputstream.adaptive.license_type=clearkey")
            lines.append(f"#KODIPROP:inputstream.adaptive.license_key={pair}")
        logo_attr = f' tvg-logo="{logo}"' if logo else ""
        tvgid = ch if uuid else fb_id
        id_attr = f' tvg-id="{tvgid}"' if tvgid else ""
        lines.append(f'#EXTINF:-1{id_attr}{logo_attr} group-title="{grp}",{disp}')
        lines.append(f"{base}/{ch}")
    return web.Response(text="\n".join(lines) + "\n",
                        content_type="application/x-mpegurl")


async def handle_health(request):
    return web.json_response({"ok": True, "channels": list(CHANNELS),
                              "upstream_proxy": bool(UPSTREAM_PROXY)})


_epg_cache = {"xml": b"", "built": 0.0}
_epg_building = False


def _xmltv_time(ts):
    return datetime.fromtimestamp(ts, SGT).strftime("%Y%m%d%H%M%S +0800")


async def _fetch_schedules(s, uuid, t0, t1):
    out, page = [], 1
    while True:
        params = {"locale": "en_US", "locale_default": "en_US", "device": 1,
                  "in_channel_id": uuid, "gt_end": t0, "lt_start": t1,
                  "limit": 100, "page": page}
        async with s.get(EPG_API, params=params, headers={"User-Agent": UA},
                         **proxy_kw()) as r:
            if r.status != 200:
                return out
            data = await r.json()
        out += data.get("resources") or []
        pg = data.get("page") or {}
        if pg.get("current", 1) < pg.get("total", 1):
            page += 1
        else:
            return out


async def build_epg():
    global _epg_building
    if _epg_building:
        return
    _epg_building = True
    try:
        s = await session()
        now = int(time.time())
        t0, t1 = now - 6 * 3600, now + EPG_DAYS * 86400
        sem = asyncio.Semaphore(6)

        async def one(uuid):
            async with sem:
                try:
                    return await _fetch_schedules(s, uuid, t0, t1)
                except Exception as e:  # noqa: BLE001
                    print(f"epg fetch failed {uuid}: {e!r}", file=sys.stderr, flush=True)
                    return []

        routes = [(ch, v[6]) for ch, v in CHANNELS.items() if v[6]]
        results = await asyncio.gather(*(one(u) for _, u in routes))
        tv = ET.Element("tv", {"generator-info-name": "starhub-proxy"})
        for ch, v in CHANNELS.items():
            cel = ET.SubElement(tv, "channel", {"id": ch})
            ET.SubElement(cel, "display-name").text = v[2]
            if v[4]:
                ET.SubElement(cel, "icon", {"src": v[4]})
        n = 0
        for (ch, _), progs in zip(routes, results):
            for it in sorted(progs, key=lambda x: x.get("start", 0)):
                try:
                    start, stop = int(it["start"]), int(it["end"])
                except (KeyError, TypeError, ValueError):
                    continue
                pel = ET.SubElement(tv, "programme", {
                    "start": _xmltv_time(start), "stop": _xmltv_time(stop),
                    "channel": ch})
                serie = (it.get("serie_title") or "").strip()
                title = serie or (it.get("title") or "").strip()
                if title:
                    ET.SubElement(pel, "title", {"lang": "en"}).text = title
                sub = (it.get("subtitle") or "").strip()
                if not sub and serie and (it.get("title") or "").strip() not in ("", serie):
                    sub = it["title"].strip()
                if sub:
                    ET.SubElement(pel, "sub-title", {"lang": "en"}).text = sub
                desc = (it.get("description") or "").strip()
                if desc:
                    ET.SubElement(pel, "desc", {"lang": "en"}).text = desc
                for g in it.get("genres") or []:
                    ET.SubElement(pel, "category").text = str(g)
                pics = it.get("pictures") or []
                if pics and pics[0].get("url"):
                    ET.SubElement(pel, "icon", {"src": pics[0]["url"]})
                n += 1
        body = ET.tostring(tv, encoding="utf-8", xml_declaration=True)
        _epg_cache["xml"] = (b'<?xml version="1.0" encoding="UTF-8"?>\n'
                             b'<!DOCTYPE tv SYSTEM "xmltv.dtd">\n' +
                             body.split(b"?>", 1)[1].lstrip())
        _epg_cache["built"] = time.time()
        print(f"epg built: {len(routes)} channels, {n} programmes",
              file=sys.stderr, flush=True)
    finally:
        _epg_building = False


async def _epg_loop():
    while True:
        try:
            await build_epg()
            await asyncio.sleep(EPG_REFRESH)
        except Exception as e:  # noqa: BLE001
            print(f"epg loop error: {e!r}", file=sys.stderr, flush=True)
            await asyncio.sleep(1800)


async def handle_epg(request):
    if not _epg_cache["xml"]:
        return web.Response(
            text='<?xml version="1.0" encoding="UTF-8"?>\n<tv></tv>',
            content_type="text/xml")
    return web.Response(body=_epg_cache["xml"], content_type="text/xml")



async def _start_epg(app):
    asyncio.create_task(_epg_loop())


def main():
    app = web.Application()
    app.on_startup.append(_start_epg)
    app.router.add_get("/playlist.m3u", handle_playlist)
    app.router.add_get("/mpd/{channel}", handle_mpd)
    app.router.add_get("/seg/{channel}/{path:.*}", handle_seg)
    app.router.add_get("/fetch", handle_fetch)
    app.router.add_get("/epg.xml", handle_epg)
    app.router.add_get("/health", handle_health)
    app.router.add_get("/", handle_health)
    app.router.add_get("/{channel}", handle_mpd)  # 根路径频道入口, 必须最后注册
    print(f"starhub-proxy on :{PORT}, upstream_proxy={'set' if UPSTREAM_PROXY else 'none'}",
          file=sys.stderr, flush=True)
    web.run_app(app, port=PORT)


if __name__ == "__main__":
    main()
__APP_PY_END__
cat > "$APP_DIR/Dockerfile" <<'__DOCKERFILE_END__'
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir aiohttp aiohttp-socks
COPY app.py /app/app.py
COPY keys.json /app/keys.json
ENV PORT=9281
EXPOSE 9281
CMD ["python", "app.py"]
__DOCKERFILE_END__
cat > "$APP_DIR/docker-compose.yml" <<'__COMPOSE_END__'
services:
  starhub-proxy:
    build: .
    image: starhub-proxy:1.0
    container_name: starhub-proxy
    restart: unless-stopped
    ports:
      # 对外端口在 .env 的 PORT 里改(默认 9281), 容器内固定 9281
      - "${PORT:-9281}:9281"
    environment:
      # 新加坡出口代理: http:// 或 socks5h:// 开头; 直连则留空
      UPSTREAM_PROXY: "${UPSTREAM_PROXY:-}"
      # 上游请求 UA: 留空用内置默认 UA
      UA: "${UA:-}"
      PORT: "9281"
    volumes:
      - ./keys.json:/app/keys.json:ro
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
__COMPOSE_END__
cat > "$APP_DIR/keys.json" <<'__KEYS_END__'
{
 "preview": "94472526cc92471493d46543faefadda:36658f2faa1f09f206a2f448ac653e2d",
 "hubecity": "f8c6b1144723408ca3635040b159d5d1:127040955c9dc320212f110d31f7aac9",
 "abcaustralia": "d05e49ef06764933b441934b0df7afd7:28f08dc6b642be5bf24651671f73e11b",
 "cctv4": "80f9916eda094579a6f1efa06d4db70c:bee68b19d59a1f5d8e44ef26e2e838c5",
 "phoenixchinese": "10c3f073b366422bb1172644d6329e29:083a46fc38413da1aeccb36f815b31f1",
 "nhkworld": "62057e40fcd64088a7fb8ae537047af2:1a0c2df99e5048484b35835e9fcd7a0d",
 "kbsworld": "ebda46a0c57e4328bb81200709446b41:48f03c03ac2f800aea4b8b1a437bb083",
 "arirang": "f21120153ab14180af9e3cc521ef3e0c:20cbfbe7200a7c173499247833a35d4b",
 "hubecity825": "8446bf3c61cb46e48efeb9303c98f651:274c6891982e220669ef82c1f6c1bde7",
 "tvbsasia": "a7e1a45d20894a8aaaf23eaef58eb66c:c95d228c3a7a396b6cb84646359af262",
 "dragontv": "cc39dc63f3e84bceb6c5a59b058a5349:d0b825d0aeb64f1d4e4dba32ef2d907c",
 "anc": "5fb01414e3464af4a2683cf7847a2ab0:4faf90b7e72e099c871558754f23fa3a",
 "dw": "ab3236dbe1be474983feeaddc16be232:1a9c9159b431050742eabe21e37d12af",
 "bbcnews": "1bfc3a60371f47dfbf91589716bc4976:c4da05d94f2ee2c073cb093ab07d1215",
 "foxnews": "f07ee8c54c2346b9a55658ba2253e1bb:2afdbfa34b08414399fb75562313a31e",
 "skynews": "d397ab72f1e44b3abea34e879511cdad:e4a449c98410d136b21ddef7f58c5a6d",
 "euronews": "a949912200ee45efb2f30d3260eb4eb1:d9ea6196758f70ad84123906b5fa218c",
 "cnbc": "8411ae48e2d940089011964dd57a4a39:b20405dd1280c2c999d2e630a1f54187",
 "bloomberg": "3990d086ffa1431897ec0df4b62b7a9c:f132946dc762434007bcf0abe4df9064",
 "cnn": "88dccf3f4ba540348a9e8d159d448484:5f87122f3582d54f44f7f8915e7f065c",
 "cgtn": "14d5c64d3c8f464ea33d4ddee66ee13c:e515502bedb70262ea62e87d48e24f9c",
 "france24": "1c5e648fc2a64499a9f5c112dc66a9c2:5fba156eab1ed43bbe1ca86018145e9d",
 "phoenixinfonews": "7cfb0befbe3e463b98b9e76e24be8111:6618e3ba4af28955d3312ac9f2ba03e1",
 "tvbsnews": "db1ba248b9e442df918b9a536cda8886:0ab81d2fa6281223a98528c2359be10e",
 "hubsports1": "42a10a01419642de97ee025db907fccd:04173eabe97faf32a1697878f5bdb156",
 "hubsports2": "fd72f19fac0c441b808996ea993d06d2:8f0be65b978ef60062b4c7dabb226a1d",
 "hubsports3": "6cfb926f22184132a35ebf76f19595f1:ef9c426de14abc376edc1656c47875e6",
 "hubsports4": "9a29d4f3b6e540b3aa2f36927c01b6f4:57b670b45b5cb453a9f48fa975b702c1",
 "hubsports5": "14d1d427e8144c7b80cd5a8a6b9aa5e3:b3992507b4df8956717e3d5d798b7ab0",
 "hubsports6": "0bed9555084b4eaa9bfea62c3ca52871:ccac45f8beaf3eb8aafbd934d1791584",
 "hubsports7": "16f39f24603a4b9ea70fa22d91f55d29:bab7601e930f1d08ccfa005548dbbace",
 "hubsports8": "760126fc9c2640f8b32e647c0f43fa09:f139ce2dd6ebe611388fa8e175e99baf",
 "spotv": "a9b08ce3328f467dac1c6ff03b4cf358:499e104ca0c44ebc78d601094001cd67",
 "spotv2": "a3fab992070540f69551d9497a1499ab:6c48e33896b10978099f81ca0b454aff",
 "bein2": "9e9a4d58a8bb48019ec1589df652dd2b:8b1ba8fdf2c1a141322cd18564973bd4",
 "bein1": "4c4b013320654277a19df8f14b80b6c5:4751e8a9d798c2a1e1c581f179771f48",
 "bein3": "f8b328f4b7bd4ac5966f8a7d434536b7:9354e572eaedf7b9481cbe30776ae781",
 "bein4": "b6addeb1135a4279b917e35c26d5b0f5:7f5599f34b2a49e23f98045a5a0f512a",
 "bein5": "7f8252e59f9b439cb89cb8628ced2443:4faba8fd3d200f9825dc29ca98d97e33",
 "hubpremier1": "d9df2aa9c4974ed3bbf0730defad68fe:0cac792b5d5ef9ffb24e324a52c3da0b",
 "hubpremier2": "17e9c5d34f514dd3bce90fcc7deaeaa6:ab86716fe05961647a3713243e95dcd2",
 "hubpremier3": "d02ff184351548eea3981c38b6f48d9b:42d56d760c19c180ceaf2e7ef512e5be",
 "hubpremier4": "624bceaf2e78422c8ee1b8f31c638fb4:5223fbfd77b228f2f01e20358972850b",
 "hubpremier5": "549415570a894df19a2aaa524d035bb6:8cd102efa9e4feeb98b62b1e8b1f10a4",
 "hubpremier6": "ecd1e866cc4e4bb1a230dda645081865:edaf41fe7af1249eef03bfac6e9ab632",
 "fashiontv": "2b9c09ade79141e39e25f18da05bee00:f805cca7aab475afeb9b55251e0f4302",
 "rockentertainment": "05e817347131436ab754a7367ab7cbf4:d50056adfc6ee86e7dfa2ccf0b8b9872",
 "axn": "2f45dc24e46048a0981d7a4bc7127177:4db68809e6795408417128abbb32dba0",
 "lifetime": "e5ae9e1d0b554bc4b8021295f14338a0:ea2edb22dd0f9dc530db7573f6480e9c",
 "hits": "5c7890082be941669ddfb1096b41ee10:e29c76bd9d4be6433ea3a30af82d7de6",
 "animax": "8421c9bc0b5241e59fe4377405a5305e:a8570f08dd26e5210041d85d7a84d6f4",
 "onetvasia": "4151419d9e5c4723bd2bd9373341e68f:e7935e41e8b0a8a62a68f905a9f641f4",
 "tvbjade": "c664bbf4728442b0bb914b9bd2280240:9a97525d9864732487668683cdc30ff0",
 "hubvvdrama": "d9712e0043af4a4e9e6b50fc304581c7:021e2862340e8956d8ce548af7ef0839",
 "tvbxinghe": "b84174f4f59a4cd2aec7d9a3e278c79e:34d266985f873db4a6f5f6a98d8b4b50",
 "zeecinema": "1b063c7afa634cd9b78852ccbb936fa2:5d5e5a474a56c88c63904446cdd3f123",
 "sonymax": "d9d97a893d1c42a3ab865f0ea5f85d87:fe1f21eda73955bf58f01cf5449cb289",
 "asianetmovies": "edd61b87c5444c63a5f503e6f7cf3de3:e72283be311aa6c5175be86862d96eb3",
 "cinemaone": "6953b6ee83a94ee6bf9bd3f9a0b41785:58568b1209a5c44b596af7ebd49029a4",
 "hitsmovies": "7665df17620b4bffadee0b982ef841f8:c81a61f154ef0ceb60644b154354d04e",
 "hbo": "eec131c3a0af46359a1734acfa9b0e50:fbd97ce2ca444ba3090bd2968809511c",
 "hbosignature": "7dd4f16f5fd647d79589d923060df12d:e29e7f9e4bd59c0515dd0ad1e83b18a7",
 "hbofamily": "7d012c1b7ebe4232b9c9868b8d4af1e7:44bf6fb3a4e044ec4469d6f5588b09f6",
 "hbohits": "7b3087019c53476da5bf58ff3092f49b:1a6e037e898efb04cd33419486a096fe",
 "cinemax": "d4c9462406784dc1ae136960ce519d9f:088f3518471c22767c0cf0e4372bccac",
 "celestialmovies": "3144abd890c9482b924a8f64f71f5da9:01c27f7e51ff7f4a396ee9d951011077",
 "celestialclassicmovies": "1bf777a86b244608948e5d4c272ade19:a7c600a766773809cb56dc1791831247",
 "cbeebies": "c44621930bf54bf0b771b610646e9005:8cafe783be0062021523cb35be913858",
 "nickjr": "b329a17ccab74793895b2302b1e8d9dc:d5bab2e51f8597031fe497f6c00addf5",
 "dreamworks": "59cd13f9432a4b17b3cfb141bb018a4f:01fe6416e1149413db3e7a655a6a445c",
 "nickelodeon": "7ffa616fd7c1427db5fd75982985b7f7:fcc74119ced123d8457d8ee3d0a95005",
 "cartoonnetwork": "c4648ad8290a410a85781044307672ae:78bcd2f197a761ea3a885d13971d6aa9",
 "history": "aaefa438407c4e39be6944fb82b952df:9fa8872f2a8d4d9395c40802527f84ac",
 "crimeinvestigation": "2cc82e4d16944e3680ecd7f798ad934a:efd9b267c84effe30cf80dd8e9f9d499",
 "bbcearth": "fad0942337db4c7e910cca2680cbae89:f48adcc739a34ac96a4848ad0bfba6cf",
 "discovery": "58e01c2c642b407197ee4773d19c1b02:fea2e9072ca6f49f297e5123d75cf490",
 "travelxp": "f73a324d13e14b51ae6576655c2646c2:eb2aeda95806929f93f744a3c1137458",
 "bbclifestyle": "06bbd3e5972746be9307aff0ca171ef1:63d0ed83314277f18961f29fd7e90e03",
 "hgtv": "c1ac1cd0128240e18b68f337fe871b59:372c1435914f835639e2595c0670b0ed",
 "citra": "1fa97b3bd1e64a4aa5eb9b42a7da036e:6d6f02aada98526dbf8191f70b0bff6b",
 "karisma": "5f3a6256209f40028a2954d02f3de31d:15e506cc2530e5e7c0a71d5561dc4d02",
 "astrowarna": "8b08559f2efb4075b6b31666b412932d:f574a17ae1805bf390b58d2bf814c062",
 "sensasi": "0510cd2f13504601956fb58167de6beb:bdd71968a15b634b3e097173a8b7ea7b",
 "zeetv": "daa2d5016af54ce5933c9034d5c21ddf:4cb6857673fb8f3adb6c620d134b8607",
 "sonyent": "11638fd3d4294a00a06a96752386c974:1631bf2a7e1c01aa9be0777798cbacbc",
 "colors": "3c85f99a0dfc43ec97f31d1887d0bf15:7746516d0361659ca71d8a8457764f9e",
 "colorstamil": "48fe2c0e229848eca6c540290d29be8d:449b22a83e46cf2f337bf71f5b2c3bd3",
 "suntv": "c5261f30f630483e83ca4d5239cbd4b6:24704616ade384abae6cebc7e62c6c80",
 "sunmusic": "ed89bf895a514836bc3235042b1cba80:804a3b2bbc0e9b3ba4db96889349e81b",
 "vijaytv": "c496a02d46f544579384af6834469cd7:c32bb1120a1e9acc6ffbbca374f0a899",
 "zeethirai": "c584a57a5edc44e1b9e58047019a6c95:14c86305c458b457a91affeffec3bcff",
 "zeetamil": "47dde0640e614122a874b78be75ea286:e33fdb7f39f5322f14b82f4abdb192e2",
 "asianet": "32233523503442728319f13e66eabe1d:9176ac4e76ce299db6e5d86dd7efac88",
 "tv5monde": "7444d9d4f4c441e4a9636b4a06822d1e:95e1b9d523beca239ff7c5e74df5f652"
}
__KEYS_END__
cat > "$APP_DIR/README.md" <<'__README_END__'
# starhub-proxy

StarHub TV+ 全频道 DASH 转流代理(共 94 台,分 综合/新闻/体育/娱乐/电影/少儿/纪录/国际 八组)(Docker)。源站只认新加坡出口,本容器把上游请求统一走一个新加坡代理(或在新加坡本地直连),再把清单与分片转给播放器,播放器只需连容器。

Stream proxy for StarHub TV+ channels (Docker): 94 channels in 8 groups — General, News, Sports, Entertainment, Movies, Kids, Factual, International. The origin CDN only accepts Singapore egress; this container fetches manifests and segments through your SG proxy (or directly when hosted in SG) and re-serves them to your player.

## 部署 / Deploy

把本包解压到服务器任意目录,执行:

Unzip anywhere on your server, then run:

```bash
bash install.sh
```

脚本首次运行会先询问:新加坡 socks5 代理地址(粘贴完整地址,没有可直接回车跳过 = 直连)→ 对外端口,写好 `.env` 后才开始部署(装 Docker、装代码到 `/opt/starhub-proxy`、构建启动、打印播放列表地址)。之后重跑不再询问,沿用 `.env` 更新代码并重启。

On first run the script asks: SG socks5 proxy address (paste the full address; Enter to skip = direct) → public port, writes `.env`, then deploys (Docker install, code to `/opt/starhub-proxy`, build, start, playlist URL). Re-runs reuse `.env` and just update.

也可以手动部署 / Manual deploy:

```bash
cp .env.example .env   # 按需改 PORT / UPSTREAM_PROXY
docker compose up -d --build
```

## 配置 / Config(`.env`)

- `PORT`:对外端口,默认 9281
- `UPSTREAM_PROXY`:新加坡出口代理,格式 `socks5h://用户:密码@IP:端口`(也支持 `http://`)。服务器本身在新加坡可留空直连。**源站在非新加坡出口下会返回 403**,自备代理的账密只写在你自己的 `.env` 里,不要提交到任何仓库。

- `PORT`: public port, default 9281
- `UPSTREAM_PROXY`: Singapore egress proxy, `socks5h://user:pass@host:port` (or `http://`). Leave empty if the server itself is in Singapore. **The origin returns 403 for non-SG egress.** Keep your own proxy credentials only in your `.env`; never commit them.

## 使用 / Usage

- 播放列表 / Playlist:`http://<服务器IP>:9281/playlist.m3u`
- 单台地址 / Channel URL:`http://<服务器IP>:9281/<频道名>`(频道名见播放列表;上游以 ucdn 优先、gcdn 兜底 / ucdn first, gcdn fallback)
- 健康检查 / Health:`http://<服务器IP>:9281/health`

播放列表条目自带 ClearKey 的 KODIPROP,keys.json 已预置全部 94 台的 KID:KEY(KID 均已逐台拉源站清单核对)。容器按需拉流:没人看时不产生上游流量,有人看哪台才经代理现拉哪台。

节目单与台标:节目单已内置——容器直接从 StarHub TV+ 官方接口抓取(90/94 台,每 6 小时自动刷新,覆盖 3 天),通过 /epg.xml 提供,播放列表表头 url-tvg 已指向它;其余 4 台(Hub Sports 8、beIN Sports 4/5、ONE TV Asia)官方接口暂无,自动回落到 EPGShare 新加坡节目单(表头第二个地址)。台标为 StarHub TV+ 官方 1920×1080 高清图(poster.starhubgo.com)。

Playlist entries carry ClearKey KODIPROP; keys.json ships all 94 KID:KEY pairs with KIDs verified against live origin manifests. Pulling is on-demand: no upstream traffic while nobody watches.

EPG & logos: the guide is built in — the container fetches it from StarHub TV+'s official API (90/94 channels, auto-refreshed every 6 hours, 3 days of listings) and serves it at /epg.xml; the playlist's url-tvg points there. The 4 channels missing from the official API (Hub Sports 8, beIN Sports 4/5, ONE TV Asia) fall back to EPGShare's Singapore guide (second url-tvg entry). Logos are StarHub TV+'s official 1920x1080 images (poster.starhubgo.com).

## 实测结论 / Verified findings

- 全部 94 台清单与分片经新加坡出口可裸拉,**不需要 StarHub 账号登录**
- ucdn 优先、gcdn 兜底(代码里 SOURCES 顺序),两源 slug 大小写敏感、已按实测写死,勿改

- All 94 channels' manifests and segments pull bare through SG egress — **no StarHub account login needed**
- ucdn first, gcdn fallback; origin slugs are case-sensitive and hard-coded as verified — don't edit

## 卸载 / Uninstall

```bash
cd /opt/starhub-proxy && docker compose down
docker rmi starhub-proxy:1.0 2>/dev/null || true
rm -rf /opt/starhub-proxy
```
__README_END__
cd "$APP_DIR"

# 4) 启动
echo "==> 构建并启动容器"
$DC up -d --build

PORT_VAL=$(grep -E "^PORT=" .env 2>/dev/null | tail -1 | cut -d= -f2); PORT_VAL=${PORT_VAL:-9281}
# 5) 自检
echo "==> 等待服务就绪"
for i in $(seq 1 20); do
  if curl -s --max-time 3 http://127.0.0.1:${PORT_VAL}/health >/dev/null 2>&1; then break; fi
  sleep 2
done
PUBIP=$(curl -s --max-time 5 https://ipinfo.io/ip || true)
echo
echo "=================================================="
echo "部署完成 / Done"
echo "播放列表 Playlist : http://${PUBIP:-<服务器IP>}:${PORT_VAL}/playlist.m3u"
echo "健康检查 Health   : http://${PUBIP:-<服务器IP>}:${PORT_VAL}/health"
echo "看日志 Logs       : cd $APP_DIR && $DC logs -f"
echo "改配置 Reconfigure: 编辑 $APP_DIR/.env 后重跑本脚本"
echo "=================================================="
