-- 心版 · Supabase 数据库（账号版）
--
-- 账号设计
--   老师：Supabase Auth 邮箱 + 密码，在 teacher.html 注册登录。
--   学生：老师在后台批量生成“账号 + 6 位数字密码”，不需要邮箱。
--         学生登录后拿到一个登录凭证（token），之后所有读写都通过下面的函数完成。
--   游客：不登录，只存在本机浏览器，不进数据库。
--
-- 数据量很小：
--   闯关进度：每人每关 1 行
--   使用时长：每人每天 1 行（秒数）
--   测验成绩：每考一次 1 行
--
-- 所有表都开了 RLS。学生相关的表没有任何直接访问策略，只能经由 security definer 函数读写；
-- 老师只能看到自己建的班级。

create schema if not exists private;

-- ========== 表 ==========

create table public.classes (
  id          bigint generated always as identity primary key,
  teacher_id  uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 40),
  prefix      text not null unique check (prefix ~ '^[a-z]{2}$'),   -- 学生账号前缀，例如 km → km01、km02
  created_at  timestamptz not null default now()
);
create index classes_teacher_id_idx on public.classes (teacher_id);

create table public.students (
  id            bigint generated always as identity primary key,
  class_id      bigint not null references public.classes (id) on delete cascade,
  name          text not null check (char_length(name) between 1 and 20),
  username      text not null unique check (username ~ '^[a-z]{2}[0-9]{2,3}$'),
  pw_hash       text not null,
  fail_count    smallint not null default 0,
  locked_until  timestamptz,
  last_seen     timestamptz,
  created_at    timestamptz not null default now()
);
create index students_class_id_idx on public.students (class_id);

create table private.sessions (
  token_hash  bytea primary key,
  student_id  bigint not null references public.students (id) on delete cascade,
  expires_at  timestamptz not null default now() + interval '120 days'
);
create index sessions_student_id_idx on private.sessions (student_id);

create table public.progress (
  student_id  bigint not null references public.students (id) on delete cascade,
  unit_key    text not null check (char_length(unit_key) <= 60),
  stars       smallint not null default 0 check (stars between 0 and 3),
  adv         smallint not null default 0 check (adv between 0 and 3),
  updated_at  timestamptz not null default now(),
  primary key (student_id, unit_key)
);

create table public.usage_daily (
  student_id  bigint not null references public.students (id) on delete cascade,
  day         date not null,
  seconds     integer not null default 0 check (seconds between 0 and 86400),
  primary key (student_id, day)
);

create table public.tests (
  id          bigint generated always as identity primary key,
  student_id  bigint not null references public.students (id) on delete cascade,
  score       integer not null check (score between 0 and 100000),
  correct     smallint not null default 0,
  wrong       smallint not null default 0,
  best_combo  smallint not null default 0,
  pack        text check (char_length(pack) <= 40),
  created_at  timestamptz not null default now()
);
create index tests_student_id_created_idx on public.tests (student_id, created_at desc);

alter table public.classes     enable row level security;
alter table public.students    enable row level security;
alter table public.progress    enable row level security;
alter table public.usage_daily enable row level security;
alter table public.tests       enable row level security;
alter table private.sessions   enable row level security;

-- 老师可以直接查看、改名、删除自己的班级；其他表只经由函数访问
create policy classes_owner on public.classes
  for all to authenticated
  using (teacher_id = (select auth.uid()))
  with check (teacher_id = (select auth.uid()));

-- ========== 内部辅助 ==========

-- 计时以雅加达时间划分“每天”
create or replace function private.today() returns date
language sql stable set search_path = '' as $$ select (now() at time zone 'Asia/Jakarta')::date $$;

-- 用登录凭证换出学生 id；凭证无效或过期则报错
create or replace function private.student_of(p_token text) returns bigint
language plpgsql stable security definer set search_path = '' as $$
declare v bigint;
begin
  select s.student_id into v from private.sessions s
  where s.token_hash = extensions.digest(p_token, 'sha256') and s.expires_at > now();
  if v is null then raise exception 'SESSION_EXPIRED'; end if;
  return v;
end $$;

-- 当前老师是否拥有这个班
create or replace function private.owns_class(p_class bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.classes where id = p_class and teacher_id = (select auth.uid()))
$$;

