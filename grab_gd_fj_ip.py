import os
import re
import requests
import subprocess
from datetime import datetime
from requests.adapters import HTTPAdapter
from requests.packages.urllib3.util.retry import Retry

# ===============================
# 配置区
FOFA_URL = "https://fofa.info/result?qbase64=InVkcHh5IiAmJiBjb3VudHJ5PSJDTiIgJiYgcmVnaW9uPSJmdWppYW4iIHx8IHJlZ2lvbj0iZ3Vhbmdkb25nIg=="

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Edg/129.0.0.0"
}

OUTPUT_FILE = "ip.txt"  # 最终输出文件

# ===============================
def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}")

def main():
    log("=" * 50)
    log("广东 + 福建 udpxy IP 采集器（单一文件版）")
    log(f"当前时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    log("=" * 50)

    # 创建 requests session + 重试机制
    session = requests.Session()
    retries = Retry(total=4, backoff_factor=2, status_forcelist=[429, 500, 502, 503, 504])
    session.mount('https://', HTTPAdapter(max_retries=retries))

    all_ips = set()

    try:
        log(f"正在请求 FOFA: {FOFA_URL}")
        r = session.get(FOFA_URL, headers=HEADERS, timeout=90)  # 超时延长到90秒
        r.raise_for_status()  # 检查状态码

        urls = re.findall(r'<a href="http://(.*?)"', r.text)
        valid_ips = [u.strip() for u in urls if u.strip() and ':' in u and len(u.split(':')) == 2]
        all_ips.update(valid_ips)

        log(f"本次抓到 {len(valid_ips)} 个 IP:port，去重后 {len(all_ips)} 个")
    except requests.exceptions.Timeout:
        log("请求超时（90秒），可能是 FOFA 服务器慢或网络问题")
        return
    except requests.exceptions.RequestException as e:
        log(f"FOFA 请求失败：{e}")
        return
    except Exception as e:
        log(f"未知错误：{e}")
        return

    if not all_ips:
        log("没有抓到任何有效 IP，结束运行")
        return

    # 写入单一文件 ip.txt（覆盖写入）
    try:
        with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
            for ip_port in sorted(all_ips):
                f.write(ip_port + "\n")
        log(f"成功写入 {OUTPUT_FILE}：{len(all_ips)} 条记录")
    except Exception as e:
        log(f"写入文件失败：{e}")
        return

    # git add / commit / push
    try:
        # 设置 git 身份
        subprocess.run(['git', 'config', '--global', 'user.name', 'GitHub Actions Bot'], check=True)
        subprocess.run(['git', 'config', '--global', 'user.email', 'actions@github.com'], check=True)

        # 先拉取远程，避免冲突
        subprocess.run(['git', 'pull', 'origin', 'main', '--rebase'], check=False, capture_output=True)

        # 添加文件
        subprocess.run(['git', 'add', OUTPUT_FILE], check=True, capture_output=True)

        # 检查是否有变更
        status = subprocess.run(['git', 'status', '--porcelain'], capture_output=True, text=True)
        if not status.stdout.strip():
            log("没有变更，无需 commit/push")
            return

        # commit
        commit_msg = f"自动更新 广东+福建 udpxy IP {datetime.now().strftime('%Y-%m-%d %H:%M UTC')}"
        subprocess.run(['git', 'commit', '-m', commit_msg], check=True, capture_output=True)

        # push（带 fallback）
        push_result = subprocess.run(['git', 'push', 'origin', 'main'], capture_output=True, text=True)
        if push_result.returncode != 0:
            log("普通 push 失败，尝试 --force-with-lease")
            subprocess.run(['git', 'push', 'origin', 'main', '--force-with-lease'], check=True)

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
