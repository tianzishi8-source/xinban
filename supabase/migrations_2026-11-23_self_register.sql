-- ========== 2026-11-23：学生自助注册（完全开放） ==========
-- 学生在游戏首页自己注册：填名字、自设账号和密码。注册后进入老师的“自助注册（待分班）”，
-- 老师可以在后台把他们移到正式班级。老师生成的账号格式（两个字母 + 2–3 位数字，如 km01）
-- 留给老师用，自助注册不能用这种格式，免得以后批量生成时撞号。

alter table public.classes add column if not exists is_open boolean not null default false;

-- 防刷：记录注册请求（只存来源地址的哈希）
create table if not exists private.reg_log (
  id bigint generated always as identity primary key,
  ip_hash bytea,
  at timestamptz not null default now()
);
create index if not exists reg_log_at_idx on private.reg_log (at);
alter table private.reg_log enable row level security;

-- 给现有老师建一个“自助注册（待分班）”班（只有一位老师时自动建；之后可在后台改名）
do $$
declare t uuid; pre text; letters text := 'abcdefghjkmnpqrstuvwxyz';
begin
  if exists (select 1 from public.classes where is_open) then return; end if;
  select id into t from auth.users order by created_at limit 1;
  if t is null then return; end if;
  loop
    pre := substr(letters, 1 + floor(random() * 23)::int, 1) || substr(letters, 1 + floor(random() * 23)::int, 1);
    exit when not exists (select 1 from public.classes where prefix = pre);
  end loop;
  insert into public.classes (teacher_id, name, prefix, is_open) values (t, '自助注册（待分班）', pre, true);
end $$;

create or replace function public.student_register(p_name text, p_username text, p_password text)
returns json
language plpgsql security definer set search_path = '' as $$
declare un text := lower(trim(p_username)); pw text := trim(p_password); nm text := trim(p_name);
        cid bigint; sid bigint; tok text; ip bytea;
begin
  if nm = '' or char_length(nm) > 20 then raise exception 'BAD_NAME'; end if;
  if un !~ '^[a-z][a-z0-9]{3,19}$' then raise exception 'BAD_USERNAME'; end if;
  if un ~ '^[a-z]{2}[0-9]{2,3}$' then raise exception 'RESERVED_USERNAME'; end if;
  if char_length(pw) < 4 or char_length(pw) > 20 then raise exception 'BAD_PASSWORD'; end if;

  ip := extensions.digest(coalesce(split_part(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ',', 1), 'unknown'), 'sha256');
  delete from private.reg_log where at < now() - interval '1 day';
  if (select count(*) from private.reg_log where ip_hash = ip and at > now() - interval '1 hour') >= 40
     or (select count(*) from private.reg_log where at > now() - interval '1 hour') >= 300 then
    raise exception 'TOO_MANY';
  end if;
  insert into private.reg_log (ip_hash) values (ip);

  select id into cid from public.classes where is_open order by id limit 1;
  if cid is null then raise exception 'REG_CLOSED'; end if;
  if exists (select 1 from public.students where username = un) then raise exception 'USERNAME_TAKEN'; end if;

  insert into public.students (class_id, name, username, pw_hash, last_seen)
  values (cid, nm, un, extensions.crypt(pw, extensions.gen_salt('bf', 8)), now())
  returning id into sid;

  tok := encode(extensions.gen_random_bytes(24), 'hex');
  insert into private.sessions (token_hash, student_id) values (extensions.digest(tok, 'sha256'), sid);
  return json_build_object('token', tok, 'name', nm, 'username', un,
    'class', (select name from public.classes where id = cid));
exception when unique_violation then raise exception 'USERNAME_TAKEN';
end $$;

revoke all on function public.student_register(text, text, text) from public;
grant execute on function public.student_register(text, text, text) to anon, authenticated;

-- 老师把学生移到自己的另一个班
create or replace function public.teacher_move_student(p_student bigint, p_class bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare cur bigint;
begin
  select class_id into cur from public.students where id = p_student;
  if cur is null or not private.owns_class(cur) or not private.owns_class(p_class) then raise exception 'NOT_YOUR_CLASS'; end if;
  update public.students set class_id = p_class where id = p_student;
end $$;

revoke all on function public.teacher_move_student(bigint, bigint) from public, anon;
grant execute on function public.teacher_move_student(bigint, bigint) to anon, authenticated;
