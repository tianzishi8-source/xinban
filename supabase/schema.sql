-- 心版 · Supabase 数据库结构
-- 在 Supabase 控制台的 SQL Editor 里整段执行一次即可。
--
-- 账号设计：
--   老师：邮箱登录（Supabase Auth 的 Email 登录）。
--   学生：匿名登录（Supabase Auth → Anonymous Sign-ins，需在控制台开启），
--         再调用 join_class(班级码, 昵称) 加入班级。学生不需要邮箱。

create schema if not exists private;

-- ========== 表 ==========

-- 班级：老师创建，学生凭班级码加入
create table public.classes (
  id          bigint generated always as identity primary key,
  code        text not null unique check (code ~ '^[A-Z0-9]{4,8}$'),
  name        text not null check (char_length(name) between 1 and 40),
  teacher_id  uuid not null references auth.users (id) on delete cascade,
  created_at  timestamptz not null default now()
);
create index classes_teacher_id_idx on public.classes (teacher_id);

-- 学生：id 就是该学生（匿名）登录后的 auth.uid()
create table public.students (
  id          uuid primary key references auth.users (id) on delete cascade,
  class_id    bigint not null references public.classes (id) on delete cascade,
  nickname    text not null check (char_length(nickname) between 1 and 12),
  created_at  timestamptz not null default now(),
  unique (class_id, nickname)
);
create index students_class_id_idx on public.students (class_id);

-- 闯关进度：一关一行。unit_key 与页面里 UNITS[i].key 完全一致，
-- 例如 "约 3:16"，长段落分段时是 "约 1:1-18#2"。
create table public.progress (
  student_id  uuid not null references public.students (id) on delete cascade,
  unit_key    text not null,
  stars       smallint not null default 0 check (stars between 0 and 3),      -- 普通训练最好成绩
  adv_stars   smallint not null default 0 check (adv_stars between 0 and 3),  -- 高阶（默写）最好成绩
  updated_at  timestamptz not null default now(),
  primary key (student_id, unit_key)
);

-- 60 秒测试：每考一次一行
create table public.test_scores (
  id          bigint generated always as identity primary key,
  student_id  uuid not null references public.students (id) on delete cascade,
  pack        text not null,                    -- 当时的经文包，例如 "约翰福音"
  score       integer not null check (score >= 0),
  correct     integer not null default 0 check (correct >= 0),
  wrong       integer not null default 0 check (wrong >= 0),
  best_combo  integer not null default 0 check (best_combo >= 0),
  created_at  timestamptz not null default now()
);
create index test_scores_student_id_idx on public.test_scores (student_id);

-- 多人对战房间：老师（主持端）开房，学生用手机加入。
-- 答题过程走 Supabase Realtime 的广播频道 duel:<code>，不逐题写库；
-- 只在开房、加入、结束时写这两张表。
create table public.duel_rooms (
  id          bigint generated always as identity primary key,
  class_id    bigint not null references public.classes (id) on delete cascade,
  code        text not null unique check (code ~ '^[0-9]{4,6}$'),
  host_id     uuid not null references auth.users (id) on delete cascade,
  pack        text not null,
  status      text not null default 'waiting' check (status in ('waiting', 'playing', 'finished')),
  score_a     integer not null default 0,
  score_b     integer not null default 0,
  created_at  timestamptz not null default now()
);
create index duel_rooms_class_id_idx on public.duel_rooms (class_id);
create index duel_rooms_host_id_idx on public.duel_rooms (host_id);

create table public.duel_players (
  room_id     bigint not null references public.duel_rooms (id) on delete cascade,
  student_id  uuid not null references public.students (id) on delete cascade,
  team        text not null check (team in ('a', 'b')),
  joined_at   timestamptz not null default now(),
  primary key (room_id, student_id)
);
create index duel_players_student_id_idx on public.duel_players (student_id);

-- ========== 辅助函数（放在不对外暴露的 private schema） ==========

-- 当前登录学生所在班级
create or replace function private.my_class_id()
returns bigint
language sql stable security definer
set search_path = ''
as $$
  select class_id from public.students where id = (select auth.uid());
$$;

-- 当前登录用户是否是该班级的老师
create or replace function private.is_teacher_of(p_class_id bigint)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.classes
    where id = p_class_id and teacher_id = (select auth.uid())
  );
$$;

-- 某个学生所在班级（老师查看学生数据时用）
create or replace function private.class_of(p_student_id uuid)
returns bigint
language sql stable security definer
set search_path = ''
as $$
  select class_id from public.students where id = p_student_id;
$$;

