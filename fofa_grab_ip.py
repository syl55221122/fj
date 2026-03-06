import os
import re
import requests
import time
import subprocess
from datetime import datetime

# ===============================
# 配置区
FOFA_URLS = {
    "https://fofa.info/result?qbase64=InVkcHh5IiAmJiBjb3VudHJ5PSJDTiI%3D": "ip.txt",
}

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Edg/129.0.0.0"
}

OUTPUT_FILE = "ip.txt"          # 所有 IP 统一写入这个文件

# ===============================
def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}")

# ===============================
def main():
    log("=" * 50)
    log("FOFA udpxy IP 采集器（单一文件版）")
    log(f"当前时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    log("=" * 50)

    all_ips = set()

    for fofo_url, _ in FOFA_URLS.items():
        log(f"正在爬取 FOFA: {fofo_url}")
        try:
            r = requests.get(fofo_url, headers=HEADERS, timeout=15)
            if r.status_code != 200:
                log(f"状态码异常: {r.status_code}")
                continue
            urls_all = re.findall(r'<a href="http://(.*?)"', r.text)
            valid_ips = [u.strip() for u in urls_all if u.strip() and ':' in u]
            all_ips.update(valid_ips)
            log(f"本次抓到 {len(valid_ips)} 个 IP:port")
        except Exception as e:
            log(f"爬取失败：{e}")
        time.sleep(3)  # 防反爬

    log(f"总共去重后 {len(all_ips)} 个 IP:port")

    if not all_ips:
        log("没有抓到任何有效 IP，结束运行")
        return

    # 写入单一文件 ip.txt（覆盖写入）
    try:
        with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
            for ip_port in sorted(all_ips):
                f.write(ip_port + "\n")
        log(f"已写入 {OUTPUT_FILE}：{len(all_ips)} 条记录")
    except Exception as e:
        log(f"写入文件失败：{e}")
        return

    # 自动 git add / commit / push
    try:
        # git add
        subprocess.run(['git', 'add', OUTPUT_FILE], check=True, capture_output=True)
        
        # 检查是否有变更（避免无谓 commit）
        status = subprocess.run(['git', 'status', '--porcelain'], capture_output=True, text=True)
        if not status.stdout.strip():
            log("没有变更，无需 commit & push")
            return

        # commit
        commit_msg = f"自动更新 FOFA udpxy IP 列表 {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
        subprocess.run(['git', 'commit', '-m', commit_msg], check=True, capture_output=True)
        
        # push
        subprocess.run(['git', 'push', 'origin', 'main'], check=True, capture_output=True)
        log("Git commit & push 成功")
    except subprocess.CalledProcessError as e:
        log(f"Git 操作失败：{e}")
        if e.stderr:
            log(f"错误详情: {e.stderr.decode('utf-8', errors='ignore')}")
    except Exception as e:
        log(f"Git 意外错误：{e}")

    log("\n任务完成！")
    log("=" * 50)

if __name__ == "__main__":
    main()