create or replace function private.random_digits(n int) returns text
language sql volatile set search_path = '' as $$
  select string_agg((floor(random() * 10))::int::text, '') from generate_series(1, n)
$$;

-- ========== 学生端函数（游戏页面调用，anon 可调） ==========

create or replace function public.student_login(p_username text, p_password text)
returns json
language plpgsql security definer set search_path = '' as $$
declare st public.students; tok text;
begin
  select * into st from public.students where username = lower(trim(p_username));
  if st.id is null then raise exception 'BAD_LOGIN'; end if;
  if st.locked_until is not null and st.locked_until > now() then raise exception 'LOCKED'; end if;
  if st.pw_hash <> extensions.crypt(trim(p_password), st.pw_hash) then
    update public.students
      set fail_count = fail_count + 1,
          locked_until = case when fail_count + 1 >= 8 then now() + interval '10 minutes' else locked_until end
      where id = st.id;
    raise exception 'BAD_LOGIN';
  end if;
  update public.students set fail_count = 0, locked_until = null, last_seen = now() where id = st.id;
  tok := encode(extensions.gen_random_bytes(24), 'hex');
  insert into private.sessions (token_hash, student_id) values (extensions.digest(tok, 'sha256'), st.id);
  delete from private.sessions where student_id = st.id and expires_at < now();
  return json_build_object('token', tok, 'name', st.name, 'username', st.username,
    'class', (select name from public.classes where id = st.class_id));
end $$;

create or replace function public.student_logout(p_token text) returns void
language sql security definer set search_path = '' as $$
  delete from private.sessions where token_hash = extensions.digest(p_token, 'sha256')
$$;

-- 登录后拉取自己的进度、测验最高分
create or replace function public.student_sync(p_token text) returns json
language plpgsql security definer set search_path = '' as $$
declare sid bigint := private.student_of(p_token);
begin
  update public.students set last_seen = now() where id = sid;
  return json_build_object(
    'name', (select name from public.students where id = sid),
    'progress', coalesce((select json_object_agg(unit_key, json_build_array(stars, adv)) from public.progress where student_id = sid), '{}'::json),
    'best', coalesce((select max(score) from public.tests where student_id = sid), 0));
end $$;

