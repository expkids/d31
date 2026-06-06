# coding=utf-8
import os
import logging
import sys
import asyncio
import aiohttp

BASE_URL = "http://api.hclyz.com:81/mf"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TARGET_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "lib"))
M3U_FILE = os.path.join(TARGET_DIR, "sbjh.m3u")

BLACK_LIST = ["支付宝风控解除", "依依实力带飞"]

HEADERS = {"User-Agent": "Mozilla/5.0"}

# 保持较低的并发量，防止处理大量有效平台时发生 134 内存溢出错误
MAX_WORKERS = 5

def setup_logging():
    logger = logging.getLogger("ScraperLogger")
    logger.setLevel(logging.INFO)
    
    formatter = logging.Formatter('[%(asctime)s] %(levelname)s: %(message)s', datefmt='%Y-%m-%d %H:%M:%S')

    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)
    
    return logger

log = setup_logging()

async def safe_get_json(url, session):
    try:
        # 设置 10 秒超时，防止个别平台接口卡死
        async with session.get(url, headers=HEADERS, timeout=10) as r:
            if r.status != 200:
                return None
            return await r.json(content_type=None)
    except Exception as e:
        log.error(f"Request Exception: {url} -> {e}")
        return None

async def process_platform(item, session, sem):
    async with sem:
        room_title = item.get("title", "").strip()
        number = item.get("Number", "")
        address = item.get("address", "")
        
        # 兼容真实 CDN 地址及旧地址，提取 Logo
        xinimg = item.get("xinimg", "")
        platform_logo = xinimg.replace("clun.top", "cdn.gcufbd.top")

        log.info(f"📺 Fetching Platform：{room_title}（Resource count: {number}）")

        detail = await safe_get_json(f"{BASE_URL}/{address}", session)
        if not detail:
            return room_title, [], 1, 0

        zhubo = detail.get("zhubo", [])
        if not zhubo:
            return room_title, [], 1, 0

        group_name = f"{room_title}"
        results = []
        errors = 0
        filtered = 0

        for vod in zhubo:
            name = vod.get("title", "").strip()
            url = vod.get("address", "").strip()

            if any(keyword in name for keyword in BLACK_LIST):
                filtered += 1
                continue

            if not url:
                errors += 1
                continue

            results.append((group_name, name, url, platform_logo))

        return room_title, results, errors, filtered

async def main_async():
    total_error = 0
    total_success = 0
    total_filtered = 0

    log.info("🚀 Enhanced task initiated.")
    
    # 增加 limit_per_host 限制，防止 DNS 解析和内存崩溃
    connector = aiohttp.TCPConnector(limit=MAX_WORKERS, limit_per_host=10)
    async with aiohttp.ClientSession(connector=connector) as session:

        home = await safe_get_json(f"{BASE_URL}/json.txt", session)
        if not home:
            log.error("❌ Retrieval failed, collection terminated.")
            sys.exit(1)

        # 获取平台列表并剔除第一个元素
        raw_data = home.get("pingtai", [])[1:]
        
        # 仅保留 Number 大于 0 的平台（即有资源的平台）
        data = [x for x in raw_data if int(x.get("Number", "0") or 0) > 0]

        m3u_lines = ["#EXTM3U x-tvg-url=\"\""]
        seen_urls = set()

        log.info(f"⚡ Found {len(data)} platforms with resources.")

        sem = asyncio.Semaphore(MAX_WORKERS)

        tasks = [process_platform(item, session, sem) for item in data]
        results = await asyncio.gather(*tasks)

        for room_title, res, errors, filtered in results:
            total_error += errors
            total_filtered += filtered
            
            for group_name, name, url, logo in res:
                if url in seen_urls:
                    continue

                seen_urls.add(url)
                # 生成带 Logo 的 M3U 标签，现在 logo 变量里是完整的图片链接了
                m3u_lines.append(f'#EXTINF:-1 tvg-logo="{logo}" group-title="{group_name}",{name}')
                m3u_lines.append(url)
                total_success += 1

    try:
        os.makedirs(os.path.dirname(M3U_FILE), exist_ok=True)
        
        with open(M3U_FILE, "w", encoding="utf-8") as f:
            f.write("\n".join(m3u_lines))
        log.info(f"📄 Generation successful. Total Streams: {total_success}")
    except Exception as e:
        log.error(f"❌ Failed to write to file: {e}")
        sys.exit(1)

    summary_msg = f"Collection completed, valid: {total_success}, Shielded: {total_filtered}, Abnormal: {total_error}"
    print(f"::notice title=📁 Save path: {M3U_FILE}::{summary_msg}")

def main():
    asyncio.run(main_async())

if __name__ == "__main__":
    main()
