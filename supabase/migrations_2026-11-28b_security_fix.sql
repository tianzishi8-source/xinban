-- 2026-11-28b 安全修补（审稿发现）
-- 1. 空密码能登录、空旧密码能改密码：比较结果为 NULL 时 if 被跳过。改成明确拒绝 NULL，并用 is distinct from。
-- 2. 输错锁定从未生效：raise 会回滚失败次数。user_login 改为返回 {error:...}（HTTP 200，事务提交），失败次数真的记下来。
-- 3. 改密码后，其他设备上的登录失效（当前这台保留）。
-- 4. leader_accounts 不把其他带领者、主账号的初始密码给非主账号看；升为带领者时清掉初始密码明文。
-- 5. “两个字母＋2–3 位数字”留给批量建账号，自己注册不能用（否则有人注册 km999 就能卡死这个前缀）。
-- 6. 取消带领者时，主账号接手的小组里去掉主账号自己的组员身份。
-- 只改函数，不动数据。

create or replace function public.user_login(p_username text, p_password text) returns json
language plpgsql security definer set search_path = '' as $$
declare u public.users;
begin
  select * into u from public.users where username = lower(trim(coalesce(p_username, '')));
  if u.id is null then return json_build_object('error', 'BAD_LOGIN'); end if;
  if u.locked_until is not null and u.locked_until > now() then return json_build_object('error', 'LOCKED'); end if;
  if p_password is null or u.pw_hash is distinct from extensions.crypt(trim(p_password), u.pw_hash) then
    update public.users set fail_count = fail_count + 1,
      locked_until = case when fail_count + 1 >= 8 then now() + interval '10 minutes' else locked_until end
    where id = u.id;
    return json_build_object('error', 'BAD_LOGIN');
  end if;
  update public.users set fail_count = 0, locked_until = null, last_seen = now() where id = u.id;
  return json_build_object('token', private.new_session(u.id), 'me', private.me_json(u.id));
end $$;

-- 旧页面转接：保持抛错的老行为（旧页面靠错误码显示提示）
create or replace function public.student_login(p_username text, p_password text) returns json
language plpgsql security definer set search_path = '' as $$
declare r json := public.user_login(p_username, p_password);
begin
  if r->>'error' is not null then raise exception '%', r->>'error'; end if;
  return json_build_object('token', r->>'token', 'name', r->'me'->>'name', 'username', r->'me'->>'username', 'class', null);
end $$;

create or replace function public.user_change_password(p_token text, p_old text, p_new text) returns void
language plpgsql security definer set search_path = '' as $$
declare uid bigint := private.user_of(p_token); h text;
begin
  select pw_hash into h from public.users where id = uid;
  if p_old is null or h is distinct from extensions.crypt(trim(p_old), h) then raise exception 'BAD_LOGIN'; end if;
  if p_new is null or char_length(trim(p_new)) < 6 or char_length(trim(p_new)) > 40 then raise exception 'BAD_PASSWORD'; end if;
  update public.users set pw_hash = extensions.crypt(trim(p_new), extensions.gen_salt('bf', 8)), pw_view = null where id = uid;
  delete from private.sessions where user_id = uid and token_hash <> extensions.digest(p_token, 'sha256');
end $$;

create or replace function public.user_register(p_username text, p_name text, p_password text, p_email text default null) returns json
language plpgsql security definer set search_path = '' as $$
declare un text := lower(trim(coalesce(p_username, ''))); pw text := trim(coalesce(p_password, '')); nm text := trim(coalesce(p_name, ''));
        em text := nullif(lower(trim(coalesce(p_email, ''))), ''); uid bigint; ip bytea;
begin
  if nm = '' or char_length(nm) > 20 then raise exception 'BAD_NAME'; end if;
  if un !~ '^[a-z0-9]{2,24}$' then raise exception 'BAD_USERNAME'; end if;
  if un ~ '^[a-z]{2}[0-9]{2,3}$' then raise exception 'RESERVED_USERNAME'; end if;
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

create or replace function public.leader_accounts(p_token text, p_group bigint)
returns table (id bigint, name text, username text, password text, last_seen timestamptz, is_leader boolean)
language plpgsql stable security definer set search_path = '' as $$
declare uid bigint := private.leader_of(p_token); adm boolean := (select u.is_admin from public.users u where u.id = uid);
begin
  perform private.check_group(uid, p_group);
  return query select s.id, s.name, s.username,
      case when (s.is_leader or s.is_admin) and not adm then '' else coalesce(s.pw_view, '') end,
      s.last_seen, s.is_leader or s.is_admin
    from public.users s join public.group_members m on m.user_id = s.id and m.group_id = p_group order by s.username;
end $$;

create or replace function public.admin_set_leader(p_token text, p_user bigint, p_on boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare adm bigint := private.admin_of(p_token);
begin
  if p_user = adm then raise exception 'BAD_INPUT'; end if;
  update public.users set is_leader = p_on, pw_view = case when p_on then null else pw_view end where id = p_user;
  if not p_on then
    delete from public.group_members m using public.groups g where g.id = m.group_id and g.leader_id = p_user and m.user_id = adm;
    update public.groups set leader_id = adm where leader_id = p_user;
  end if;
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('user_login', 'student_login', 'user_change_password', 'user_register', 'leader_accounts', 'admin_set_leader')
  loop
    execute 'revoke all on function ' || f.sig || ' from public';
    execute 'grant execute on function ' || f.sig || ' to anon, authenticated';
  end loop;
end $$;
