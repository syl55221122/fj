import os
import re
import requests
import subprocess
from datetime import datetime

# 配置
FOFA_URL = "https://fofa.info/result?qbase64=InVkcHh5IiAmJiBjb3VudHJ5PSJDTiIgJiYgcmVnaW9uPSLmmIjmhI/ljZfpl6giIHx8IHJlZ2lvbj0i56aP5bu65Lq65rCR5Li65pS55Yqf5b+D5rC05bqnIg=="
HEADERS = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}

OUTPUT_FILE = "ip.txt"

def log(msg):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}")

def main():
    log("开始抓取广东 + 福建 udpxy IP")

    all_ips = set()
    try:
        r = requests.get(FOFA_URL, headers=HEADERS, timeout=20)
        if r.status_code != 200:
            log(f"FOFA 返回状态码: {r.status_code}")
            return

        urls = re.findall(r'<a href="http://(.*?)"', r.text)
        valid = [u.strip() for u in urls if u.strip() and ':' in u]
        all_ips.update(valid)
        log(f"本次抓到 {len(valid)} 个 IP:port，去重后 {len(all_ips)} 个")
    except Exception as e:
        log(f"抓取失败：{e}")
        return

    if not all_ips:
        log("没有抓到任何有效 IP，结束")
        return

    # 写入单一文件 ip.txt（覆盖写入）
    try:
        with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
            for ip_port in sorted(all_ips):
                f.write(ip_port + "\n")
        log(f"成功写入 {OUTPUT_FILE}：{len(all_ips)} 条记录")
    except Exception as e:
        log(f"写入失败：{e}")
        return

    # git add / commit / push
    try:
        subprocess.run(['git', 'config', '--global', 'user.name', 'GitHub Actions Bot'], check=True)
        subprocess.run(['git', 'config', '--global', 'user.email', 'actions@github.com'], check=True)
        
        # 先 pull 避免冲突
        subprocess.run(['git', 'pull', 'origin', 'main', '--rebase'], check=False)
        
        subprocess.run(['git', 'add', OUTPUT_FILE], check=True)
        
        status = subprocess.run(['git', 'status', '--porcelain'], capture_output=True, text=True)
        if status.stdout.strip():
            commit_msg = f"自动更新 广东+福建 udpxy IP {datetime.now().strftime('%Y-%m-%d %H:%M UTC')}"
            subprocess.run(['git', 'commit', '-m', commit_msg], check=True)
            subprocess.run(['git', 'push', 'origin', 'main'], check=True)
            log("Git commit & push 成功")
        else:
            log("没有变更，无需 commit/push")
    except Exception as e:
        log(f"Git 操作失败：{e}")

    log("任务完成")

if __name__ == "__main__":
    main()
