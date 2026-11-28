-- 2026-11-28 统一账号、小组与主账号
-- 设计：docs/superpowers/specs/2026-11-28-accounts-groups-design.md
--
-- 原则：数据一行都不复制，表和列原地改名；末尾核对条数与每人星星，对不上就整体回滚。
-- 整个文件必须在一个事务里执行（Supabase apply_migration 会这样做）。

-- ========== 0. 防止重复执行；记下迁移前的数 ==========
do $$ begin
  if to_regclass('public.users') is not null then raise exception 'ALREADY_MIGRATED'; end if;
  if (select count(*) from public.students where username = 'teacher') <> 1 then raise exception 'NO_ADMIN_ACCOUNT'; end if;
end $$;

create temp table _mig_count on commit drop as
  select 'users' t, count(*) n from public.students
  union all select 'sessions', count(*) from private.sessions
  union all select 'progress', count(*) from public.progress
  union all select 'plays', count(*) from public.plays
  union all select 'tests', count(*) from public.tests
  union all select 'usage_daily', count(*) from public.usage_daily
  union all select 'reviews', count(*) from public.reviews
  union all select 'review_days', count(*) from public.review_days
  union all select 'hw_days', count(*) from public.hw_days
  union all select 'writings', count(*) from public.writings;
create temp table _mig_stars on commit drop as
  select student_id uid, sum(stars + adv) s, count(*) c from public.progress group by 1;

-- ========== 1. 旧函数全部移除（学生端稍后以转接形式重建） ==========
do $$ declare f record; begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where (n.nspname = 'public' and (p.proname like 'student\_%' or p.proname like 'teacher\_%' or p.proname in ('leaderboard', 'leaderboard_packs')))
              or (n.nspname = 'private' and p.proname in ('me', 'owns_class', 'student_of'))
  loop execute 'drop function ' || f.sig; end loop;
end $$;
drop policy if exists classes_owner on public.classes;

-- ========== 2. 表、列原地改名 ==========
alter table public.students rename to users;
alter table public.classes rename to groups;
alter table private.sessions rename column student_id to user_id;
alter table public.progress rename column student_id to user_id;
alter table public.plays rename column student_id to user_id;
alter table public.tests rename column student_id to user_id;
alter table public.usage_daily rename column student_id to user_id;
alter table public.reviews rename column student_id to user_id;
alter table public.review_days rename column student_id to user_id;
alter table public.hw_days rename column student_id to user_id;
alter table public.writings rename column student_id to user_id;

