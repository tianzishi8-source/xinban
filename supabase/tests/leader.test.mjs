import { test } from "node:test";
import assert from "node:assert/strict";
import { db, rpc, one, withKey } from "./harness.mjs";
const MIG = "migrations_2026-11-28_users_groups.sql";
const login = async (pg, u, p = "123456") => { const r = await rpc(pg, "user_login", { p_username: u, p_password: p }); if (r.error) throw new Error(r.error); return r.token; };
const reg = async (pg, u) => (await rpc(pg, "user_register", { p_username: u, p_name: u, p_password: "abcdef" })).token;
const idOf = async (pg, u) => Number((await one(pg, "select id from public.users where username=$1", [u])).id);

// 两个带领者 A、B 各带一个小组；U 是普通用户；M 在 B 的小组里
async function world() {
  const pg = await db({ migrate: [MIG, "migrations_2026-11-28b_security_fix.sql"] });
  const adm = await login(pg, "teacher");
  const A = await reg(pg, "zzleada"), B = await reg(pg, "zzleadb"), U = await reg(pg, "zzuser"), M = await reg(pg, "zzmember");
  await rpc(pg, "admin_set_leader", { p_token: adm, p_user: await idOf(pg, "zzleada"), p_on: true });
  await rpc(pg, "admin_set_leader", { p_token: adm, p_user: await idOf(pg, "zzleadb"), p_on: true });
  const ga = await rpc(pg, "leader_create_group", { p_token: A, p_name: "A组" });
  const gb = await rpc(pg, "leader_create_group", { p_token: B, p_name: "B组" });
  await rpc(pg, "user_join_group", { p_token: M, p_code: gb.invite_code });
  return { pg, adm, A, B, U, M, ga, gb };
}

test("建小组：自动前缀和邀请码，带领者不是本组组员", async () => {
  const { pg, A, ga } = await world();
  assert.match(ga.prefix, /^[a-z]{2}$/); assert.match(ga.invite_code, /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$/);
  await assert.rejects(rpc(pg, "user_join_group", { p_token: A, p_code: ga.invite_code }), /OWN_GROUP/);
  const gs = await rpc(pg, "leader_groups", { p_token: A });
  assert.deepEqual(gs.map(g => g.name), ["A组"]);
});

test("普通用户调用带领者函数报 NOT_LEADER", async () => {
  const { pg, U, ga } = await world();
  await assert.rejects(rpc(pg, "leader_groups", { p_token: U }), /NOT_LEADER/);
  await assert.rejects(rpc(pg, "leader_overview", { p_token: U, p_group: ga.id }), /NOT_LEADER/);
  await assert.rejects(rpc(pg, "admin_users", { p_token: U, p_q: "" }), /NOT_ADMIN/);
});

test("带领者越界：看 B 组、重置 B 组组员、重置 B、重置主账号，全部 FORBIDDEN", async () => {
  const { pg, A, gb } = await world();
  const m = await idOf(pg, "zzmember"), b = await idOf(pg, "zzleadb"), t = await idOf(pg, "teacher");
  await assert.rejects(rpc(pg, "leader_overview", { p_token: A, p_group: gb.id }), /FORBIDDEN/);
  await assert.rejects(rpc(pg, "leader_accounts", { p_token: A, p_group: gb.id }), /FORBIDDEN/);
  await assert.rejects(rpc(pg, "leader_user_detail", { p_token: A, p_user: m }), /FORBIDDEN/);
  await assert.rejects(rpc(pg, "leader_reset_password", { p_token: A, p_user: m }), /FORBIDDEN/);
  await assert.rejects(rpc(pg, "leader_reset_password", { p_token: A, p_user: b }), /FORBIDDEN/);
  await assert.rejects(rpc(pg, "leader_reset_password", { p_token: A, p_user: t }), /FORBIDDEN/);
  await assert.rejects(rpc(pg, "admin_set_leader", { p_token: A, p_user: m, p_on: true }), /NOT_ADMIN/);
});

test("带领者不能重置也在自己组里的另一个带领者", async () => {
  const { pg, A, B, ga } = await world();
  await rpc(pg, "user_join_group", { p_token: B, p_code: ga.invite_code });
  await assert.rejects(rpc(pg, "leader_reset_password", { p_token: A, p_user: await idOf(pg, "zzleadb") }), /FORBIDDEN/);
});

test("带领者管理自己的组员：改显示名、重置 6 位密码、移出", async () => {
  const { pg, B, gb } = await world();
  const m = await idOf(pg, "zzmember");
  await rpc(pg, "leader_rename_user", { p_token: B, p_user: m, p_name: "改过的名字" });
  const pw = await rpc(pg, "leader_reset_password", { p_token: B, p_user: m });
  assert.match(pw, /^[0-9]{6}$/);
  assert.ok(await login(pg, "zzmember", pw));
  const acc = await rpc(pg, "leader_accounts", { p_token: B, p_group: gb.id });
  assert.equal(acc[0].name, "改过的名字"); assert.equal(acc[0].password, pw);
  await rpc(pg, "leader_remove_member", { p_token: B, p_group: gb.id, p_user: m });
  assert.equal((await rpc(pg, "leader_accounts", { p_token: B, p_group: gb.id })).length, 0);
  assert.equal(Number((await one(pg, "select count(*) n from public.users where id=$1", [m])).n), 1);
});

