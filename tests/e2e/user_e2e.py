"""学生端冒烟测试：本地 index.html + 线上数据库，只用临时账号 zztest01。
运行：python3 tests/e2e/user_e2e.py"""
import asyncio, os, sys
from playwright.async_api import async_playwright
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
URL = "file://" + os.path.join(ROOT, "index.html")
U, P = "zztest01", "zz123456"
fails = []
def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond: fails.append(msg)

async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(executable_path="/usr/bin/google-chrome", args=["--no-sandbox"])
        ctx = await b.new_context(viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True)
        pg = await ctx.new_page(); errs = []
        pg.on("pageerror", lambda e: errs.append(str(e)))
        await pg.goto(URL); await pg.wait_for_timeout(1200)
        # 注册页：登录名、显示名各有虚线框提示，有选填邮箱
        await pg.click("#accTabUp"); await pg.wait_for_timeout(200)
        check(await pg.locator("#accForm .tip:visible").count() >= 2, "注册页有登录名、显示名的虚线框提示")
        check(await pg.locator("#accEmail").is_visible(), "注册页有邮箱（选填）")
        # 登录
        await pg.click("#accTabIn"); await pg.fill("#accUser", U); await pg.fill("#accPw", P)
        await pg.click("#accGo"); await pg.wait_for_timeout(2500)
        check("临时测试" in (await pg.inner_text("#accBtn")), "顶栏显示显示名")
        await pg.click("#accBtn"); await pg.wait_for_timeout(1200)
        check(await pg.locator("#me").is_visible(), "点显示名打开“我的”")
        check(await pg.locator("#me .tip").count() >= 2, "“我的”页有虚线框提示")
        check(await pg.input_value("#meUser") == U, "“我的”页登录名只读显示")
        # 改显示名 → 刷新仍在 → 改回
        await pg.fill("#meName", "临时测试二"); await pg.click("#meSave"); await pg.wait_for_timeout(1500)
        await pg.reload(); await pg.wait_for_timeout(2500)
        check("临时测试二" in (await pg.inner_text("#accBtn")), "改显示名后刷新仍是新名字")
        await pg.click("#accBtn"); await pg.wait_for_timeout(1000)
        await pg.fill("#meName", "临时测试"); await pg.click("#meSave"); await pg.wait_for_timeout(1500)
        # 错误的邀请码
        await pg.fill("#meCode", "ZZZZZZ"); await pg.click("#meJoin"); await pg.wait_for_timeout(1500)
        check("邀请码" in (await pg.inner_text("#meMsg")), "错误的邀请码有提示")
        # 改密码 → 用新密码登录 → 改回
        await pg.fill("#mePwOld", P); await pg.fill("#mePwNew", "zz654321"); await pg.fill("#mePwNew2", "zz654321")
        await pg.click("#mePwGo"); await pg.wait_for_timeout(1500)
        await pg.click("#meLogout"); await pg.wait_for_timeout(1500)
        await pg.fill("#accUser", U); await pg.fill("#accPw", "zz654321"); await pg.click("#accGo"); await pg.wait_for_timeout(2500)
        check("临时测试" in (await pg.inner_text("#accBtn")), "改密码后用新密码能登录")
        await pg.click("#accBtn"); await pg.wait_for_timeout(1000)
        await pg.fill("#mePwOld", "zz654321"); await pg.fill("#mePwNew", P); await pg.fill("#mePwNew2", P)
        await pg.click("#mePwGo"); await pg.wait_for_timeout(1500)
        check(await pg.is_checked("#meShow") is False, "总榜显示开关反映账号设置（临时账号已隐藏）")
        # 榜单：两个板块 + 三个时段；没有小组时不出现“我的小组”
        await pg.click("#meBack"); await pg.wait_for_timeout(500)
        await pg.click("#goBoard"); await pg.wait_for_timeout(2500)
        scopes = await pg.locator("#bScope button:visible").all_inner_texts()
        periods = await pg.locator("#bPeriod button").all_inner_texts()
        check(scopes == ["全部"], f"不在小组时榜单只有“全部”板块 {scopes}")
        check(periods == ["总榜", "本周", "今日"], f"每个板块里有总榜/本周/今日 {periods}")
        await pg.evaluate("ACC.groups=[{id:1,name:'G7'},{id:2,name:'G8'}];renderBoard()"); await pg.wait_for_timeout(300)
        check(await pg.locator("#bScope button:visible").all_inner_texts() == ["全部", "我的小组"], "在小组里时出现“我的小组”")
        # 主账号不受限制（页面内设标记，不用真实主账号）
        await pg.evaluate("ACC.me={...ACC.me,is_admin:true};TD.pending=['x'];")
        check(await pg.evaluate("UNITS.length>5 && unlocked(5) && pendingHere().length===0 && !hwBlock('all')"), "主账号：任意关卡可开，温习锁、作业锁不拦")
        await pg.evaluate("goMap()"); await pg.wait_for_timeout(800)
        check(await pg.locator("#adminBadge").is_visible(), "地图顶部有“主账号 · 不受限制”")
        await pg.evaluate("ACC.me={...ACC.me,is_admin:false};TD.pending=[];")
        check(not await pg.evaluate("unlocked(5) && !MEM[UNITS[4].key]"), "普通用户关卡仍按顺序解锁")
        # 多小组作业：逐个显示
        await pg.evaluate("TD.hw=[{group:'G7',pack:'约翰福音',daily:2},{group:'G8',pack:'罗马书',daily:1}];show('home');renderHome()")
        await pg.wait_for_timeout(500)
        check("G7" in (await pg.inner_text("#hwBar")), "首页作业条显示第一个小组的作业")
        await pg.evaluate("TD.hw=[];renderHome()")
        check(errs == [], f"页面没有报错 {errs[:3]}")
        await b.close()

asyncio.run(main())
print("\n%d 项失败" % len(fails)); sys.exit(1 if fails else 0)