revoke all on function private.my_class_id() from public, anon;
revoke all on function private.is_teacher_of(bigint) from public, anon;
revoke all on function private.class_of(uuid) from public, anon;
grant usage on schema private to authenticated;
grant execute on function private.my_class_id() to authenticated;
grant execute on function private.is_teacher_of(bigint) to authenticated;
grant execute on function private.class_of(uuid) to authenticated;

-- ========== 对外的 RPC ==========

-- 学生加入班级：匿名登录后调用 supabase.rpc('join_class', { p_code, p_nickname })
-- 已加入过则只更新昵称；同班昵称重复会报错，页面提示换一个名字。
create or replace function public.join_class(p_code text, p_nickname text)
returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_class bigint;
begin
  if v_uid is null then
    raise exception '请先登录';
  end if;
  select id into v_class from public.classes where code = upper(trim(p_code));
  if v_class is null then
    raise exception '班级码不存在';
  end if;
  insert into public.students (id, class_id, nickname)
  values (v_uid, v_class, trim(p_nickname))
  on conflict (id) do update set class_id = excluded.class_id, nickname = excluded.nickname;
  return v_class;
end;
$$;
revoke all on function public.join_class(text, text) from public, anon;
grant execute on function public.join_class(text, text) to authenticated;

-- 班级榜：同班同学的测试最高分和已过关数
create or replace function public.class_leaderboard()
returns table (nickname text, best_score integer, passed integer, is_me boolean)
language sql stable security definer
set search_path = ''
as $$
  select s.nickname,
         coalesce((select max(t.score) from public.test_scores t where t.student_id = s.id), 0) as best_score,
         (select count(*)::int from public.progress p where p.student_id = s.id and p.stars > 0) as passed,
         s.id = (select auth.uid()) as is_me
  from public.students s
  where s.class_id = (select private.my_class_id())
  order by best_score desc, passed desc;
$$;
revoke all on function public.class_leaderboard() from public, anon;
grant execute on function public.class_leaderboard() to authenticated;

-- ========== 行级安全（RLS） ==========

alter table public.classes      enable row level security;
alter table public.students     enable row level security;
alter table public.progress     enable row level security;
alter table public.test_scores  enable row level security;
alter table public.duel_rooms   enable row level security;
alter table public.duel_players enable row level security;

-- 班级：老师管理自己的班；学生能看到自己所在的班
create policy classes_teacher_all on public.classes
  for all to authenticated
  using (teacher_id = (select auth.uid()))
  with check (teacher_id = (select auth.uid()));
create policy classes_member_read on public.classes
  for select to authenticated
  using (id = (select private.my_class_id()));

-- 学生：看自己和同班同学；改自己的昵称；老师看本班学生
create policy students_read on public.students
  for select to authenticated
  using (
    class_id = (select private.my_class_id())
    or (select private.is_teacher_of(class_id))
  );
create policy students_update_self on public.students
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- 闯关进度：学生读写自己的；老师读本班的
create policy progress_self_all on public.progress
  for all to authenticated
  using (student_id = (select auth.uid()))
  with check (student_id = (select auth.uid()));
create policy progress_teacher_read on public.progress
  for select to authenticated
  using ((select private.is_teacher_of(private.class_of(student_id))));

-- 测试成绩：学生写入并读取自己的；老师读本班的
create policy test_scores_self_insert on public.test_scores
  for insert to authenticated
  with check (student_id = (select auth.uid()));
create policy test_scores_self_read on public.test_scores
  for select to authenticated
  using (student_id = (select auth.uid()));
create policy test_scores_teacher_read on public.test_scores
  for select to authenticated
  using ((select private.is_teacher_of(private.class_of(student_id))));

-- 对战房间：老师在自己的班开房、改比分；本班学生能看到房间
create policy duel_rooms_host_all on public.duel_rooms
  for all to authenticated
  using (host_id = (select auth.uid()))
  with check (host_id = (select auth.uid()) and (select private.is_teacher_of(class_id)));
create policy duel_rooms_member_read on public.duel_rooms
  for select to authenticated
  using (class_id = (select private.my_class_id()));

-- 对战队员：学生把自己加入本班的房间；房主和本班学生能看到名单
create policy duel_players_self_insert on public.duel_players
  for insert to authenticated
  with check (
    student_id = (select auth.uid())
    and exists (
      select 1 from public.duel_rooms r
      where r.id = room_id and r.class_id = (select private.my_class_id()) and r.status = 'waiting'
    )
  );
create policy duel_players_read on public.duel_players
  for select to authenticated
  using (
    exists (
      select 1 from public.duel_rooms r
      where r.id = room_id
        and (r.host_id = (select auth.uid()) or r.class_id = (select private.my_class_id()))
    )
  );
