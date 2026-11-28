# 统一账号、小组与主账号 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace students/classes/teachers with one account system (users, groups, leaders, one admin) without losing a single existing record.

**Architecture:** Rename tables and columns **in place** (`students→users`, `classes→groups`, `student_id→user_id`), so no row is ever copied. Add `group_members`, role flags and invite codes. Rewrite the RPC layer as `user_*` and `leader_*` functions; leaders authenticate with the same session token as everyone else. Thin `student_*` compatibility wrappers keep the currently deployed page working between the DB migration and the frontend push. A final task removes them, along with every other legacy name.

**Tech Stack:** Supabase Postgres 17 (plpgsql RPCs, pgcrypto `crypt`), single-file vanilla JS pages (`index.html`, `leader.html`), GitHub Pages. Tests: Node + `@electric-sql/pglite` (in-process Postgres) for SQL; Playwright + system Chrome for pages.

**Spec:** `docs/superpowers/specs/2026-11-28-accounts-groups-design.md`

## Global Constraints

- 底线：现有用户的所有记录完整保留。生产库基线：users 31，classes 6，sessions 45，progress 518（星星合计 1495），plays 483，tests 430，usage_daily 85，reviews 10，review_days 6，hw_days 0，writings 7，teacher_keys 1。
- 登录名 `^[a-z0-9]{2,24}$`，建好后不能改。显示名 1–20 字。
- 初始密码和重置密码都是 6 位数字。用户自己设的密码至少 6 位。
- 邀请码 6 位，字符集 `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`。重新生成后旧码立刻失效。
- 小组前缀 `^[a-z]{2}$`，全局唯一。现有班级的前缀保留不变。
- 主账号 = 现有用户 `teacher`，只有这一个。
- 不改视觉风格，新界面沿用现有的 class 和颜色。
- 凡是出现登录名、显示名的界面，都要加虚线框提示 `.tip`。文案固定如下：
  - 登录名：登录时用，只有你自己知道，建好后不能改
  - 显示名：别人在榜单和小组里看到的名字，随时可以改
- 用户自己改密码后，要清空 `pw_view`（明文初始密码）。
- 最终命名：`users`、`groups`、`group_members`、`user_*`、`leader_*`、`leader.html`、`x-leader-key`、`private.leader_keys`。

## Review Focus

1. 生产迁移对不上数时，必须整体回滚，不能只改一半。由 Task 6 的核对块保证。
2. 带领者跨越权限边界：读取或修改别的小组的组员，或者重置另一个带领者、主账号的密码。由 Task 4 的测试覆盖。
3. 迁移期间旧版网页仍然在线：旧页面调用的 `student_*` 要照常工作，进度不能丢。由 Task 2 的兼容层测试覆盖。
4. 一个用户在多个小组、多个小组都设了作业时，作业锁和首页进度要逐个小组判断。由 Task 3 的 `user_sync` 测试和 Task 7 覆盖。
5. 用户隐藏了自己：总榜上普通人看不到他，主账号能看到并标"已隐藏"，他自己能看到自己的名次。由 Task 3 覆盖。

---

## File Structure

- `supabase/tests/harness.mjs`（新建）：在 PGlite 里重建生产库结构，载入数据快照，导出 `db()` 和 `rpc(fn,args)`。
- `supabase/tests/prod_schema.sql`（新建）：生产库的结构和函数快照，从线上直接导出。不进仓库，写进 `.gitignore`。
- `supabase/tests/snapshot.json`（新建）：生产数据快照。不进仓库，写进 `.gitignore`。
- `supabase/tests/*.test.mjs`（新建）：用 `node --test` 运行的测试。
- `supabase/migrations_2026-11-28_users_groups.sql`（新建）：表改名、加字段、回填数据、新函数、兼容层、核对块。
- `supabase/migrations_2026-11-29_cleanup.sql`（新建）：删兼容层、旧函数、`teacher_id` 列等。
- `index.html`（修改）：改用新函数；加"我的"页、注册新字段、榜单两个板块、多小组作业、主账号不受限。
- `leader.html`（由 `teacher.html` 改名并重写登录部分）。
- `tests/e2e/*.mjs`（新建）：Playwright 冒烟测试，针对生产库，使用临时测试账号。
- `README.md`：更新文档。

---

### Task 1: 备份与本地测试环境

**Files:**
- Create: `supabase/tests/harness.mjs`
- Create: `supabase/tests/baseline.test.mjs`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `async function db(): PGlite`，每次返回一份全新的生产快照副本；`async function rpc(pg, fn, args): any`，用来调用 `public.fn`。

