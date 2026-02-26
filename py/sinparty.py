import asyncio
import aiohttp
import re
from playwright.async_api import async_playwright

async def fetch_m3u8(session: aiohttp.ClientSession, name: str, link: str):
    """
    使用 aiohttp 高并发拉取单个直播间源码，并使用正则嗅探底层 .m3u8 流媒体链接
    优化逻辑：保持底层并发稳定，避免 GitHub Actions 中 OOM
    """
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }
    try:
        async with session.get(link, headers=headers, timeout=15) as response:
            if response.status == 200:
                text = await response.text()
                match = re.search(r'(https?:[\\/]+[^"\'\s]+\.m3u8[^"\'\s]*)', text)
                if match:
                    m3u8_url = match.group(1).replace('\\/', '/')
                    return name, m3u8_url, link
    except Exception:
        pass 
    
    return name, None, link

async def main():
    results = []
    
    # === 阶段 1：Playwright 全站分页抓取 ===
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()

        page_num = 1
        while True:
            print(f"正在加载并抓取第 {page_num} 页数据...")
            # 动态改变 page=&& 参数
            url = f"https://sinparty.com/zh?page={page_num}"
            await page.goto(url, wait_until="networkidle")

            # 定位目标：跳过 skeleton 骨架屏，直接锁定在线主播节点
            # 兼容 a.cam-tile.cam-tile--online 作为独立跳转链接提取
            elements = await page.locator("a.cam-tile.cam-tile--online").all()
            
            if not elements:
                print(f"第 {page_num} 页未检测到有效在线主播数据，翻页结束。\n")
                break

            for element in elements:
                # 抓取标题与名字：兼容 .cam-tile__title 或 .cam-tile__info
                title_loc = element.locator(".cam-tile__title, .cam-tile__info")
                if await title_loc.count() > 0:
                    title = await title_loc.first.inner_text()
                else:
                    title = "未知用户"

                # 抓取 href 跳转链接
                href = await element.get_attribute("href")
                
                if href:
                    if href.startswith("/"):
                        href = f"https://sinparty.com{href}"
                    
                    results.append({
                        "name": title.strip(),
                        "link": href
                    })

            page_num += 1

        await browser.close()

    # === 阶段 2：AIOHTTP 高性能并发抓取 m3u8 流 ===
    print(f"全站遍历完毕，共提取 {len(results)} 个直播间链接。开始高并发底层嗅探...")
    
    connector = aiohttp.TCPConnector(limit=100)
    async with aiohttp.ClientSession(connector=connector) as session:
        tasks = [fetch_m3u8(session, res["name"], res["link"]) for res in results]
        m3u8_results = await asyncio.gather(*tasks)

    # === 阶段 3：转换并格式化输出 M3U ===
    m3u_lines = ["#EXTM3U"]
    success_count = 0
    
    for name, m3u8_url, room_link in m3u8_results:
        # M3U 标准：需要直接填入可播放的流媒体链接 (.m3u8)
        # 如果底层抓不到 m3u8，则使用原始跳转链接作为 fallback
        final_link = m3u8_url if m3u8_url else room_link
        
        # 按照要求输出 group-title="女生" 及名称
        m3u_lines.append(f'#EXTINF:-1 group-title="女生",{name}')
        m3u_lines.append(final_link)
        
        if m3u8_url:
            success_count += 1
            
    m3u_content = "\n".join(m3u_lines)
    
    print("\n=== 转换格式 M3U 输出 ===")
    print(m3u_content)
    
    with open("lib/party.m3u", "w", encoding="utf-8") as f:
        f.write(m3u_content)
        
    print(f"\n并发处理完成！成功解析 {success_count} 个底层流，总计写入 {len(results)} 条数据。")

if __name__ == "__main__":
    asyncio.run(main())

