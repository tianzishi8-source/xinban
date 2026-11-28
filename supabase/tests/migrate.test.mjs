import { test } from "node:test";
import assert from "node:assert/strict";
import { db, rpc, one } from "./harness.mjs";
const MIG = "migrations_2026-11-28_users_groups.sql";
const n = async (pg, sql) => Number((await one(pg, sql)).n);
const TABLES = ["progress", "plays", "tests", "usage_daily", "reviews", "review_days", "hw_days", "writings"];

test("迁移：所有记录条数不变，每人星星不变", async () => {
  const pg = await db();
  const before = {};
  for (const t of TABLES) before[t] = await n(pg, `select count(*) n from public.${t}`);
  before.users = await n(pg, "select count(*) n from public.students");
  before.sessions = await n(pg, "select count(*) n from private.sessions");
  const stars = (await pg.query("select s.username u, sum(p.stars)::int s from public.students s join public.progress p on p.student_id=s.id group by 1 order by 1")).rows;
  await pg.exec((await import("node:fs")).readFileSync(new URL("../" + MIG, import.meta.url), "utf8"));
  for (const t of TABLES) assert.equal(await n(pg, `select count(*) n from public.${t}`), before[t], t);
  assert.equal(await n(pg, "select count(*) n from public.users"), before.users);
  assert.equal(await n(pg, "select count(*) n from private.sessions"), before.sessions);
  const after = (await pg.query("select u.username u, sum(p.stars)::int s from public.users u join public.progress p on p.user_id=u.id group by 1 order by 1")).rows;
  assert.deepEqual(after, stars);
});

test("迁移：小组、组员、主账号、邀请码、带领者钥匙", async () => {
  const pg = await db({ migrate: [MIG] });
  const t = await one(pg, "select id,is_admin,show_on_board from public.users where username='teacher'");
  assert.equal(t.is_admin, true); assert.equal(t.show_on_board, false);
  assert.equal(await n(pg, "select count(*) n from public.users where is_admin"), 1);
  // 普通班变成小组，开放班、隐藏班删除；成员仍然在 users 里
  assert.deepEqual((await pg.query("select name from public.groups order by name")).rows.map(r => r.name), ["G7", "G8"]);
  assert.equal(await n(pg, `select count(*) n from public.groups where leader_id=${t.id}`), 2);
  assert.equal(await n(pg, "select count(*) n from public.groups where invite_code ~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$'"), 2);
  assert.equal(await n(pg, "select count(distinct invite_code) n from public.groups"), 2);
  assert.equal(await n(pg, "select count(*) n from public.group_members"), 3); // km01 km02 pq01
  assert.equal(await n(pg, "select count(*) n from public.users where username in ('ding','teacher')"), 2);
  assert.equal(await n(pg, "select count(*) n from public.group_members m join public.users u on u.id=m.user_id where u.username in ('ding','teacher')"), 0);
  assert.equal(await n(pg, `select count(*) n from private.leader_keys where user_id=${t.id}`), 1);
  assert.equal(await n(pg, "select count(*) n from pg_tables where tablename in ('students','classes','teacher_keys')"), 0);
});

test("迁移：旧页面的 student_* 仍可用，写进新表", async () => {
  const pg = await db({ migrate: [MIG] });
  const r = await rpc(pg, "student_login", { p_username: "km01", p_password: "123456" });
  assert.ok(r.token);
  await rpc(pg, "student_save_progress", { p_token: r.token, p_items: JSON.stringify([{ k: "u9", s: 3, a: 0 }]) });
  assert.equal(await n(pg, "select count(*) n from public.progress p join public.users u on u.id=p.user_id where u.username='km01' and unit_key='u9'"), 1);
  const s = await rpc(pg, "student_sync", { p_token: r.token });
  assert.ok(s);
});

test("迁移：重复执行会明确报错，不改任何数据", async () => {
  const pg = await db({ migrate: [MIG] });
  const sql = (await import("node:fs")).readFileSync(new URL("../" + MIG, import.meta.url), "utf8");
  await assert.rejects(pg.exec(sql), /ALREADY_MIGRATED/);
  assert.equal(await n(pg, "select count(*) n from public.users"), 5);
});
