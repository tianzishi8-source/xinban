import { test } from "node:test";
import assert from "node:assert/strict";
import { db, rpc, one } from "./harness.mjs";
const MIG = "migrations_2026-11-28_users_groups.sql";
const login = async (pg, u, p = "123456") => (await rpc(pg, "user_login", { p_username: u, p_password: p })).token;
const reg = (pg, u, name = u, pw = "abcdef", email = null) => rpc(pg, "user_register", { p_username: u, p_name: name, p_password: pw, p_email: email });

test("注册：登录名重复、密码太短报错；邮箱可空；返回 me", async () => {
  const pg = await db({ migrate: [MIG] });
  const r = await reg(pg, "zzalice", "爱丽丝");
  assert.ok(r.token); assert.equal(r.me.name, "爱丽丝"); assert.equal(r.me.email, null); assert.equal(r.me.is_admin, false);
  await assert.rejects(reg(pg, "zzalice"), /USERNAME_TAKEN/);
  await assert.rejects(reg(pg, "zzbob", "b", "12345"), /BAD_PASSWORD/);
  await assert.rejects(reg(pg, "zzbob", "b", "123456", "not-an-email"), /BAD_EMAIL/);
  assert.equal((await reg(pg, "km99", "可以用前缀格式")).me.username, "km99");
});

test("改资料、改密码：旧密码失效，初始密码明文被清空", async () => {
  const pg = await db({ migrate: [MIG] });
  const t = await login(pg, "km01");
  assert.equal((await rpc(pg, "user_sync", { p_token: t })).me.pw_is_initial, true);
  const me = await rpc(pg, "user_update_profile", { p_token: t, p_name: "新名字", p_email: "a@b.cn", p_show_on_board: false });
  assert.equal(me.name, "新名字"); assert.equal(me.email, "a@b.cn"); assert.equal(me.show_on_board, false);
  await assert.rejects(rpc(pg, "user_change_password", { p_token: t, p_old: "wrong1", p_new: "654321" }), /BAD_LOGIN/);
  await rpc(pg, "user_change_password", { p_token: t, p_old: "123456", p_new: "654321" });
  await assert.rejects(login(pg, "km01"), /BAD_LOGIN/);
  assert.ok(await login(pg, "km01", "654321"));
  assert.equal((await one(pg, "select pw_view from public.users where username='km01'")).pw_view, null);
});

test("小组：邀请码加入、错误码、重复加入、退出", async () => {
  const pg = await db({ migrate: [MIG] });
  const t = (await reg(pg, "zzcarl")).token;
  const g = await one(pg, "select id, invite_code from public.groups where name='G7'");
  await assert.rejects(rpc(pg, "user_join_group", { p_token: t, p_code: "ZZZZZZ" }), /BAD_CODE/);
  assert.equal((await rpc(pg, "user_join_group", { p_token: t, p_code: g.invite_code.toLowerCase() })).name, "G7");
  await rpc(pg, "user_join_group", { p_token: t, p_code: g.invite_code });
  assert.equal((await rpc(pg, "user_sync", { p_token: t })).groups.length, 1);
  await rpc(pg, "user_leave_group", { p_token: t, p_group: g.id });
  assert.equal((await rpc(pg, "user_sync", { p_token: t })).groups.length, 0);
});

test("总榜隐私：隐藏的人对别人不可见，对本人可见，主账号可见并标 hidden", async () => {
  const pg = await db({ migrate: [MIG] });
  const a = await login(pg, "km01"), b = await login(pg, "pq01"), adm = await login(pg, "teacher");
  await rpc(pg, "user_update_profile", { p_token: a, p_show_on_board: false });
  const names = r => r.rows.map(x => x.name);
  assert.ok(!names(await rpc(pg, "leaderboard", { p_token: b, p_kind: "stars" })).includes("甲"));
  assert.ok(names(await rpc(pg, "leaderboard", { p_token: a, p_kind: "stars" })).includes("甲"));
  const ar = await rpc(pg, "leaderboard", { p_token: adm, p_kind: "stars" });
  assert.equal(ar.rows.find(x => x.name === "甲").hidden, true);
  assert.equal(ar.rows.find(x => x.name === "丙").hidden, false);
});

test("小组榜：只列本组组员，不受隐藏影响；非组员报错", async () => {
  const pg = await db({ migrate: [MIG] });
  const a = await login(pg, "km01"), b = await login(pg, "pq01");
  await rpc(pg, "user_update_profile", { p_token: a, p_show_on_board: false });
  const g7 = (await one(pg, "select id from public.groups where name='G7'")).id;
  const r = await rpc(pg, "leaderboard", { p_token: a, p_kind: "stars", p_scope: "group", p_group: g7 });
  assert.deepEqual(r.rows.map(x => x.name).sort(), ["乙", "甲"]);
  await assert.rejects(rpc(pg, "leaderboard", { p_token: b, p_kind: "stars", p_scope: "group", p_group: g7 }), /NOT_MEMBER/);
  const t = await rpc(pg, "leaderboard", { p_token: a, p_kind: "test", p_pack: "约翰福音", p_period: "week" });
  assert.ok(t.rows.length > 0);
});

test("多个小组都有作业：today.hw 逐个列出；作业记录按经文包各一条", async () => {
  const pg = await db({ migrate: [MIG] });
  await pg.exec("update public.groups set hw_pack='约翰福音', hw_daily=3 where name='G7'; update public.groups set hw_pack='罗马书', hw_daily=2 where name='G8'");
  const t = await login(pg, "km01");
  await rpc(pg, "user_join_group", { p_token: t, p_code: (await one(pg, "select invite_code c from public.groups where name='G8'")).c });
  const td = await rpc(pg, "user_today", { p_token: t });
  assert.deepEqual(td.hw.map(h => h.pack), ["约翰福音", "罗马书"]);
  await rpc(pg, "user_hw_report", { p_token: t, p_pack: "约翰福音", p_new: 3, p_target: 3 });
  await rpc(pg, "user_hw_report", { p_token: t, p_pack: "罗马书", p_new: 1, p_target: 2 });
  assert.equal(Number((await one(pg, "select count(*) n from public.hw_days")).n), 2);
  assert.equal((await rpc(pg, "student_today", { p_token: t })).hw_pack, "约翰福音");
});
