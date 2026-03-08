# stability_test.py
# 自动测试直播源稳定性，只保留真正能稳定播放的源

import os
import subprocess
import concurrent.futures
import time
from datetime import datetime

# ================== 配置 ==================
INPUT_FILE = "全国_可用直播源.txt"     # 输入文件（你的直播源 txt）
OUTPUT_FILE = "稳定源.txt"               # 输出稳定源
TEST_DURATION = 30                        # 测试时长（秒）
MIN_BITRATE = 0.5                         # 最低平均码率（Mbps）
MAX_WORKERS = 6                           # 并发数（根据机器性能调）
# ===========================================

def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}")

def test_stream(url, duration=TEST_DURATION):
    """测试单个源的稳定性"""
    cmd = [
        "ffmpeg", "-i", url,
        "-t", str(duration),
        "-f", "null", "-",
        "-loglevel", "error",
        "-stats"
    ]
    try:
        result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=duration + 20,
            text=True,
            encoding='utf-8', errors='ignore'
        )
        stderr = result.stderr
        bitrate = 0.0
        if "bitrate=" in stderr:
            for line in stderr.splitlines():
                if "bitrate=" in line:
                    try:
                        br = line.split("bitrate=")[1].split("kbits")[0].strip()
                        bitrate = float(br) / 1000
                    except:
                        pass

        success = (result.returncode == 0 or "End of file" in stderr) and bitrate >= MIN_BITRATE
        return {
            "url": url,
            "stable": success,
            "bitrate": round(bitrate, 2),
            "error": stderr[:200] if not success else ""
        }
    except subprocess.TimeoutExpired:
        return {"url": url, "stable": False, "bitrate": 0.0, "error": "超时"}
    except Exception as e:
        return {"url": url, "stable": False, "bitrate": 0.0, "error": str(e)[:200]}

def main():
    if not os.path.exists(INPUT_FILE):
        log(f"输入文件 {INPUT_FILE} 不存在")
        return

    channels = []
    with open(INPUT_FILE, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or '#genre#' in line:
                continue
            if ',' not in line:
                continue
            name, url = line.split(',', 1)
            name = name.strip()
            url = url.split('#')[0].strip()  # 去备注
            if url.startswith(('http://', 'https://')):
                channels.append((name, url))

    log(f"开始测试 {len(channels)} 条源，时长 {TEST_DURATION}秒/条，并发 {MAX_WORKERS}")

    stable = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = {executor.submit(test_stream, url): (name, url) for name, url in channels}
        for future in concurrent.futures.as_completed(futures):
            name, url = futures[future]
            res = future.result()
            status = "稳定" if res["stable"] else "不稳定"
            log(f"{status} | {name} | {res['bitrate']} Mbps | {url}")
            if res["stable"]:
                stable.append(f"{name},{url} # {res['bitrate']} Mbps")

    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        f.write(f"# 稳定直播源 - 测试于 {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"# 测试时长：{TEST_DURATION}秒   最低码率：{MIN_BITRATE} Mbps\n")
        f.write(f"# 共 {len(stable)} 条稳定源\n\n")
        f.write("#genre#\n")
        for line in stable:
            f.write(line + "\n")

    log(f"测试完成！稳定源数量：{len(stable)}")
    log(f"结果保存到：{OUTPUT_FILE}")

if __name__ == "__main__":
    main()
