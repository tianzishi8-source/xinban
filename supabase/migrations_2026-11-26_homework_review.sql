-- ========== 2026-11-26（二）：每日作业关数 + 温习摸底 ==========
-- 作业：classes.hw_pack（已有）＋ classes.hw_daily（每天要完成的新关卡数，0 = 不限制）。
--       作业没完成前，游戏页只开放作业经文包的闯关和测试。
-- 摸底：每天第一次进闯关，从已过的关卡里出打字填空题；填错的关卡记为“待温习”，
--       重新过这一关即自动清除；有待温习的关卡时，不能开新关。

alter table public.classes add column if not exists hw_daily smallint not null default 0 check (hw_daily between 0 and 50);

create table if not exists public.reviews (
  student_id bigint not null references public.students(id) on delete cascade,
  unit_key text not null check (char_length(unit_key) <= 60),
  pack text check (char_length(pack) <= 40),
  created_at timestamptz not null default now(),
  cleared_at timestamptz,
  primary key (student_id, unit_key)
);
alter table public.reviews enable row level security;

create table if not exists public.review_days (
  student_id bigint not null references public.students(id) on delete cascade,
  day date not null,
  pack text check (char_length(pack) <= 40),
  asked smallint not null default 0,
  wrong smallint not null default 0,
  at timestamptz not null default now(),
  primary key (student_id, day)
);
alter table public.review_days enable row level security;

-- 每天作业进度（由游戏页上报：今天在作业经文包里新过了几关）
create table if not exists public.hw_days (
  student_id bigint not null references public.students(id) on delete cascade,
  day date not null,
  pack text check (char_length(pack) <= 40),
  new_levels smallint not null default 0,
  target smallint not null default 0,
  at timestamptz not null default now(),
  primary key (student_id, day)
);
alter table public.hw_days enable row level security;

-- 过关时自动清除这一关的“待温习”
create or replace function private.clear_review_on_play() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.reviews set cleared_at = now()
  where student_id = new.student_id and unit_key = new.unit_key and cleared_at is null and created_at <= new.at;
  return new;
end $$;
create trigger plays_clear_review after insert on public.plays for each row execute function private.clear_review_on_play();

-- 学生今天的状态
create or replace function public.student_today(p_token text)
returns json
language plpgsql stable security definer set search_path = '' as $$
declare sid bigint := private.student_of(p_token); d date := private.today(); c public.classes;
begin
  select cl.* into c from public.students s join public.classes cl on cl.id = s.class_id where s.id = sid;
  return json_build_object(
    'day', d,
    'hw_pack', c.hw_pack, 'hw_daily', c.hw_daily,
    'first_today', coalesce((select json_agg(k) from (
        select unit_key k from public.plays where student_id = sid group by unit_key
        having (min(at) at time zone 'Asia/Jakarta')::date = d) x), '[]'::json),
    'recent', coalesce((select json_agg(k) from (
        select unit_key k from public.plays where student_id = sid group by unit_key
        having (min(at) at time zone 'Asia/Jakarta')::date between d - 3 and d - 1) x), '[]'::json),
    'review_done', exists (select 1 from public.review_days where student_id = sid and day = d),
    'pending', coalesce((select json_agg(unit_key) from public.reviews where student_id = sid and cleared_at is null), '[]'::json),
    'wrong_before', coalesce((select json_agg(unit_key) from public.reviews where student_id = sid and created_at > now() - interval '30 days'), '[]'::json));
end $$;

-- 交摸底：一天只记第一次；填错的关卡记为待温习
create or replace function public.student_save_review(p_token text, p_pack text, p_asked int, p_wrong text[])
returns void
language plpgsql security definer set search_path = '' as $$
declare sid bigint := private.student_of(p_token); k text;
begin
  if coalesce(array_length(p_wrong, 1), 0) > 30 then raise exception 'BAD_INPUT'; end if;
  insert into public.review_days (student_id, day, pack, asked, wrong)
  values (sid, private.today(), left(p_pack, 40), least(greatest(coalesce(p_asked, 0), 0), 50), coalesce(array_length(p_wrong, 1), 0))
  on conflict (student_id, day) do nothing;
  foreach k in array coalesce(p_wrong, '{}') loop
    insert into public.reviews (student_id, unit_key, pack, created_at, cleared_at)
    values (sid, left(k, 60), left(p_pack, 40), now(), null)
    on conflict (student_id, unit_key) do update set created_at = now(), cleared_at = null, pack = excluded.pack;
  end loop;
end $$;

-- 上报今天作业进度
create or replace function public.student_hw_report(p_token text, p_pack text, p_new int, p_target int)
returns void
language plpgsql security definer set search_path = '' as $$
declare sid bigint := private.student_of(p_token);
begin
  insert into public.hw_days (student_id, day, pack, new_levels, target, at)
  values (sid, private.today(), left(p_pack, 40), least(greatest(coalesce(p_new, 0), 0), 500), least(greatest(coalesce(p_target, 0), 0), 50), now())
  on conflict (student_id, day) do update set pack = excluded.pack, new_levels = greatest(public.hw_days.new_levels, excluded.new_levels), target = excluded.target, at = now();
end $$;

-- 老师：设置作业经文包和每日关数；读取设置；看某天每个学生的作业和摸底情况
create or replace function public.teacher_set_homework(p_class bigint, p_pack text, p_daily int) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.owns_class(p_class) then raise exception 'NOT_YOUR_CLASS'; end if;
  update public.classes set hw_pack = nullif(left(trim(p_pack), 40), ''), hw_daily = least(greatest(coalesce(p_daily, 0), 0), 50) where id = p_class;
end $$;

create or replace function public.teacher_homework_v2()
returns table(id bigint, hw_pack text, hw_daily smallint)
language sql stable security definer set search_path = '' as $$
  select c.id, c.hw_pack, c.hw_daily from public.classes c where c.teacher_id = private.me()
$$;

create or replace function public.teacher_hw_day(p_class bigint, p_day date)
returns json
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.owns_class(p_class) then raise exception 'NOT_YOUR_CLASS'; end if;
  return coalesce((select json_agg(json_build_object(
      'id', s.id,
      'new', h.new_levels, 'target', h.target, 'pack', h.pack,
      'asked', r.asked, 'wrong', r.wrong,
      'pending', (select count(*) from public.reviews v where v.student_id = s.id and v.cleared_at is null)))
    from public.students s
    left join public.hw_days h on h.student_id = s.id and h.day = p_day
    left join public.review_days r on r.student_id = s.id and r.day = p_day
    where s.class_id = p_class), '[]'::json);
end $$;

revoke all on function public.student_today(text) from public;
grant execute on function public.student_today(text) to anon, authenticated;
revoke all on function public.student_save_review(text, text, int, text[]) from public;
grant execute on function public.student_save_review(text, text, int, text[]) to anon, authenticated;
revoke all on function public.student_hw_report(text, text, int, int) from public;
grant execute on function public.student_hw_report(text, text, int, int) to anon, authenticated;
revoke all on function public.teacher_set_homework(bigint, text, int) from public;
grant execute on function public.teacher_set_homework(bigint, text, int) to anon, authenticated;
revoke all on function public.teacher_homework_v2() from public;
grant execute on function public.teacher_homework_v2() to anon, authenticated;
revoke all on function public.teacher_hw_day(bigint, date) from public;
grant execute on function public.teacher_hw_day(bigint, date) to anon, authenticated;
revoke all on function private.clear_review_on_play() from public;
