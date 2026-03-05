import requests
import time
import concurrent.futures
from urllib.parse import urljoin, urlparse

# ====================== 配置区 ======================
# 你的 udpxy 服务器列表来源（可替换成其他 github raw 链接）
# 格式示例：每行一个 http://1.2.3.4:4022  或 1.2.3.4:4022
UDPPXY_LIST_URL = "https://raw.githubusercontent.com/syl55221122/fj/refs/heads/main/Quanbu2.txt"  # ← 你需要自己找或维护这个列表

# 频道后缀 + 名称文件（你原来的格式： /udp/239.1.2.3:1234, 频道名）
CHANNEL_FILE_URL = "https://raw.githubusercontent.com/syl55221122/fj/refs/heads/main/zuboip.txt"

# 输出文件名
OUTPUT_FILE = "广西_可用直播源.txt"

# 测速时每个地址最多下载的字节数（建议 5MB ~ 15MB，更准但更慢）
MAX_DOWNLOAD_BYTES = 1 * 1024 * 1024  # 1MB

# 测速超时（秒）
SPEED_TIMEOUT = 8

# 并发线程数（别太大，容易被本地网络或目标限流）
MAX_WORKERS = 30
# ====================================================

def load_udpxy_servers(url):
    """加载 udpxy 服务器列表"""
    try:
        r = requests.get(url, timeout=10)
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
        print(f"加载到 {len(servers)} 个 udpxy 服务器")
        return list(set(servers))  # 去重
    except Exception as e:
        print(f"加载 udpxy 列表失败：{e}")
        return []


def load_channels(url):
    """加载 后缀路径 -> 名称 的映射"""
    try:
        r = requests.get(url, timeout=10)
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
        print(f"加载到 {len(channels)} 个频道")
        return channels
    except Exception as e:
        print(f"加载频道列表失败：{e}")
        return {}


def is_udpxy_alive(server, timeout=3):
    """简单判断 udpxy 是否在线"""
    test_urls = [
        f"{server}/status",
        f"{server}/rtp/239.255.255.250:1900",  # 常见无效但会快速返回的测试地址
    ]
    for tu in test_urls:
        try:
            r = requests.get(tu, timeout=timeout, stream=True)
            if r.status_code in (200, 206, 403):  # 有些 udpxy 不开 status 但播放路径正常
                return True
        except:
            pass
    return False


def measure_speed(server, path, name, max_bytes=MAX_DOWNLOAD_BYTES):
    """测速单个播放地址"""
    full_url = urljoin(server + '/', path.lstrip('/'))
    try:
        start = time.time()
        r = requests.get(full_url, stream=True, timeout=SPEED_TIMEOUT)
        if r.status_code != 200:
            return name, full_url, 0.0

        downloaded = 0
        for chunk in r.iter_content(1024 * 512):  # 512KB 块
            if not chunk:
                break
            downloaded += len(chunk)
            if downloaded >= max_bytes:
                break

        elapsed = time.time() - start
        if elapsed < 0.3:  # 太快可能是缓存或假响应
            return name, full_url, 0.0

        speed_mbps = (downloaded / elapsed) / (1024 * 1024) * 8  # 转为 Mbps
        print(f"  {name:<18}  {full_url:<40}  {speed_mbps:6.2f} Mbps")
        return name, full_url, speed_mbps

    except Exception:
        return name, full_url, 0.0


def main():
    servers = load_udpxy_servers(UDPPXY_LIST_URL)
    if not servers:
        print("没有可用 udpxy 服务器，退出。")
        return

    channels = load_channels(CHANNEL_FILE_URL)
    if not channels:
        print("没有频道列表，退出。")
        return

    # 先筛选活的服务器
    print("\n筛选存活的 udpxy 服务器...")
    alive_servers = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as exe:
        futures = {exe.submit(is_udpxy_alive, s): s for s in servers}
        for fut in concurrent.futures.as_completed(futures):
            s = futures[fut]
            if fut.result():
                alive_servers.append(s)
                print(f"  存活 → {s}")

    if not alive_servers:
        print("没有发现任何存活的 udpxy 服务器。")
        return

    # 开始测速
    print(f"\n开始并发测速（共 {len(alive_servers) * len(channels)} 个任务）...\n")
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = []
        for server in alive_servers:
            for path, name in channels.items():
                futures.append(
                    executor.submit(measure_speed, server, path, name)
                )

        for fut in concurrent.futures.as_completed(futures):
            results.append(fut.result())

    # 筛选有效结果并排序（速度降序）
    valid = [r for r in results if r[2] > 0.5]   # 过滤掉 <0.5Mbps 的（可调）
    valid.sort(key=lambda x: x[2], reverse=True)

    # 写入文件
    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        f.write(f"# 广西 IPTV 可用源（生成于 {time.strftime('%Y-%m-%d %H:%M')}\n")
        f.write(f"# 共找到 {len(valid)} 条有效线路（速度降序）\n\n")
        f.write("#genre#\n")
        for name, url, speed in valid:
            f.write(f"{name},{url}  # {speed:.2f} Mbps\n")

    print(f"\n完成！有效线路已保存到：{OUTPUT_FILE}")
    print(f"共 {len(valid)} 条速度 >0.5Mbps 的线路")


if __name__ == "__main__":
    main()