- [ ] **Step 1: 导出备份。** 通过 Supabase SQL，把 public 和 private 两个 schema 下每张表都导出为 `json_agg`，存成 `/home/claude/backup/xinban-2026-11-28.json`。再用 `pg_get_functiondef` 和建表语句导出 `prod_schema.sql`。导出后把备份文件发给主账号保存。
- [ ] **Step 2: 写 `baseline.test.mjs`。** 测试载入快照后各表条数等于 Global Constraints 里的基线，并且 `sum(progress.stars)=1495`。
- [ ] **Step 3: 实现 `harness.mjs`。**
  - 用 PGlite 加载 pgcrypto。
  - 用桩函数补出 `auth.users`、`auth.uid()` 和 `extensions` schema。
  - 执行 `prod_schema.sql`，再插入快照数据。
- [ ] **Step 4: 运行。** `node --test supabase/tests/baseline.test.mjs`，预期 PASS。
- [ ] **Step 5: 提交。** 只提交 harness、测试和 `.gitignore`，不提交快照和备份。

### Task 2: 迁移——改名、新字段、回填、兼容层

**Files:**
- Create: `supabase/migrations_2026-11-28_users_groups.sql`
- Test: `supabase/tests/migrate.test.mjs`

**Interfaces:**
- Produces：
  - `public.users`：原有各列，外加 `email text null unique`、`show_on_board bool default true`、`is_leader bool default false`、`is_admin bool default false`。`name` 列就是显示名，`class_id` 列在清理阶段删除。
  - `public.groups`：原有各列，外加 `leader_id bigint references users`、`invite_code text unique`、`hw_enabled bool`。
  - `public.group_members(group_id, user_id, joined_at)`，主键是 `(group_id, user_id)`。
  - 各表的 `student_id` 列统一改名为 `user_id`。
  - `private.sessions.user_id`。
  - `private.leader_keys(key_hash bytea pk, user_id bigint)`。
  - `private.user_of(p_token text) returns bigint`。
  - `private.new_invite_code() returns text`。

- [ ] **Step 1: 写测试。** 迁移后各表条数和基线完全相同，每个 `user_id` 的星星和迁移前相同，并且：
  - `group_members` 的数量 = 迁移前不属于"开放班"和"隐藏班"的学生数（实测 24）。
  - `teacher` 用户 `is_admin=true`，`show_on_board=false`。
  - 4 个普通班的 `leader_id` 都是 teacher，邀请码各不相同且符合字符集。
  - 开放班和隐藏班已删除，但它们的成员仍然存在于 `users` 里。
  - 唯一的那个 teacher key 已经转换成 `leader_keys` 里属于 teacher 的一行。
  - 旧函数 `student_login`、`student_save_progress` 仍然可以调用，并且写进新表。
- [ ] **Step 2: 运行，确认失败。**
- [ ] **Step 3: 写迁移。** 整个迁移放在一个事务里：
  - 用 `alter table ... rename` 改名，所有外键跟着自动更新。
  - 先把 `users.class_id` 改成可空，再删除开放班和隐藏班。不能依赖级联删除，删之前先把这两个班成员的 `class_id` 置空。
  - 旧函数改写成调用新函数的单行包装。
  - 迁移末尾加一个 `do $$` 核对块：任何一项条数不等就 `raise exception`，让整个事务回滚。
- [ ] **Step 4: 运行，确认通过。**
- [ ] **Step 5: 提交。**

### Task 3: 用户端函数 `user_*` 与榜单

**Files:**
- Modify: `supabase/migrations_2026-11-28_users_groups.sql`
- Test: `supabase/tests/user.test.mjs`

**Interfaces:**
- Produces：`user_*` 和原来的 `student_*` 一一对应，参数相同，只把 `p_token` 统一放在第一位：
  - `user_login`、`user_logout`、`user_sync`、`user_heartbeat`、`user_save_progress`、`user_save_plays`、`user_save_test`、`user_save_review`、`user_hw_report`、`user_today`、`user_save_writing`、`user_writings`
- 新增：
  - `user_register(p_username, p_name, p_password, p_email default null)`
  - `user_update_profile(p_token, p_name, p_email, p_show_on_board)`
  - `user_change_password(p_token, p_old, p_new)`：改完后把 `pw_view` 置空。
  - `user_join_group(p_token, p_code)`：返回 `{id, name}`。
  - `user_leave_group(p_token, p_group)`
  - `leaderboard(p_token, p_kind, p_period, p_scope 'all'|'group', p_group bigint default null, p_pack default null)`
  - `leaderboard_packs(p_token)`
- `user_sync` 额外返回：
  - `me: {id, username, name, email, show_on_board, is_leader, is_admin, pw_is_initial}`
  - `groups: [{id, name, hw_pack, hw_daily, board}]`

