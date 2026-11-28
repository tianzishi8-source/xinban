import { test } from "node:test";
import assert from "node:assert/strict";
import { db, rpc, one } from "./harness.mjs";

test("基线：旧结构可登录、可保存进度", async () => {
  const pg = await db();
  const r = await rpc(pg, "student_login", { p_username: "km01", p_password: "123456" });
  assert.ok(r.token);
  await rpc(pg, "student_save_progress", { p_token: r.token, p_items: JSON.stringify([{ k: "u9", s: 3, a: 0 }]) });
  assert.equal(Number((await one(pg, "select count(*) n from public.students")).n), 5);
});