test("批量建账号：接着前缀已有最大编号往下，6 位数字密码，自动入组", async () => {
  const { pg, adm } = await world();
  const g7 = Number((await one(pg, "select id from public.groups where name='G7'")).id); // 前缀 km，已有 km01 km02
  await pg.exec("insert into public.users(name,username,pw_hash) values ('占位','km09','x'),('别人','km10','x')");
  const r = await rpc(pg, "leader_add_users", { p_token: adm, p_group: g7, p_count: 3 });
  assert.deepEqual(r.map(x => x.username), ["km11", "km12", "km13"]);
  assert.ok(r.every(x => /^[0-9]{6}$/.test(x.password) && x.name === x.username));
  const r2 = await rpc(pg, "leader_add_users", { p_token: adm, p_group: g7, p_names: ["小明", " ", "小红"] });
  assert.deepEqual(r2.map(x => [x.username, x.name]), [["km14", "小明"], ["km15", "小红"]]);
  assert.equal(Number((await one(pg, `select count(*) n from public.group_members where group_id=${g7}`)).n), 7);
});

test("邀请码重新生成后旧码立刻失效", async () => {
  const { pg, A, U, ga } = await world();
  const code = await rpc(pg, "leader_regen_code", { p_token: A, p_group: ga.id });
  assert.notEqual(code, ga.invite_code);
  await assert.rejects(rpc(pg, "user_join_group", { p_token: U, p_code: ga.invite_code }), /BAD_CODE/);
  assert.equal((await rpc(pg, "user_join_group", { p_token: U, p_code: code })).name, "A组");
});

test("主账号：看所有小组、取消带领者后小组转给主账号、转让小组、把人加进小组", async () => {
  const { pg, adm, A, ga, gb } = await world();
  assert.ok((await rpc(pg, "leader_groups", { p_token: adm })).length >= 4);
  await rpc(pg, "admin_set_leader", { p_token: adm, p_user: await idOf(pg, "zzleada"), p_on: false });
  assert.equal(Number((await one(pg, `select leader_id from public.groups where id=${ga.id}`)).leader_id), await idOf(pg, "teacher"));
  await assert.rejects(rpc(pg, "leader_groups", { p_token: A }), /NOT_LEADER/);
  await rpc(pg, "admin_transfer_group", { p_token: adm, p_group: ga.id, p_leader: await idOf(pg, "zzleadb") });
  await rpc(pg, "admin_add_member", { p_token: adm, p_group: gb.id, p_user: await idOf(pg, "ding") });
  const us = await rpc(pg, "admin_users", { p_token: adm, p_q: "ding" });
  assert.equal(us.length, 1); assert.equal(us[0].groups, "B组");
});

test("带领者看组员详情、日报、作业、句子并写评语", async () => {
  const { pg, adm } = await world();
  const g7 = Number((await one(pg, "select id from public.groups where name='G7'")).id), k1 = await idOf(pg, "km01");
  assert.equal((await rpc(pg, "leader_overview", { p_token: adm, p_group: g7 })).length, 2);
  assert.ok((await rpc(pg, "leader_user_detail", { p_token: adm, p_user: k1 })).progress.length > 0);
  assert.equal((await rpc(pg, "leader_user_days", { p_token: adm, p_user: k1, p_days: 3 })).length, 3);
  assert.equal((await rpc(pg, "leader_day", { p_token: adm, p_group: g7, p_day: new Date().toISOString().slice(0, 10) })).length, 2);
  assert.equal((await rpc(pg, "leader_hw_day", { p_token: adm, p_group: g7, p_day: "2026-11-28" })).length, 2);
  const w = await rpc(pg, "leader_writings", { p_token: adm, p_group: g7, p_days: 30 });
  await rpc(pg, "leader_note_writing", { p_token: adm, p_id: w[0].id, p_note: "写得好" });
  assert.equal((await one(pg, `select note from public.writings where id=${w[0].id}`)).note, "写得好");
  await rpc(pg, "leader_set_homework", { p_token: adm, p_group: g7, p_pack: "约翰福音", p_daily: 3 });
  assert.equal((await one(pg, `select hw_pack from public.groups where id=${g7}`)).hw_pack, "约翰福音");
});

test("带领者钥匙：请求头 x-leader-key 也能认出主账号", async () => {
  const { pg } = await world();
  await withKey(pg, "tk");
  assert.ok((await rpc(pg, "leader_groups", { p_token: null })).length >= 2);
  await withKey(pg, null);
  await assert.rejects(rpc(pg, "leader_groups", { p_token: null }), /SESSION_EXPIRED|NOT_LEADER/);
});
