import { test } from "node:test";
import assert from "node:assert/strict";
import { db, rpc, one } from "./harness.mjs";
const MIGS = ["migrations_2026-11-28_users_groups.sql", "migrations_2026-11-28b_security_fix.sql"];
const login = (pg, u, p) => rpc(pg, "user_login", { p_username: u, p_password: p });

test("空密码不能登录（新旧两个入口）", async () => {
  const pg = await db({ migrate: MIGS });
  const r = await login(pg, "teacher", null);
  assert.equal(r.token, undefined); assert.equal(r.error, "BAD_LOGIN");
  await assert.rejects(rpc(pg, "student_login", { p_username: "teacher", p_password: null }), /BAD_LOGIN/);
});

test("改密码必须给对旧密码，空旧密码不行；改完其他设备的登录失效", async () => {
  const pg = await db({ migrate: MIGS });
  const t1 = (await login(pg, "km01", "123456")).token, t2 = (await login(pg, "km01", "123456")).token;
  await assert.rejects(rpc(pg, "user_change_password", { p_token: t1, p_old: null, p_new: "999999" }), /BAD_LOGIN/);
  await rpc(pg, "user_change_password", { p_token: t1, p_old: "123456", p_new: "999999" });
  assert.ok(await rpc(pg, "user_sync", { p_token: t1 }));
  await assert.rejects(rpc(pg, "user_sync", { p_token: t2 }), /SESSION_EXPIRED/);
});

test("连续输错 8 次会锁定 10 分钟（失败次数真的记下来）", async () => {
  const pg = await db({ migrate: MIGS });
  for (let i = 0; i < 8; i++) assert.equal((await login(pg, "km02", "000000")).error, "BAD_LOGIN");
  assert.equal((await login(pg, "km02", "123456")).error, "LOCKED");
});

test("带领者看不到其他带领者、主账号的初始密码；升为带领者时清掉初始密码明文", async () => {
  const pg = await db({ migrate: MIGS });
  const adm = (await login(pg, "teacher", "123456")).token;
  const g7 = Number((await one(pg, "select id from public.groups where name='G7'")).id);
  const k2 = Number((await one(pg, "select id from public.users where username='km02'")).id);
  // 新带领者 A 带 G7；km02 也是带领者并且在 G7 里
  const A = (await rpc(pg, "user_register", { p_username: "zzleada", p_name: "A", p_password: "abcdef" })).token;
  const a = Number((await one(pg, "select id from public.users where username='zzleada'")).id);
  await rpc(pg, "admin_set_leader", { p_token: adm, p_user: a, p_on: true });
  await rpc(pg, "admin_transfer_group", { p_token: adm, p_group: g7, p_leader: a });
  await pg.exec(`update public.users set pw_view='123456' where id=${k2}`);
  await rpc(pg, "admin_set_leader", { p_token: adm, p_user: k2, p_on: true });
  assert.equal((await one(pg, `select pw_view from public.users where id=${k2}`)).pw_view, null);
  await pg.exec(`update public.users set pw_view='123456' where id=${k2}`);
  const acc = await rpc(pg, "leader_accounts", { p_token: A, p_group: g7 });
  assert.equal(acc.find(r => r.username === "km02").password, "");
  assert.equal(acc.find(r => r.username === "km01").password, "123456");
});

test("“两个字母＋数字”格式留给批量建账号，自己注册不能用", async () => {
  const pg = await db({ migrate: MIGS });
  await assert.rejects(rpc(pg, "user_register", { p_username: "km999", p_name: "x", p_password: "abcdef" }), /RESERVED_USERNAME/);
  assert.ok((await rpc(pg, "user_register", { p_username: "km9x", p_name: "x", p_password: "abcdef" })).token);
});

test("取消带领者时，主账号不会同时是那个小组的组员", async () => {
  const pg = await db({ migrate: MIGS });
  const adm = (await login(pg, "teacher", "123456")).token;
  const A = (await rpc(pg, "user_register", { p_username: "zzleada", p_name: "A", p_password: "abcdef" })).token;
  const a = Number((await one(pg, "select id from public.users where username='zzleada'")).id);
  await rpc(pg, "admin_set_leader", { p_token: adm, p_user: a, p_on: true });
  const g = await rpc(pg, "leader_create_group", { p_token: A, p_name: "A组" });
  await rpc(pg, "user_join_group", { p_token: adm, p_code: g.invite_code });
  await rpc(pg, "admin_set_leader", { p_token: adm, p_user: a, p_on: false });
  assert.equal(Number((await one(pg, `select count(*) n from public.group_members m join public.users u on u.id=m.user_id where u.is_admin and m.group_id=${g.id}`)).n), 0);
});