-- 批量保存闯关进度：p_items = [{"k":"约 3:16","s":3,"a":0}, ...]；只会往高处更新
create or replace function public.student_save_progress(p_token text, p_items jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare sid bigint := private.student_of(p_token);
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then raise exception 'BAD_INPUT'; end if;
  insert into public.progress as p (student_id, unit_key, stars, adv)
  select sid, left(x->>'k', 60), least(greatest(coalesce((x->>'s')::int, 0), 0), 3), least(greatest(coalesce((x->>'a')::int, 0), 0), 3)
  from jsonb_array_elements(p_items) x
  where coalesce(x->>'k', '') <> ''
  on conflict (student_id, unit_key) do update
    set stars = greatest(p.stars, excluded.stars), adv = greatest(p.adv, excluded.adv), updated_at = now();
end $$;

create or replace function public.student_save_test(p_token text, p_score int, p_correct int, p_wrong int, p_combo int, p_pack text)
returns void
language plpgsql security definer set search_path = '' as $$
declare sid bigint := private.student_of(p_token);
begin
  insert into public.tests (student_id, score, correct, wrong, best_combo, pack)
  values (sid, least(greatest(p_score, 0), 100000), least(greatest(p_correct, 0), 999), least(greatest(p_wrong, 0), 999),
          least(greatest(p_combo, 0), 999), left(p_pack, 40));
end $$;

-- 使用时长：页面在前台、学生在操作时，每分钟上报一次秒数
create or replace function public.student_heartbeat(p_token text, p_seconds int) returns void
language plpgsql security definer set search_path = '' as $$
declare sid bigint := private.student_of(p_token); sec int := least(greatest(coalesce(p_seconds, 0), 0), 120);
begin
  insert into public.usage_daily as u (student_id, day, seconds) values (sid, private.today(), sec)
  on conflict (student_id, day) do update set seconds = least(u.seconds + excluded.seconds, 86400);
  update public.students set last_seen = now() where id = sid;
end $$;

-- ========== 老师端函数（teacher.html 调用，需老师登录） ==========

create or replace function public.teacher_create_class(p_name text) returns public.classes
language plpgsql security definer set search_path = '' as $$
declare pre text; c public.classes; letters text := 'abcdefghjkmnpqrstuvwxyz';
begin
  if (select auth.uid()) is null then raise exception 'NOT_TEACHER'; end if;
  loop
    pre := substr(letters, 1 + floor(random() * 23)::int, 1) || substr(letters, 1 + floor(random() * 23)::int, 1);
    exit when not exists (select 1 from public.classes where prefix = pre);
  end loop;
  insert into public.classes (teacher_id, name, prefix) values ((select auth.uid()), trim(p_name), pre) returning * into c;
  return c;
end $$;

-- 批量生成学生账号：返回明文密码，仅此一次显示
create or replace function public.teacher_add_students(p_class bigint, p_names text[])
returns table (name text, username text, password text)
language plpgsql security definer set search_path = '' as $$
declare pre text; n int; nm text; pw text; un text;
begin
  if not private.owns_class(p_class) then raise exception 'NOT_YOUR_CLASS'; end if;
  select prefix into pre from public.classes where id = p_class;
  select coalesce(max(substr(s.username, 3)::int), 0) into n from public.students s where s.class_id = p_class;
  foreach nm in array p_names loop
    nm := trim(nm);
    continue when nm = '';
    n := n + 1;
    un := pre || lpad(n::text, 2, '0');
    pw := private.random_digits(6);
    insert into public.students (class_id, name, username, pw_hash)
    values (p_class, left(nm, 20), un, extensions.crypt(pw, extensions.gen_salt('bf', 8)));
    name := left(nm, 20); username := un; password := pw;
    return next;
  end loop;
end $$;

create or replace function public.teacher_reset_password(p_student bigint) returns text
language plpgsql security definer set search_path = '' as $$
declare pw text := private.random_digits(6);
begin
  if not exists (select 1 from public.students s where s.id = p_student and private.owns_class(s.class_id)) then raise exception 'NOT_YOUR_CLASS'; end if;
  update public.students set pw_hash = extensions.crypt(pw, extensions.gen_salt('bf', 8)), fail_count = 0, locked_until = null where id = p_student;
  delete from private.sessions where student_id = p_student;
  return pw;
end $$;

create or replace function public.teacher_rename_student(p_student bigint, p_name text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.students s where s.id = p_student and private.owns_class(s.class_id)) then raise exception 'NOT_YOUR_CLASS'; end if;
  update public.students set name = left(trim(p_name), 20) where id = p_student;
end $$;

create or replace function public.teacher_delete_student(p_student bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.students s where s.id = p_student and private.owns_class(s.class_id)) then raise exception 'NOT_YOUR_CLASS'; end if;
  delete from public.students where id = p_student;
end $$;

-- 全班一览：一行一个学生
create or replace function public.teacher_overview(p_class bigint)
returns table (id bigint, name text, username text, today_sec int, week_sec int, total_sec int,
               passed int, stars int, adv int, tests int, best_score int, last_score int, last_seen timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.owns_class(p_class) then raise exception 'NOT_YOUR_CLASS'; end if;
  return query
  select s.id, s.name, s.username,
    coalesce((select u.seconds from public.usage_daily u where u.student_id = s.id and u.day = private.today()), 0),
    coalesce((select sum(u.seconds)::int from public.usage_daily u where u.student_id = s.id and u.day > private.today() - 7), 0),
    coalesce((select sum(u.seconds)::int from public.usage_daily u where u.student_id = s.id), 0),
    (select count(*)::int from public.progress p where p.student_id = s.id and p.stars > 0
       and (p.unit_key like '%#%' or not exists (select 1 from public.progress q where q.student_id = s.id and q.unit_key like p.unit_key || '#%'))),
    coalesce((select sum(p.stars)::int from public.progress p where p.student_id = s.id and p.unit_key not like '%#%'), 0),
    (select count(*)::int from public.progress p where p.student_id = s.id and p.adv > 0),
    (select count(*)::int from public.tests t where t.student_id = s.id),
    coalesce((select max(t.score) from public.tests t where t.student_id = s.id), 0),
    coalesce((select t.score from public.tests t where t.student_id = s.id order by t.created_at desc limit 1), 0),
    s.last_seen
  from public.students s
  where s.class_id = p_class
  order by s.username;
end $$;

-- 单个学生的明细：近 30 天时长、近 30 次测验、全部关卡
create or replace function public.teacher_student_detail(p_student bigint) returns json
language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.students s where s.id = p_student and private.owns_class(s.class_id)) then raise exception 'NOT_YOUR_CLASS'; end if;
  return json_build_object(
    'today', private.today(),
    'usage', coalesce((select json_agg(json_build_object('d', u.day, 's', u.seconds) order by u.day)
                       from public.usage_daily u where u.student_id = p_student and u.day > private.today() - 30), '[]'::json),
    'tests', coalesce((select json_agg(json_build_object('t', x.created_at, 's', x.score, 'c', x.correct, 'w', x.wrong, 'p', x.pack) order by x.created_at)
                       from (select * from public.tests t where t.student_id = p_student order by t.created_at desc limit 30) x), '[]'::json),
    'progress', coalesce((select json_agg(json_build_object('k', p.unit_key, 's', p.stars, 'a', p.adv, 't', p.updated_at))
                          from public.progress p where p.student_id = p_student), '[]'::json));
end $$;

-- ========== 权限 ==========

-- private 里的辅助函数只供上面的 security definer 函数内部调用，不对外开放
revoke all on all functions in schema private from public, anon, authenticated;

revoke all on function public.student_login(text, text), public.student_logout(text), public.student_sync(text),
  public.student_save_progress(text, jsonb), public.student_save_test(text, int, int, int, int, text), public.student_heartbeat(text, int)
  from public;
grant execute on function public.student_login(text, text), public.student_logout(text), public.student_sync(text),
  public.student_save_progress(text, jsonb), public.student_save_test(text, int, int, int, int, text), public.student_heartbeat(text, int)
  to anon, authenticated;

revoke all on function public.teacher_create_class(text), public.teacher_add_students(bigint, text[]), public.teacher_reset_password(bigint),
  public.teacher_rename_student(bigint, text), public.teacher_delete_student(bigint), public.teacher_overview(bigint), public.teacher_student_detail(bigint)
  from public, anon;
grant execute on function public.teacher_create_class(text), public.teacher_add_students(bigint, text[]), public.teacher_reset_password(bigint),
  public.teacher_rename_student(bigint, text), public.teacher_delete_student(bigint), public.teacher_overview(bigint), public.teacher_student_detail(bigint)
  to authenticated;

-- ========== 2026-11-06：老师可以随时查看学生密码 ==========
-- 学生密码是老师生成的 6 位数字，老师需要随时能查到，所以另存一份明文 pw_view。
-- 这一列只能经由老师函数 teacher_accounts 读取，学生端和其他老师都读不到。
alter table public.students add column if not exists pw_view text;

create or replace function public.teacher_add_students(p_class bigint, p_names text[])
returns table (name text, username text, password text)
language plpgsql security definer set search_path = '' as $$
declare pre text; n int; nm text; pw text; un text;
begin
  if not private.owns_class(p_class) then raise exception 'NOT_YOUR_CLASS'; end if;
  select prefix into pre from public.classes where id = p_class;
  select coalesce(max(substr(s.username, 3)::int), 0) into n from public.students s where s.class_id = p_class;
  foreach nm in array p_names loop
    nm := trim(nm);
    continue when nm = '';
    n := n + 1;
    un := pre || lpad(n::text, 2, '0');
    pw := private.random_digits(6);
    insert into public.students (class_id, name, username, pw_hash, pw_view)
    values (p_class, left(nm, 20), un, extensions.crypt(pw, extensions.gen_salt('bf', 8)), pw);
    name := left(nm, 20); username := un; password := pw;
    return next;
  end loop;
end $$;

create or replace function public.teacher_reset_password(p_student bigint) returns text
language plpgsql security definer set search_path = '' as $$
declare pw text := private.random_digits(6);
begin
  if not exists (select 1 from public.students s where s.id = p_student and private.owns_class(s.class_id)) then raise exception 'NOT_YOUR_CLASS'; end if;
  update public.students set pw_hash = extensions.crypt(pw, extensions.gen_salt('bf', 8)), pw_view = pw, fail_count = 0, locked_until = null where id = p_student;
  delete from private.sessions where student_id = p_student;
  return pw;
end $$;

create or replace function public.teacher_accounts(p_class bigint)
returns table (id bigint, name text, username text, password text, last_seen timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.owns_class(p_class) then raise exception 'NOT_YOUR_CLASS'; end if;
  return query select s.id, s.name, s.username, coalesce(s.pw_view, ''), s.last_seen
    from public.students s where s.class_id = p_class order by s.username;
end $$;

revoke all on function public.teacher_accounts(bigint) from public, anon;
grant execute on function public.teacher_accounts(bigint) to authenticated;
-- ========== 2026-11-06（二）：老师专属链接免登录；账号可用 班级+名字 ==========
-- 学生账号可以是 g7samuel 这类形式（字母数字，2–24 位）
alter table public.students drop constraint if exists students_username_check;
alter table public.students add constraint students_username_check check (username ~ '^[a-z0-9]{2,24}$');

-- 老师专属链接：链接里带一把长钥匙，数据库只存它的哈希
create table if not exists private.teacher_keys (
  key_hash   bytea primary key,
  teacher_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

-- 当前老师：已登录用登录身份；否则看请求头 x-teacher-key
create or replace function private.me() returns uuid
language sql stable security definer set search_path = '' as $$
  select coalesce((select auth.uid()),
    (select k.teacher_id from private.teacher_keys k
      where k.key_hash = extensions.digest(nullif(nullif(current_setting('request.headers', true), '')::json ->> 'x-teacher-key', ''), 'sha256')))
$$;

create or replace function private.owns_class(p_class bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.classes where id = p_class and teacher_id = private.me())
$$;

create or replace function public.teacher_classes()
returns table (id bigint, name text, prefix text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select c.id, c.name, c.prefix, c.created_at from public.classes c where c.teacher_id = private.me() order by c.name
$$;

create or replace function public.teacher_create_class(p_name text) returns public.classes
language plpgsql security definer set search_path = '' as $$
declare pre text; c public.classes; letters text := 'abcdefghjkmnpqrstuvwxyz'; t uuid := private.me();
begin
  if t is null then raise exception 'NOT_TEACHER'; end if;
  loop
    pre := substr(letters, 1 + floor(random() * 23)::int, 1) || substr(letters, 1 + floor(random() * 23)::int, 1);
    exit when not exists (select 1 from public.classes where prefix = pre);
  end loop;
  insert into public.classes (teacher_id, name, prefix) values (t, trim(p_name), pre) returning * into c;
  return c;
end $$;

-- 编号只看 前缀+数字 形式的账号，避免和 g7samuel 这类账号冲突
create or replace function public.teacher_add_students(p_class bigint, p_names text[])
returns table (name text, username text, password text)
language plpgsql security definer set search_path = '' as $$
declare pre text; n int; nm text; pw text; un text;
begin
  if not private.owns_class(p_class) then raise exception 'NOT_YOUR_CLASS'; end if;
  select prefix into pre from public.classes where id = p_class;
  select coalesce(max(substr(s.username, 3)::int), 0) into n from public.students s
    where s.class_id = p_class and s.username ~ ('^' || pre || '[0-9]{2,3}$');
  foreach nm in array p_names loop
    nm := trim(nm);
    continue when nm = '';
    n := n + 1;
    un := pre || lpad(n::text, 2, '0');
    pw := private.random_digits(4);
    insert into public.students (class_id, name, username, pw_hash, pw_view)
    values (p_class, left(nm, 20), un, extensions.crypt(pw, extensions.gen_salt('bf', 8)), pw);
    name := left(nm, 20); username := un; password := pw;
    return next;
  end loop;
end $$;

create or replace function public.teacher_reset_password(p_student bigint) returns text
language plpgsql security definer set search_path = '' as $$
declare pw text := private.random_digits(4);
begin
  if not exists (select 1 from public.students s where s.id = p_student and private.owns_class(s.class_id)) then raise exception 'NOT_YOUR_CLASS'; end if;
  update public.students set pw_hash = extensions.crypt(pw, extensions.gen_salt('bf', 8)), pw_view = pw, fail_count = 0, locked_until = null where id = p_student;
  delete from private.sessions where student_id = p_student;
  return pw;
end $$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke all on function public.teacher_classes() from public;
grant execute on function public.teacher_classes(), public.teacher_create_class(text), public.teacher_add_students(bigint, text[]),
  public.teacher_reset_password(bigint), public.teacher_rename_student(bigint, text), public.teacher_delete_student(bigint),
  public.teacher_overview(bigint), public.teacher_student_detail(bigint), public.teacher_accounts(bigint)
  to anon, authenticated;