- [ ] **Step 1: 写测试。** 覆盖以下行为：
  - 注册时登录名重复会报错。密码少于 6 位会报错。邮箱可以为空。
  - 改密码后旧密码失效，`pw_view` 被清空。
  - 用邀请码可以加入小组，错误的码会报错，重复加入不会出错，退出后 `groups` 里就没有这个小组了。
  - 总榜上 `show_on_board=false` 的人对普通用户不可见，对主账号可见并带 `hidden:true`，对他本人也可见。
  - 选 `p_scope='group'` 时只列出本组成员，不受隐藏开关影响。不是组员却查询小组榜会报错。
  - 一个人加入两个都设了作业的小组时，`user_sync.groups` 返回两个小组的作业。
- [ ] **Step 2: 运行，确认失败。**
- [ ] **Step 3: 实现。** 从线上导出的 `student_*` 函数体出发改写。兼容层改为调用新函数。
- [ ] **Step 4: 运行，确认通过。**
- [ ] **Step 5: 提交。**

### Task 4: 带领者与主账号函数 `leader_*`

**Files:**
- Modify: `supabase/migrations_2026-11-28_users_groups.sql`
- Test: `supabase/tests/leader.test.mjs`

**Interfaces:**
- 鉴权：每个函数的第一个参数都是 `p_token`。另外，请求头带 `x-leader-key` 也可以，换算成对应用户。调用者必须 `is_leader` 或 `is_admin`，否则报 `not_leader`。
- 权限 helper：
  - `private.can_manage_group(uid, gid)`：主账号，或者 `groups.leader_id = uid`。
  - `private.can_manage_user(uid, target)`：主账号可以管任何人；带领者只能管自己小组里的组员，且对方 `is_leader=false`、`is_admin=false`。
- Produces（对应原来的 teacher_* 函数，按小组运作）：
  - `leader_groups`、`leader_create_group(p_token, p_name)`：自动分配前缀和邀请码。
  - `leader_regen_code`、`leader_set_homework(p_token, p_group, p_pack, p_daily)`
  - `leader_overview`、`leader_day`、`leader_hw_day`、`leader_accounts`
  - `leader_add_users(p_token, p_group, p_count int default null, p_names text[] default null)`：两个参数二选一。登录名接着该前缀现有的最大编号往下生成，初始密码 6 位数字，返回 `[{username, name, password}]`。
  - `leader_rename_user`、`leader_reset_password`、`leader_remove_member`
  - `leader_user_detail`、`leader_user_days`、`leader_writings`、`leader_note_writing`
- Produces（仅主账号）：
  - `admin_users(p_token, p_q text)`
  - `admin_set_leader(p_token, p_user, p_on bool)`：取消资格时，他的小组转给主账号。
  - `admin_transfer_group(p_token, p_group, p_leader)`

- [ ] **Step 1: 写测试。** 新建两个带领者 A、B，各带一个小组；新建普通用户 U：
  - A 查看 B 小组的数据、重置 B 小组组员的密码、重置 B 本人的密码、重置 teacher 的密码，都会报 `forbidden`。
  - U 调用任何 `leader_*` 都会报 `not_leader`。
  - `leader_add_users(p_count=3)` 在前缀 km 已有 km01–km09 时，生成 km10–km12，密码是 6 位数字。
  - `admin_set_leader(A, false)` 之后，A 的小组的 `leader_id` 变成 teacher。
  - 主账号可以对所有小组做所有操作。
- [ ] **Step 2: 运行，确认失败。**
- [ ] **Step 3: 实现。**
- [ ] **Step 4: 运行，确认通过。**
- [ ] **Step 5: 提交。**

### Task 5: 生产快照上完整演练

**Files:**
- Test: `supabase/tests/rehearsal.test.mjs`

- [ ] **Step 1: 写测试。** 在全新的快照上执行整份迁移文件，再执行一次（幂等，或者第二次能明确报"已迁移"而不破坏任何数据）。然后逐项核对基线，并用 `student_login` 兼容层登录一个现有账号，确认密码仍然有效。
- [ ] **Step 2: 运行，确认通过。** 如果失败，修 Task 2 到 Task 4 的代码。
- [ ] **Step 3: 提交。**

### Task 6: 在生产库执行迁移

- [ ] **Step 1: 重新导出最新备份。** 只导出数据，覆盖 Task 1 那份，因为这期间可能有新记录。
- [ ] **Step 2: 执行迁移。** 用 Supabase `apply_migration` 执行迁移文件。核对块失败时整个事务回滚，这时停下来报告，不要重试。
- [ ] **Step 3: 用 SQL 核对。** 各表条数、星星总数、`group_members=24`、teacher 是主账号。
- [ ] **Step 4: 确认旧版网页仍可用。** 用 Playwright 打开线上旧版页面，以游客身份进入，没有报错。注册一个临时账号 `zztest01`，闯一关后确认 `progress` 里有记录。最后删掉这个账号。

