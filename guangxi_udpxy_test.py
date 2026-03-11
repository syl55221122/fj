import requests
import time
import concurrent.futures
from urllib.parse import urljoin

# ====================== 配置区 ======================
UDPPXY_LIST_URL = "https://raw.githubusercontent.com/syl55221122/fj/refs/heads/main/1.txt"
CHANNEL_FILE_URL = "https://raw.githubusercontent.com/syl55221122/fj/refs/heads/main/fjgd.txt"  # 你自己的全国频道列表

OUTPUT_FILE = "ai.txt"
MAX_DOWNLOAD_BYTES = 3 * 1024 * 1024   # 3MB，更容易通过
SPEED_TIMEOUT = 10                     # 延长到10秒
MAX_WORKERS = 12                       # 并发12
# ====================================================

def log(msg):
    ts = time.strftime('%Y-%m-%d %H:%M:%S')
    print(f"[{ts}] {msg}")

def load_udpxy_servers(url):
    """加载 udpxy 服务器列表"""
    try:
        r = requests.get(url, timeout=15)
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
        r = requests.get(url, timeout=15)
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
    """增强版 udpxy 存活检测：使用约45个全国各省组播测试路径
       任意一个路径返回 200/206/403 即判定在线（早停机制）
       路径后已添加你指定的地区/运营商注释（2026年3月数据）"""
    
    test_paths = [
        "/udp/237.2.1.59:1234",                 # cctv1福建广电
        "/rtp/239.12.22.3:10001",               # cctv1广东广电电
        "/rtp/239.45.3.145:5140",               # 上海电信
        "/rtp/239.200.200.2:8080",              # 云南电信
        "/rtp/239.29.0.113:5000",               # 内蒙电信
        "/rtp/239.125.1.177:4130",              # 内蒙联通
        "/rtp/225.1.8.1:8008",                  # 北京电信
        "/rtp/239.3.1.129:8008",                # 北京联通
        "/rtp/239.37.0.254:5540",               # 吉林电信
        "/rtp/239.253.142.160:3000",            # cctv1广东
        "/rtp/239.93.0.156:2193",               # 吉林联通
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
        "/rtp/239.81.0.102:4056",               # 广西联通
        "/rtp/238.125.5.96:5140",               # 新疆电信
        "/rtp/239.49.8.19:9614",                # 江苏电信
        "/rtp/239.252.219.200:5140",            # 江西电信
        "/rtp/239.254.200.45:8008",             # 河北电信
        "/rtp/239.253.92.154:6011",             # 河北联通
        "/rtp/239.16.20.1:10010",               # 河南电信
        "/rtp/225.1.4.73:1102",                 # 河南移动
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
    ]
    
    for path in test_paths:
        test_url = urljoin(server.rstrip('/') + '/', path.lstrip('/'))
        
        try:
            with requests.get(test_url, timeout=timeout, stream=True) as r:
                if r.status_code in (200, 206, 403):
                    # log(f"  ✓ {server} 通过 {path} 测试")  # 调试时打开此行查看哪个路径命中
                    return True
        except:
            continue  # 失败就试下一个路径
    
    return False

def measure_speed(server, path, name, max_bytes=MAX_DOWNLOAD_BYTES):
    """测速单个播放地址，放宽条件"""
    full_url = urljoin(server + '/', path.lstrip('/'))
    try:
        start = time.time()
        r = requests.get(full_url, stream=True, timeout=SPEED_TIMEOUT)
        
        # 放宽条件：只要求 200 + 下载到一点数据
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
        if elapsed < 0.5 or downloaded < 300 * 1024:  # 至少下 300KB
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
    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as exe:
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

    valid = [r for r in results if r[2] > 0.3]   # 门槛降低到 0.3 Mbps
    valid.sort(key=lambda x: x[2], reverse=True)

    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        f.write(f"# ai（生成于 {time.strftime('%Y-%m-%d %H:%M')})\n")
        f.write(f"# 共找到 {len(valid)} 条有效线路（速度降序）\n\n")
        f.write("#genre#\n")
        for name, url, speed in valid:
            f.write(f"{name},{url} # {speed:.2f} Mbps\n")

    log(f"\n完成！有效线路已保存到：{OUTPUT_FILE}")
    log(f"共找到 {len(valid)} 条速度 >0.3 Mbps 的线路")

if __name__ == "__main__":
    main()
