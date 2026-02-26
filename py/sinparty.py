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
        page = await browser.new_page(ignore_https_errors=True)

        # 【核心新增】：注入反爬虫绕过脚本，抹除自动化特征，欺骗防御蜘蛛的探测
        await page.add_init_script("Object.defineProperty(navigator, 'webdriver', {get: () => undefined})")

        page_num = 1
        while True:
            print(f"正在加载并抓取第 {page_num} 页数据...")
            # 动态改变 page=&& 参数
            url = f"https://sinparty.com/?page={page_num}"
            # 移除不可靠的 networkidle，使用默认导航机制
            await page.goto(url)

            # 【核心新增】：强制屏蔽拦截遮罩，破坏防御弹窗，恢复“可操作、可活动、可点击”状态
            await page.add_style_tag(content='''
                .app-modal__overlay, .modal-auth__inner { display: none !important; z-index: -9999 !important; }
                body, html { pointer-events: auto !important; overflow: auto !important; user-select: auto !important; }
            ''')
            # 使用 JS 直接从 DOM 树中强制物理删除这两个拦截节点
            await page.evaluate('''() => {
                document.querySelectorAll('.app-modal__overlay, .modal-auth__inner').forEach(el => el.remove());
            }''')

            # 定位目标：跳过 skeleton 骨架屏，直接锁定在线主播节点
            try:
                # 显式等待真实数据的 CSS 节点渲染到 DOM 中（最长容忍 20 秒）
                # 统一 <div class="content-gallery content-gallery--live-listing"> 数组 和 <div class="content-gallery__item">
                await page.wait_for_selector(".content-gallery--live-listing .content-gallery__item", timeout=20000)
            except Exception:
                # 如果 20 秒后目标节点仍未出现，说明确实到达了没有数据的最后一页
                print(f"第 {page_num} 页未检测到有效在线主播数据，翻页结束。\n")
                break
                
            # 此时 DOM 中必定已有数据，安全执行并集提取
            # 每二次数组截胡 <div class="content-gallery__item">
            elements = await page.locator(".content-gallery--live-listing .content-gallery__item").all()

            for element in elements:
                # 抓取标题与名字：兼容 .cam-tile__title 或 .cam-tile__details
                title_loc = element.locator(".cam-tile__title")
                if await title_loc.count() > 0:
                    title = await title_loc.first.inner_text()
                else:
                    title = "未知用户"

                # 抓取 href 跳转链接：对应 class="cam-tile" 等于跳转链接
                a_loc = element.locator("a.cam-tile")
                if await a_loc.count() > 0:
                    href = await a_loc.first.get_attribute("href")
                else:
                    href = ""
                
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
    
    connector = aiohttp.TCPConnector(limit=100, ssl=False)
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