### Task 7: 学生端 index.html

**Files:**
- Modify: `index.html`
- Test: `tests/e2e/user.e2e.mjs`

**Interfaces:**
- Consumes：Task 3 的函数。
- Produces：
  - 全局 `ME`（来自 `user_sync.me`）和 `GROUPS`。
  - `isAdmin()` 返回 `ME?.is_admin`。
  - `locked(i)`、作业锁、温习锁和每日摸底弹出，在 `isAdmin()` 为真时全部放行。

- [ ] **Step 1: 写 e2e 测试。** 用本地 `file://` 页面连生产库，用临时账号测试：
  - 注册页有 4 个字段，登录名和显示名各有一个 `.tip` 虚线框。
  - 注册后顶栏显示显示名，点开是"我的"页。
  - 在"我的"页改显示名后，刷新页面仍然是新名字。
  - 关掉"在总榜显示我"后，别的临时账号在总榜上看不到他。
  - 改密码后用新密码能登录。
  - 输入错误的邀请码有提示。
  - 榜单有"总榜 / 我的小组"两个板块，每个板块里有"总榜 / 今日 / 本周"。
  - 用一个临时管理员测试账号（测试结束删除）：地图第 5 关可以直接点开，地图顶部有"主账号 · 不受限制"。
- [ ] **Step 2: 运行，确认失败。**
- [ ] **Step 3: 实现。**
  - 把所有 `rpc("student_*")` 换成 `user_*`。
  - 新增 `#me` 页面，字段按设计文档第十三节。
  - 注册表单加显示名和邮箱。
  - 榜单板块切换，在多个小组时加一个下拉选择小组。
  - 首页作业卡改成逐个小组显示。
  - 新增 `.tip{border:1px dashed var(--line);border-radius:10px;padding:6px 10px;font-size:13px;color:var(--muted)}`。
- [ ] **Step 4: 运行，确认通过。** 截图看手机尺寸下的"我的"页和注册页。
- [ ] **Step 5: 提交，但先不推送。**

### Task 8: 带领者后台 leader.html

**Files:**
- Create: `leader.html`（从 `teacher.html` 改写），删除 `teacher.html`
- Test: `tests/e2e/leader.e2e.mjs`

- [ ] **Step 1: 写 e2e 测试。** 用临时带领者账号测试：
  - 用登录名和密码登录，普通用户登录时提示"你还不是带领者"。
  - 建小组后能看到邀请码，重新生成后邀请码改变。
  - 批量建账号：填 3 人，生成 3 行，每行有登录名、显示名和 6 位密码，结果页有 `.tip` 虚线框。
  - 组员列表里能改显示名、能重置密码。
  - 用主账号测试账号测试："全部用户"页能搜索，能指定或取消带领者。
- [ ] **Step 2: 运行，确认失败。**
- [ ] **Step 3: 实现。**
  - 删掉 Supabase 邮箱登录，改成调用 `user_login` 拿令牌，再调 `leader_*`。
  - 页面上的"老师 / 班级 / 学生"统一改成"带领者 / 小组 / 组员"。
  - 新增一个页签：全部用户（仅主账号可见）。
- [ ] **Step 4: 运行，确认通过。**
- [ ] **Step 5: 提交。**

### Task 9: 上线前端与线上核对

- [ ] **Step 1: 更新 README。** 改写账号、小组、带领者后台三节。
- [ ] **Step 2: 推送到 main。** 等 GitHub Pages 更新后，用 curl 确认线上已经是新代码。
- [ ] **Step 3: 线上冒烟测试。**
  - 在线上重跑 Task 7 和 Task 8 的 e2e 测试。
  - 用 SQL 抽查 3 个真实用户（星星最多的 3 人）：`user_sync` 返回的进度条数等于他们 `progress` 里的条数。
- [ ] **Step 4: 清理测试数据。** 删除所有 `zz` 开头的临时账号和临时小组。确认各表条数回到"基线 + 上线期间真实用户新增的记录"。

### Task 10: 清理旧名字（执行前给主账号看核对结果）

**Files:**
- Create: `supabase/migrations_2026-11-29_cleanup.sql`

- [ ] **Step 1: 写测试。** 在快照上跑完两份迁移后，以下这些都不存在：
  - 所有 `student_*`、`teacher_*` 函数
  - `teacher_homework_v2`
  - `private.teacher_keys`
  - `groups.teacher_id`、`groups.is_open`、`groups.hide_rank`
  - `users.class_id`

  同时各表条数不变。
- [ ] **Step 2: 运行，确认失败，然后实现，再确认通过。**
- [ ] **Step 3: 给主账号确认。** 把核对结果发给主账号，得到确认后，在生产库执行清理，再核对一次条数。
- [ ] **Step 4: 提交并推送，更新 README。**
