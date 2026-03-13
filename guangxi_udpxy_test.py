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
    """增强版 udpxy 存活检测：使用你指定的全国组播测试路径列表
       任意一个路径返回 200/206/403 即判定在线（早停机制）
       严格以用户2026-03-12提供的列表为准，已添加对应地区/运营商注释"""
    
    test_paths = [
        "/udp/237.2.1.59:1234",                 # 福建广电
        "/rtp/239.12.22.3:10001",               # 广东广电
        "/udp/224.1.100.90:11111"               # 广东有线
    ]
    
    for path in test_paths:
        test_url = urljoin(server.rstrip('/') + '/', path.lstrip('/'))
        
        try:
            with requests.get(test_url, timeout=timeout, stream=True) as r:
                if r.status_code in (200, 206, 403):
                    # log(f"  ✓ {server} 通过 {path} 测试")  # 可选：调试时打开，查看哪个路径先命中
                    return True
        except:
            continue  # 失败继续下一个
    
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