-- ========== 3. 新字段、新表 ==========
alter table public.users drop constraint if exists students_username_check;
alter table public.users add constraint users_username_check check (username ~ '^[a-z0-9]{2,24}$');
alter table public.users
  add column email text check (email is null or (char_length(email) <= 120 and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')),
  add column show_on_board boolean not null default true,
  add column is_leader boolean not null default false,
  add column is_admin boolean not null default false;
create unique index users_email_key on public.users (lower(email)) where email is not null;
create unique index users_one_admin on public.users (is_admin) where is_admin;

alter table public.groups
  add column leader_id bigint references public.users (id) on delete set null,
  add column invite_code text unique check (invite_code ~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$');
create index groups_leader_id_idx on public.groups (leader_id);

create table public.group_members (
  group_id  bigint not null references public.groups (id) on delete cascade,
  user_id   bigint not null references public.users (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index group_members_user_id_idx on public.group_members (user_id);
alter table public.group_members enable row level security;

-- 作业记录：一人一天每个经文包一条（一个人可能在几个小组都有作业）。迁移时此表为空。
alter table public.hw_days drop constraint hw_days_pkey;
update public.hw_days set pack = '' where pack is null;
alter table public.hw_days alter column pack set not null, alter column pack set default '';
alter table public.hw_days add primary key (user_id, day, pack);

create table private.leader_keys (
  key_hash   bytea primary key,
  user_id    bigint not null references public.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

-- ========== 4. 回填 ==========
create or replace function private.new_invite_code() returns text
language plpgsql volatile set search_path = '' as $$
declare cs text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text;
begin
  loop
    select string_agg(substr(cs, 1 + floor(random() * 32)::int, 1), '') into c from generate_series(1, 6);
    exit when not exists (select 1 from public.groups where invite_code = c);
  end loop;
  return c;
end $$;

do $$ declare adm bigint;
begin
  select id into adm from public.users where username = 'teacher';
  update public.users set is_admin = true where id = adm;
  -- 原“老师自己”这类不上榜的班：里面的人默认不在总榜显示
  update public.users u set show_on_board = false from public.groups g where g.id = u.class_id and g.hide_rank;
  -- 普通班 → 小组，带领者是主账号
  update public.groups set leader_id = adm, invite_code = private.new_invite_code() where not is_open and not hide_rank;
  insert into public.group_members (group_id, user_id, joined_at)
    select u.class_id, u.id, u.created_at from public.users u join public.groups g on g.id = u.class_id where g.leader_id is not null;
  -- 原来的老师钥匙 → 主账号的带领者钥匙
  insert into private.leader_keys (key_hash, user_id, created_at) select key_hash, adm, created_at from private.teacher_keys;
  -- 开放班、隐藏班删除（先断开成员，防止级联删除用户）
  alter table public.users alter column class_id drop not null;
  update public.users set class_id = null;
  delete from public.groups where is_open or hide_rank;
end $$;

drop table private.teacher_keys;
alter table public.users drop column class_id;
alter table public.groups drop column teacher_id, drop column is_open, drop column hide_rank;

-- 约束、索引、序列名里的旧叫法一并改掉
do $$ declare r record; nn text;
begin
  for r in select c.conname, c.conrelid::regclass tbl from pg_constraint c join pg_namespace n on n.oid = c.connamespace
           where n.nspname in ('public', 'private') and (c.conname ~ 'student|class') loop
    nn := replace(replace(replace(replace(r.conname, 'students', 'users'), 'student', 'user'), 'classes', 'groups'), 'class', 'group');
    execute format('alter table %s rename constraint %I to %I', r.tbl, r.conname, nn);
  end loop;
  for r in select i.relname, n.nspname from pg_class i join pg_namespace n on n.oid = i.relnamespace
           where i.relkind in ('i', 'S') and n.nspname in ('public', 'private') and i.relname ~ 'student|class' loop
    nn := replace(replace(replace(replace(r.relname, 'students', 'users'), 'student', 'user'), 'classes', 'groups'), 'class', 'group');
    execute format('alter %s %I.%I rename to %I', case when exists (select 1 from pg_class where relname = r.relname and relkind = 'S') then 'sequence' else 'index' end, r.nspname, r.relname, nn);
  end loop;
end $$;

-- ========== 5. 内部辅助函数 ==========
create or replace function private.user_of(p_token text) returns bigint
language plpgsql stable security definer set search_path = '' as $$
declare v bigint;
begin
  select s.user_id into v from private.sessions s
  where s.token_hash = extensions.digest(p_token, 'sha256') and s.expires_at > now();
  if v is null then raise exception 'SESSION_EXPIRED'; end if;
  return v;
end $$;

create or replace function private.clear_review_on_play() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.reviews set cleared_at = now()
  where user_id = new.user_id and unit_key = new.unit_key and cleared_at is null and created_at <= new.at;
  return new;
end $$;

create or replace function private.me_json(p_uid bigint) returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object('id', id, 'username', username, 'name', name, 'email', email, 'show_on_board', show_on_board,
    'is_leader', is_leader, 'is_admin', is_admin, 'pw_is_initial', pw_view is not null)
  from public.users where id = p_uid
$$;

create or replace function private.new_session(p_uid bigint) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare tok text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  insert into private.sessions (token_hash, user_id) values (extensions.digest(tok, 'sha256'), p_uid);
  delete from private.sessions where user_id = p_uid and expires_at < now();
  return tok;
end $$;

-- ========== 6. 用户端函数（index.html 调用；anon 可调） ==========
-- 错误码：BAD_LOGIN LOCKED BAD_NAME BAD_USERNAME USERNAME_TAKEN BAD_PASSWORD BAD_EMAIL EMAIL_TAKEN TOO_MANY BAD_CODE OWN_GROUP NOT_MEMBER SESSION_EXPIRED BAD_INPUT

create or replace function public.user_login(p_username text, p_password text) returns json
language plpgsql security definer set search_path = '' as $$
declare u public.users;
begin
  select * into u from public.users where username = lower(trim(p_username));
  if u.id is null then raise exception 'BAD_LOGIN'; end if;
  if u.locked_until is not null and u.locked_until > now() then raise exception 'LOCKED'; end if;
  if u.pw_hash <> extensions.crypt(trim(p_password), u.pw_hash) then
    update public.users set fail_count = fail_count + 1,
      locked_until = case when fail_count + 1 >= 8 then now() + interval '10 minutes' else locked_until end
    where id = u.id;
    raise exception 'BAD_LOGIN';
  end if;
  update public.users set fail_count = 0, locked_until = null, last_seen = now() where id = u.id;
  return json_build_object('token', private.new_session(u.id), 'me', private.me_json(u.id));
end $$;

create or replace function public.user_register(p_username text, p_name text, p_password text, p_email text default null) returns json
language plpgsql security definer set search_path = '' as $$
declare un text := lower(trim(p_username)); pw text := trim(p_password); nm text := trim(p_name);
        em text := nullif(lower(trim(coalesce(p_email, ''))), ''); uid bigint; ip bytea;
begin
  if nm = '' or char_length(nm) > 20 then raise exception 'BAD_NAME'; end if;
  if un !~ '^[a-z0-9]{2,24}$' then raise exception 'BAD_USERNAME'; end if;
  if char_length(pw) < 6 or char_length(pw) > 40 then raise exception 'BAD_PASSWORD'; end if;
  if em is not null and (char_length(em) > 120 or em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then raise exception 'BAD_EMAIL'; end if;
  ip := extensions.digest(coalesce(split_part(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ',', 1), 'unknown'), 'sha256');
  delete from private.reg_log where at < now() - interval '1 day';
  if (select count(*) from private.reg_log where ip_hash = ip and at > now() - interval '1 hour') >= 40
     or (select count(*) from private.reg_log where at > now() - interval '1 hour') >= 300 then raise exception 'TOO_MANY'; end if;
  insert into private.reg_log (ip_hash) values (ip);
  if exists (select 1 from public.users where username = un) then raise exception 'USERNAME_TAKEN'; end if;
  if em is not null and exists (select 1 from public.users where lower(email) = em) then raise exception 'EMAIL_TAKEN'; end if;
  insert into public.users (name, username, pw_hash, email, last_seen)
  values (nm, un, extensions.crypt(pw, extensions.gen_salt('bf', 8)), em, now()) returning id into uid;
  return json_build_object('token', private.new_session(uid), 'me', private.me_json(uid));
end $$;

create or replace function public.user_logout(p_token text) returns void
language sql security definer set search_path = '' as $$
  delete from private.sessions where token_hash = extensions.digest(p_token, 'sha256')
$$;

create or replace function private.groups_json(p_uid bigint) returns json
language sql stable security definer set search_path = '' as $$
  select coalesce(json_agg(json_build_object('id', g.id, 'name', g.name, 'hw_pack', g.hw_pack, 'hw_daily', g.hw_daily) order by m.joined_at, g.id), '[]'::json)
  from public.group_members m join public.groups g on g.id = m.group_id where m.user_id = p_uid
$$;

create or replace function public.user_sync(p_token text) returns json
language plpgsql security definer set search_path = '' as $$
declare uid bigint := private.user_of(p_token);
begin
  update public.users set last_seen = now() where id = uid;
  return json_build_object(
    'me', private.me_json(uid),
    'groups', private.groups_json(uid),
    'progress', coalesce((select json_object_agg(unit_key, json_build_array(stars, adv)) from public.progress where user_id = uid), '{}'::json),
    'best', coalesce((select max(score) from public.tests where user_id = uid), 0));
end $$;

create or replace function public.user_update_profile(p_token text, p_name text default null, p_email text default null, p_show_on_board boolean default null) returns json
language plpgsql security definer set search_path = '' as $$
declare uid bigint := private.user_of(p_token); nm text := trim(p_name); em text := lower(trim(p_email));
begin
  if p_name is not null and (nm = '' or char_length(nm) > 20) then raise exception 'BAD_NAME'; end if;
  if p_email is not null and em <> '' and (char_length(em) > 120 or em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then raise exception 'BAD_EMAIL'; end if;
  if p_email is not null and em <> '' and exists (select 1 from public.users where lower(email) = em and id <> uid) then raise exception 'EMAIL_TAKEN'; end if;
  update public.users set
    name = coalesce(nm, name),
    email = case when p_email is null then email else nullif(em, '') end,
    show_on_board = coalesce(p_show_on_board, show_on_board)
  where id = uid;
  return private.me_json(uid);
end $$;

create or replace function public.user_change_password(p_token text, p_old text, p_new text) returns void
language plpgsql security definer set search_path = '' as $$
declare uid bigint := private.user_of(p_token); h text;
begin
  select pw_hash into h from public.users where id = uid;
  if h <> extensions.crypt(trim(p_old), h) then raise exception 'BAD_LOGIN'; end if;
  if char_length(trim(p_new)) < 6 or char_length(trim(p_new)) > 40 then raise exception 'BAD_PASSWORD'; end if;
  update public.users set pw_hash = extensions.crypt(trim(p_new), extensions.gen_salt('bf', 8)), pw_view = null where id = uid;
end $$;

create or replace function public.user_join_group(p_token text, p_code text) returns json
language plpgsql security definer set search_path = '' as $$
declare uid bigint := private.user_of(p_token); g public.groups;
begin
  select * into g from public.groups where invite_code = upper(trim(p_code));
  if g.id is null then raise exception 'BAD_CODE'; end if;
  if g.leader_id = uid then raise exception 'OWN_GROUP'; end if;
  insert into public.group_members (group_id, user_id) values (g.id, uid) on conflict do nothing;
  return json_build_object('id', g.id, 'name', g.name);
end $$;

create or replace function public.user_leave_group(p_token text, p_group bigint) returns void
language sql security definer set search_path = '' as $$
  delete from public.group_members where user_id = private.user_of(p_token) and group_id = p_group
$$;

create or replace function public.user_heartbeat(p_token text, p_seconds int) returns void
language plpgsql security definer set search_path = '' as $$
declare uid bigint := private.user_of(p_token); sec int := least(greatest(coalesce(p_seconds, 0), 0), 120);
begin
  insert into public.usage_daily as u (user_id, day, seconds, first_at, last_at)
  values (uid, private.today(), sec, now() - make_interval(secs => sec), now())
  on conflict (user_id, day) do update set seconds = least(u.seconds + excluded.seconds, 86400),
    first_at = coalesce(u.first_at, excluded.first_at), last_at = now();
  update public.users set last_seen = now() where id = uid;
end $$;

create or replace function public.user_save_progress(p_token text, p_items jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare uid bigint := private.user_of(p_token);
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then raise exception 'BAD_INPUT'; end if;
  insert into public.progress as p (user_id, unit_key, stars, adv)
  select uid, left(x->>'k', 60), least(greatest(coalesce((x->>'s')::int, 0), 0), 3), least(greatest(coalesce((x->>'a')::int, 0), 0), 3)
  from jsonb_array_elements(p_items) x where coalesce(x->>'k', '') <> ''
  on conflict (user_id, unit_key) do update
    set stars = greatest(p.stars, excluded.stars), adv = greatest(p.adv, excluded.adv), updated_at = now();
end $$;

create or replace function public.user_save_plays(p_token text, p_items jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare uid bigint := private.user_of(p_token);
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 200 then raise exception 'BAD_INPUT'; end if;
  insert into public.plays (user_id, unit_key, mode, stars, misses, at)
  select uid, left(x->>'k', 60), case when x->>'m' = 'a' then 'a' else 'n' end,
    least(greatest(coalesce((x->>'s')::int, 1), 1), 3), least(greatest(coalesce((x->>'x')::int, 0), 0), 999),
    least(greatest(coalesce(to_timestamp((x->>'t')::double precision / 1000), now()), now() - interval '7 days'), now())
  from jsonb_array_elements(p_items) x where coalesce(x->>'k', '') <> '';
end $$;

create or replace function public.user_save_test(p_token text, p_score int, p_correct int, p_wrong int, p_combo int, p_pack text) returns void
language plpgsql security definer set search_path = '' as $$
declare uid bigint := private.user_of(p_token);
begin
  insert into public.tests (user_id, score, correct, wrong, best_combo, pack)
  values (uid, least(greatest(p_score, 0), 100000), least(greatest(p_correct, 0), 999), least(greatest(p_wrong, 0), 999),
          least(greatest(p_combo, 0), 999), left(p_pack, 40));
end $$;

-- 今日：作业按小组逐个列出（hw），只列设了作业的小组
create or replace function public.user_today(p_token text) returns json
language plpgsql stable security definer set search_path = '' as $$
declare uid bigint := private.user_of(p_token); d date := private.today();
begin
  return json_build_object(
    'day', d,
    'hw', coalesce((select json_agg(json_build_object('group_id', g.id, 'group', g.name, 'pack', g.hw_pack, 'daily', g.hw_daily) order by m.joined_at, g.id)
                    from public.group_members m join public.groups g on g.id = m.group_id
                    where m.user_id = uid and g.hw_pack is not null and g.hw_daily > 0), '[]'::json),
    'first_today', coalesce((select json_agg(k) from (
        select unit_key k from public.plays where user_id = uid group by unit_key
        having (min(at) at time zone 'Asia/Jakarta')::date = d) x), '[]'::json),
    'recent', coalesce((select json_agg(k) from (
        select unit_key k from public.plays where user_id = uid group by unit_key
        having (min(at) at time zone 'Asia/Jakarta')::date between d - 3 and d - 1) x), '[]'::json),
    'review_done', exists (select 1 from public.review_days where user_id = uid and day = d),
    'pending', coalesce((select json_agg(unit_key) from public.reviews where user_id = uid and cleared_at is null), '[]'::json),
    'wrong_before', coalesce((select json_agg(unit_key) from public.reviews where user_id = uid and created_at > now() - interval '30 days'), '[]'::json));
end $$;

create or replace function public.user_save_review(p_token text, p_pack text, p_asked int, p_wrong text[]) returns void
language plpgsql security definer set search_path = '' as $$
declare uid bigint := private.user_of(p_token); k text;
begin
  if coalesce(array_length(p_wrong, 1), 0) > 30 then raise exception 'BAD_INPUT'; end if;
  insert into public.review_days (user_id, day, pack, asked, wrong)
  values (uid, private.today(), left(p_pack, 40), least(greatest(coalesce(p_asked, 0), 0), 50), coalesce(array_length(p_wrong, 1), 0))
  on conflict (user_id, day) do nothing;
  foreach k in array coalesce(p_wrong, '{}') loop
    insert into public.reviews (user_id, unit_key, pack, created_at, cleared_at)
    values (uid, left(k, 60), left(p_pack, 40), now(), null)
    on conflict (user_id, unit_key) do update set created_at = now(), cleared_at = null, pack = excluded.pack;
  end loop;
end $$;

create or replace function public.user_hw_report(p_token text, p_pack text, p_new int, p_target int) returns void
language plpgsql security definer set search_path = '' as $$
declare uid bigint := private.user_of(p_token);
begin
  insert into public.hw_days as h (user_id, day, pack, new_levels, target, at)
  values (uid, private.today(), coalesce(left(p_pack, 40), ''), least(greatest(coalesce(p_new, 0), 0), 500), least(greatest(coalesce(p_target, 0), 0), 50), now())
  on conflict (user_id, day, pack) do update set new_levels = greatest(h.new_levels, excluded.new_levels), target = excluded.target, at = now();
end $$;

create or replace function public.user_save_writing(p_token text, p_word text, p_kind text, p_body text, p_ref text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare uid bigint := private.user_of(p_token);
begin
  if p_kind not in ('translate', 'write', 'assess') or coalesce(trim(p_body), '') = '' then raise exception 'BAD_INPUT'; end if;
  insert into public.writings (user_id, word, kind, body, ref)
  values (uid, left(trim(p_word), 60), p_kind, left(trim(p_body), 400), left(p_ref, 2000));
end $$;

create or replace function public.user_writings(p_token text) returns json
language sql stable security definer set search_path = '' as $$
  select coalesce(json_agg(json_build_object('id', w.id, 'word', w.word, 'kind', w.kind, 'body', w.body, 'at', w.at, 'note', w.note) order by w.at desc), '[]')
  from (select * from public.writings where user_id = private.user_of(p_token) order by at desc limit 50) w
$$;

-- 榜单。p_scope: 'all' 总榜 | 'group' 小组榜（p_group 不给时取我加入的第一个小组）
-- 总榜：不显示选了隐藏的人（本人和主账号能看到，主账号看到的带 hidden:true）。小组榜：组员全显示。
create or replace function public.leaderboard(p_token text, p_kind text, p_period text default 'all', p_scope text default 'all',
                                              p_pack text default null, p_group bigint default null) returns json
language plpgsql stable security definer set search_path = '' as $$
declare uid bigint := private.user_of(p_token); adm boolean; gid bigint; d date := private.today(); since date; res json;
begin
  select is_admin into adm from public.users where id = uid;
  if p_scope in ('group', 'class') then
    gid := coalesce(p_group, (select group_id from public.group_members where user_id = uid order by joined_at, group_id limit 1));
    if gid is null or not (adm or exists (select 1 from public.group_members where group_id = gid and user_id = uid)
                           or exists (select 1 from public.groups where id = gid and leader_id = uid)) then
      raise exception 'NOT_MEMBER';
    end if;
  end if;
  since := case p_period when 'day' then d when 'week' then date_trunc('week', d)::date else null end;
  with base as (
    select u.id, u.name, not u.show_on_board as hidden,
      coalesce((select g.name from public.group_members m join public.groups g on g.id = m.group_id
                where m.user_id = u.id order by m.joined_at, g.id limit 1), '个人') as cls,
      case p_kind
        when 'stars' then case when since is null
          then (select coalesce(sum(p.stars + p.adv), 0) from public.progress p where p.user_id = u.id)
          else (select coalesce(sum(m), 0) from (select max(pl.stars) m from public.plays pl
                  where pl.user_id = u.id and (pl.at at time zone 'Asia/Jakarta')::date >= since
                  group by pl.unit_key, pl.mode) x) end
        when 'test'  then (select coalesce(max(t.score), 0) from public.tests t where t.user_id = u.id
                             and t.pack is not distinct from p_pack
                             and (since is null or (t.created_at at time zone 'Asia/Jakarta')::date >= since))
        when 'time'  then (select coalesce(sum(x.seconds), 0) / 60 from public.usage_daily x where x.user_id = u.id
                             and (since is null or x.day >= since))
      end as val
    from public.users u
    where case when gid is not null then exists (select 1 from public.group_members m where m.group_id = gid and m.user_id = u.id)
               else (u.show_on_board or u.id = uid or adm) end
  ), ranked as (
    select id, name, cls, hidden, val, rank() over (order by val desc) as rk from base where val > 0
  )
  select json_build_object(
    'rows', coalesce((select json_agg(json_build_object('rank', rk, 'name', name, 'cls', cls, 'val', val, 'me', id = uid,
                                                        'hidden', gid is null and hidden) order by rk, name)
                      from (select * from ranked order by rk, name limit 50) x), '[]'::json),
    'me', (select json_build_object('rank', rk, 'val', val) from ranked where id = uid),
    'total', (select count(*) from ranked))
  into res;
  return res;
end $$;

create or replace function public.leaderboard_packs(p_token text) returns json
language plpgsql stable security definer set search_path = '' as $$
declare uid bigint := private.user_of(p_token); adm boolean; hw text;
begin
  select is_admin into adm from public.users where id = uid;
  select g.hw_pack into hw from public.group_members m join public.groups g on g.id = m.group_id
    where m.user_id = uid and g.hw_pack is not null order by m.joined_at, g.id limit 1;
  return json_build_object('hw', hw, 'packs', coalesce((
    select json_agg(json_build_object('pack', pack, 'players', players, 'mine', mine) order by (pack = hw) desc, players desc, pack)
    from (select t.pack, count(distinct t.user_id) as players, bool_or(t.user_id = uid) as mine
          from public.tests t join public.users u on u.id = t.user_id
          where t.pack is not null and (u.show_on_board or u.id = uid or adm)
          group by t.pack) x), '[]'::json));
end $$;

-- ========== 7. 旧页面转接（新版 index.html 上线后，在 cleanup 迁移里删除） ==========
create or replace function public.student_login(p_username text, p_password text) returns json
language plpgsql security definer set search_path = '' as $$
declare r json := public.user_login(p_username, p_password);
begin
  return json_build_object('token', r->>'token', 'name', r->'me'->>'name', 'username', r->'me'->>'username', 'class', null);
end $$;
create or replace function public.student_register(p_name text, p_username text, p_password text) returns json
language plpgsql security definer set search_path = '' as $$
declare r json := public.user_register(p_username, p_name, p_password, null);
begin
  return json_build_object('token', r->>'token', 'name', r->'me'->>'name', 'username', r->'me'->>'username', 'class', null);
end $$;
create or replace function public.student_logout(p_token text) returns void language sql security definer set search_path = '' as $$ select public.user_logout(p_token) $$;
create or replace function public.student_sync(p_token text) returns json
language sql security definer set search_path = '' as $$
  select (public.user_sync(p_token)::jsonb || jsonb_build_object('name', (public.user_sync(p_token)->'me'->>'name')))::json
$$;
create or replace function public.student_heartbeat(p_token text, p_seconds int) returns void language sql security definer set search_path = '' as $$ select public.user_heartbeat(p_token, p_seconds) $$;
create or replace function public.student_save_progress(p_token text, p_items jsonb) returns void language sql security definer set search_path = '' as $$ select public.user_save_progress(p_token, p_items) $$;
create or replace function public.student_save_plays(p_token text, p_items jsonb) returns void language sql security definer set search_path = '' as $$ select public.user_save_plays(p_token, p_items) $$;
create or replace function public.student_save_test(p_token text, p_score int, p_correct int, p_wrong int, p_combo int, p_pack text) returns void language sql security definer set search_path = '' as $$ select public.user_save_test(p_token, p_score, p_correct, p_wrong, p_combo, p_pack) $$;
create or replace function public.student_save_review(p_token text, p_pack text, p_asked int, p_wrong text[]) returns void language sql security definer set search_path = '' as $$ select public.user_save_review(p_token, p_pack, p_asked, p_wrong) $$;
create or replace function public.student_hw_report(p_token text, p_pack text, p_new int, p_target int) returns void language sql security definer set search_path = '' as $$ select public.user_hw_report(p_token, p_pack, p_new, p_target) $$;
create or replace function public.student_save_writing(p_token text, p_word text, p_kind text, p_body text, p_ref text default null) returns void language sql security definer set search_path = '' as $$ select public.user_save_writing(p_token, p_word, p_kind, p_body, p_ref) $$;
create or replace function public.student_writings(p_token text) returns json language sql stable security definer set search_path = '' as $$ select public.user_writings(p_token) $$;
create or replace function public.student_today(p_token text) returns json
language sql stable security definer set search_path = '' as $$
  select (t::jsonb || jsonb_build_object('hw_pack', t->'hw'->0->>'pack', 'hw_daily', coalesce((t->'hw'->0->>'daily')::int, 0)))::json
  from (select public.user_today(p_token) t) x
$$;

-- @@LEADER_FUNCTIONS@@

-- ========== 9. 核对：条数与每人星星必须和迁移前一致，否则整体回滚 ==========
do $$ declare r record; now_n bigint;
begin
  for r in select * from _mig_count loop
    execute format('select count(*) from %s', case r.t when 'sessions' then 'private.sessions' else 'public.' || r.t end) into now_n;
    if now_n <> r.n then raise exception 'VERIFY_FAILED: % before=% after=%', r.t, r.n, now_n; end if;
  end loop;
  if exists (select 1 from _mig_stars m full join (select user_id uid, sum(stars + adv) s, count(*) c from public.progress group by 1) p using (uid)
             where m.s is distinct from p.s or m.c is distinct from p.c) then
    raise exception 'VERIFY_FAILED: progress per user';
  end if;
  if (select count(*) from public.users where is_admin) <> 1 then raise exception 'VERIFY_FAILED: admin'; end if;
end $$;
