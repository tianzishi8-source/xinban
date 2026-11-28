"""带领者后台测试：本地 leader.html，服务器用假数据代替（不碰线上数据）。
每个被调用的函数名和参数名都和迁移文件里的真实签名核对。运行：python3 tests/e2e/leader_e2e.py"""
import asyncio, json, os, re, sys
from playwright.async_api import async_playwright
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
URL = "file://" + os.path.join(ROOT, "leader.html")
SQL = open(os.path.join(ROOT, "supabase/migrations_2026-11-28_users_groups.sql"), encoding="utf-8").read()
SIGS = {m[1]: set(re.findall(r"(p_\w+)", m[2])) for m in re.finditer(r"function public\.(\w+)\((.*?)\)\s*(?:returns|\n)", SQL, re.S)}
fails = []
def check(c, msg):
    print(("ok   " if c else "FAIL ") + msg)
    if not c: fails.append(msg)

def fixtures(admin, leader=True, bad_login=False):
    me = {"id": 9, "username": "zzlead", "name": "带领者甲", "is_leader": leader, "is_admin": admin, "pw_is_initial": False, "show_on_board": True, "email": None}
    G = [{"id": 1, "name": "G7", "prefix": "km", "invite_code": "ABCDEF", "hw_pack": None, "hw_daily": 0, "members": 2, "leader_id": 9, "leader_name": "带领者甲", "created_at": "2026-11-01"}]
    acc = [{"id": 11, "name": "甲", "username": "km01", "password": "123456", "last_seen": None, "is_leader": False},
           {"id": 12, "name": "乙", "username": "km02", "password": "", "last_seen": None, "is_leader": False}]
    ov = [{"id": 11, "name": "甲", "username": "km01", "today_sec": 60, "week_sec": 60, "total_sec": 60, "passed": 1, "stars": 3, "adv": 0, "tests": 1, "best_score": 100, "last_score": 100, "last_seen": None}]
    return {
        "user_login": {"error": "BAD_LOGIN"} if bad_login else {"token": "T", "me": me},
        "leader_me": me if (leader or admin) else {"__error": "NOT_LEADER"},
        "leader_groups": G, "leader_accounts": acc, "leader_overview": ov, "leader_day": [], "leader_hw_day": [], "leader_writings": [],
        "leader_regen_code": "GHJKLM", "leader_reset_password": "654321", "leader_set_homework": None, "leader_rename_user": None, "leader_remove_member": None,
        "leader_add_users": [{"name": "km03", "username": "km03", "password": "111111"}, {"name": "km04", "username": "km04", "password": "222222"}, {"name": "km05", "username": "km05", "password": "333333"}],
        "leader_user_detail": {"today": "2026-11-28", "usage": [], "tests": [], "progress": []}, "leader_user_days": [],
        "admin_users": [{"id": 9, "username": "zzlead", "name": "带领者甲", "email": None, "is_leader": True, "is_admin": True, "show_on_board": True, "last_seen": None, "groups": None, "stars": 0},
                        {"id": 11, "username": "km01", "name": "甲", "email": None, "is_leader": False, "is_admin": False, "show_on_board": True, "last_seen": None, "groups": "G7", "stars": 3}],
        "admin_set_leader": None, "admin_add_member": None, "admin_transfer_group": None,
    }

async def run(p, admin, leader=True, bad_login=False, key=None):
    calls = []
    b = await p.chromium.launch(executable_path="/usr/bin/google-chrome", args=["--no-sandbox"])
    pg = await (await b.new_context(viewport={"width": 1100, "height": 900})).new_page(); errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.on("dialog", lambda d: asyncio.ensure_future(d.accept()))
    F = fixtures(admin, leader, bad_login)
    async def handle(route):
        fn = route.request.url.rsplit("/", 1)[-1]; body = json.loads(route.request.post_data or "{}"); calls.append((fn, body))
        v = F.get(fn, None)
        if isinstance(v, dict) and "__error" in v:
            await route.fulfill(status=400, content_type="application/json", body=json.dumps({"message": v["__error"]})); return
        await route.fulfill(status=200, content_type="application/json", body=json.dumps(v))
    await pg.route("**/rest/v1/rpc/*", handle)
    await pg.goto(URL + (f"#k={key}" if key else "")); await pg.wait_for_timeout(800)
    if key: await pg.wait_for_timeout(800); return b, pg, calls, errs
    await pg.fill("#user", "zzlead"); await pg.fill("#pass", "123456"); await pg.click("#authGo"); await pg.wait_for_timeout(1200)
    return b, pg, calls, errs

