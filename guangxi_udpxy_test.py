import requests
import time
import concurrent.futures
from urllib.parse import urljoin

# ====================== 配置区 ======================
UDPPXY_LIST_URL = "https://raw.githubusercontent.com/syl55221122/fj/refs/heads/main/1.txt"
CHANNEL_FILE_URL = "https://raw.githubusercontent.com/syl55221122/fj/refs/heads/main/fjgd.txt"  # 你自己的全国频道列表

OUTPUT_FILE = "ai.txt"
MAX_DOWNLOAD_BYTES = 3 * 1024 * 1024   # 3MB
SPEED_TIMEOUT = 10                     # 测速超时
MAX_WORKERS = 12                       # 并发线程数

# 模拟浏览器请求头，防止被防火墙或 udpxy 策略拦截
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Accept": "*/*",
    "Connection": "keep-alive"
}
# ====================================================

def log(msg):
    ts = time.strftime('%Y-%m-%d %H:%M:%S')
    print(f"[{ts}] {msg}")

def load_udpxy_servers(url):
    """加载 udpxy 服务器列表"""
    try:
        # 加入 headers
        r = requests.get(url, headers=HEADERS, timeout=15)
        r.raise_for_status()
        servers = []
        for line in r.text.splitlines():
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if line.startswith('http://'):
                servers.append(line.rstrip('/'))
            elif ':' in line:
                servers.append(f"http://{line.rstrip('/')}")
        log(f"加载到 {len(servers)} 个 udpxy 服务器")
        return list(set(servers))  # 去重
    except Exception as e:
        log(f"加载 udpxy 列表失败：{e}")
        return []

def load_channels(url):
    """加载 后缀路径 -> 名称 的映射"""
    try:
        # 加入 headers
        r = requests.get(url, headers=HEADERS, timeout=15)
        r.raise_for_status()
        channels = {}
        for line in r.text.splitlines():
            line = line.strip()
            if not line or ',' not in line:
                continue
            path, name = line.split(',', 1)
            path = path.strip()
            name = name.strip()
            if path and name:
                channels[path] = name
        log(f"加载到 {len(channels)} 个频道（来自 fjgd.txt）")
        return channels
    except Exception as e:
        log(f"加载频道列表失败：{e}")
        return {}

def is_udpxy_alive(server, timeout=4):
    """增强版 udpxy 存活检测"""
    
    test_paths = [
        "/udp/237.2.1.59:1234",                 # 福建广电
        "/rtp/239.12.22.3:10001",               # 广东广电
        "/rtp/239.45.3.145:5140",               # 上海电信
        "/rtp/239.200.200.2:8080",              # 云南电信
        "/rtp/239.29.0.113:5000",               # 内蒙电信
        "/rtp/239.125.1.177:4130",              # 内蒙联通
        "/rtp/225.1.8.1:8008",                  # 北京电信
        "/rtp/239.3.1.129:8008",                # 北京联通
        "/rtp/239.37.0.254:5540",               # 吉林电信
        "/rtp/239.253.142.160:3000",            # 吉林联通
        "/rtp/239.93.0.156:2193",               # 四川电信
        "/rtp/239.5.1.4:5000",                  # 天津电信
        "/rtp/225.1.1.120:5002",                # 天津联通
        "/rtp/239.121.4.113:8636",              # 宁夏电信
        "/rtp/238.1.78.166:7200",               # 安徽电信
        "/rtp/239.21.1.120:5002",               # 山东电信
        "/rtp/239.253.254.77:8000",             # 山东联通
        "/rtp/239.1.1.7:8007",                  # 山西电信
        "/rtp/226.0.2.153:9136",                # 山西联通
        "/rtp/239.77.0.86:5146",                # 广东电信
        "/rtp/239.10.0.114:1025",               # 广东移动
        "/rtp/239.0.1.3:8008",                  # 广东联通
        "/rtp/239.81.0.102:4056",               # 广西电信
        "/rtp/238.125.5.96:5140",               # 新疆电信
        "/rtp/239.49.8.19:9614",                # 江苏电信
        "/rtp/239.252.219.200:5140",            # 江西电信
        "/rtp/239.254.200.45:8008",             # 河北电信
        "/rtp/239.253.92.154:6011",             # 河北联通
        "/rtp/239.16.20.1:10010",               # 河南电信
        "/rtp/225.1.4.73:1102",                 # 河南联通
        "/rtp/233.50.201.118:5140",             # 浙江电信
        "/rtp/239.253.64.120:5140",             # 海南电信
        "/rtp/239.254.96.96:8550",              # 湖北电信
        "/rtp/228.0.0.1:6108",                  # 湖北联通
        "/rtp/239.76.253.151:9000",             # 湖南电信
        "/rtp/239.255.30.101:8231",             # 甘肃电信
        "/rtp/239.61.3.61:9884",                # 福建电信
        "/rtp/238.255.2.91:5999",               # 贵州电信
        "/rtp/232.0.0.27:1234",                 # 辽宁联通
        "/rtp/235.254.198.51:1480",             # 重庆电信
        "/rtp/225.0.4.74:7980",                 # 重庆联通
        "/rtp/239.109.205.118:8880",            # 陕西电信
        "/rtp/239.120.2.220:5141",              # 青海联通
        "/rtp/229.58.190.151:5000",             # 黑龙江联通
        "/udp/236.78.79.2:59000",               # cctv3内蒙移动
        "/rtp/239.255.40.35:8208",              # 福建联通
        "/rtp/239.254.96.82:7640",              # 海南联通
        "/rtp/239.0.0.10:5140",                 # 四川联通
        "/rtp/239.11.0.65:5140",                # 四川移动
        "/udp/224.1.100.90:11111",              # 广东有线
        "/rtp/238.200.200.133:5540",            # 上海联通
        "/rtp/226.1.30.1:6000",                 #山东广电
        "/udp/239.132.1.29:5000",               #四川广电
        "/rtp/228.1.1.1:6001",                  #湖南广电
        "/rtp/228.1.1.28:8008",                 #北京移动
    ]
    
    for path in test_paths:
        test_url = urljoin(server.rstrip('/') + '/', path.lstrip('/'))
        
        try:
            # 加入 headers，设置较短的连接超时 (connect, read)
            with requests.get(test_url, headers=HEADERS, timeout=(2, timeout), stream=True) as r:
                if r.status_code in (200, 206, 403):
                    return True
        except:
            continue
    
    return False

def measure_speed(server, path, name, max_bytes=MAX_DOWNLOAD_BYTES):
    """测速单个播放地址"""
    full_url = urljoin(server + '/', path.lstrip('/'))
    try:
        start = time.time()
        # 加入 headers
        r = requests.get(full_url, headers=HEADERS, stream=True, timeout=(3, SPEED_TIMEOUT))
        
        if r.status_code != 200:
            return name, full_url, 0.0

        downloaded = 0
        for chunk in r.iter_content(1024 * 512):
            if not chunk:
                break
            downloaded += len(chunk)
            if downloaded >= max_bytes:
                break

        elapsed = time.time() - start
        if elapsed < 0.5 or downloaded < 300 * 1024:
            return name, full_url, 0.0

        speed_mbps = (downloaded / elapsed) / (1024 * 1024) * 8
        log(f" ✓ {name:<20} {full_url:<45} {speed_mbps:6.2f} Mbps")
        return name, full_url, speed_mbps

    except Exception:
        return name, full_url, 0.0

def main():
    servers = load_udpxy_servers(UDPPXY_LIST_URL)
    if not servers:
        log("没有可用服务器，退出")
        return

    channels = load_channels(CHANNEL_FILE_URL)
    if not channels:
        log("没有频道列表，退出")
        return

    log("\n开始筛选存活服务器...")
    alive_servers = []
    # 增加存活检查的并发，加快速度
    with concurrent.futures.ThreadPoolExecutor(max_workers=30) as exe:
        futures = {exe.submit(is_udpxy_alive, s): s for s in servers}
        for fut in concurrent.futures.as_completed(futures):
            s = futures[fut]
            if fut.result():
                alive_servers.append(s)
                log(f" 存活 → {s}")

    if not alive_servers:
        log("没有存活服务器")
        return

    log(f"\n开始测速（{len(alive_servers)} 个服务器 × {len(channels)} 个频道）...\n")
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = [executor.submit(measure_speed, server, path, name) 
                   for server in alive_servers 
                   for path, name in channels.items()]
        for fut in concurrent.futures.as_completed(futures):
            results.append(fut.result())

    valid = [r for r in results if r[2] > 0.3]   
    valid.sort(key=lambda x: x[2], reverse=True)

    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        f.write(f"# ai（生成于 {time.strftime('%Y-%m-%d %H:%M')})\n")
        f.write(f"# 共找到 {len(valid)} 条有效线路\n\n")
        f.write("#genre#\n")
        for name, url, speed in valid:
            f.write(f"{name},{url} # {speed:.2f} Mbps\n")

    log(f"\n完成！有效线路已保存到：{OUTPUT_FILE}")
    log(f"共找到 {len(valid)} 条速度 >0.3 Mbps 的线路")

if __name__ == "__main__":
    main()