async def main():
    async with async_playwright() as p:
        # 普通用户进不来
        b, pg, calls, errs = await run(p, admin=False, leader=False)
        check("你还不是带领者" in await pg.inner_text("#authMsg"), "普通用户登录时提示“你还不是带领者”")
        check(await pg.locator("#app").is_hidden(), "普通用户看不到后台")
        await b.close()
        # 带领者
        b, pg, calls, errs = await run(p, admin=False)
        check(await pg.locator("#app").is_visible(), "带领者能进入后台")
        check("ABCDEF" in await pg.inner_text("#codeBox"), "显示小组邀请码")
        await pg.click("#regenCode"); await pg.wait_for_timeout(500)
        check("GHJKLM" in await pg.inner_text("#codeBox"), "重新生成后显示新邀请码")
        check(await pg.locator("#vUsers").is_hidden(), "带领者看不到“全部用户”")
        await pg.click("#vAcct"); await pg.wait_for_timeout(600)
        check(await pg.locator("#acctView .tip").count() >= 2, "账号页有登录名、显示名的虚线框提示")
        await pg.fill("#addCount", "3"); await pg.click("#addGo"); await pg.wait_for_timeout(600)
        add = [c for c in calls if c[0] == "leader_add_users"]
        check(bool(add) and add[-1][1].get("p_count") == 3 and add[-1][1].get("p_group") == 1, "按人数批量建账号（p_count=3）")
        check("111111" in await pg.inner_text("#newAccts"), "批量建账号后显示新账号和初始密码")
        await pg.click('#acctTbl tr[data-id="11"] [data-op="pw"]'); await pg.wait_for_timeout(600)
        check("654321" in await pg.inner_text("#acctTbl"), "重置密码后显示新密码")
        txt = await pg.inner_text("body")
        bad = [w for w in ["老师", "班级", "学生"] if w in txt]
        check(not bad, f"页面上不再出现旧叫法 {bad}")
        check(errs == [], f"页面没有报错 {errs[:2]}")
        all_calls = calls; await b.close()
        # 主账号
        b, pg, calls, errs = await run(p, admin=True)
        check(await pg.locator("#vUsers").is_visible(), "主账号看得到“全部用户”")
        await pg.click("#vUsers"); await pg.wait_for_timeout(600)
        check("km01" in await pg.inner_text("#usersTbl"), "“全部用户”列出用户")
        await pg.fill("#uq", "km"); await pg.press("#uq", "Enter"); await pg.wait_for_timeout(500)
        check(any(c[0] == "admin_users" and c[1].get("p_q") == "km" for c in calls), "可以搜索用户")
        await pg.click('#usersTbl tr[data-id="11"] [data-op="lead"]'); await pg.wait_for_timeout(500)
        check(any(c[0] == "admin_set_leader" and c[1] == {"p_token": "T", "p_user": 11, "p_on": True} for c in calls), "可以指定带领者")
        check(errs == [], f"主账号页面没有报错 {errs[:2]}")
        # 把当前小组交给带领者（km01 不是带领者，所以用 fixture 里把他改成带领者再画一次）
        await pg.evaluate("USERS[1].is_leader=true;drawUsers()")
        await pg.click('#usersTbl tr[data-id="11"] [data-op="give"]'); await pg.wait_for_timeout(500)
        check(any(c[0] == "admin_transfer_group" and c[1].get("p_group") == 1 and c[1].get("p_leader") == 11 for c in calls), "主账号可以把小组交给带领者")
        all_calls += calls; await b.close()
        # 登录失败用 {error} 返回时也能提示
        b, pg, calls, errs = await run(p, admin=False, bad_login=True)
        check("登录名或密码不对" in await pg.inner_text("#authMsg"), "登录名或密码不对时有提示")
        await b.close()
        # 专属链接（没有登录凭证）：主账号也看不到“全部用户”，不会被踢出
        b, pg, calls, errs = await run(p, admin=True, key="k" * 24)
        check(await pg.locator("#app").is_visible() and await pg.locator("#vUsers").is_hidden(), "专属链接打开时不显示“全部用户”")
        # 每个调用都和真实函数签名一致
        bad = [(f, sorted(set(a) - SIGS.get(f, set()))) for f, a in all_calls if f not in SIGS or set(a) - SIGS[f]]
        check(not bad, f"所有调用的函数名和参数名都存在于数据库 {bad[:4]}")

asyncio.run(main())
print("\n%d 项失败" % len(fails)); sys.exit(1 if fails else 0)
