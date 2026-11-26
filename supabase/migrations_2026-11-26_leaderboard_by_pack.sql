-- ========== 2026-11-26：测验榜按经文包（书卷）分开排 ==========
-- 不同书卷难度不同（约翰福音 123 条，约书亚记 3 条），测验榜只在同一个经文包里比。
-- leaderboard 加参数 p_pack：p_kind='test' 时只算这个经文包的测试成绩（必须给 p_pack）。
-- leaderboard_packs 列出有人考过的经文包，以及考过的人数，供页面做选择。
drop function if exists public.leaderboard(text, text, text, text);

create or replace function public.leaderboard(p_token text, p_kind text, p_period text default 'all', p_scope text default 'all', p_pack text default null)
returns json
language plpgsql stable security definer set search_path = '' as $$
declare sid bigint := private.student_of(p_token); my_cls bigint; wk date; res json;
begin
  select class_id into my_cls from public.students where id = sid;
  wk := date_trunc('week', private.today())::date;
  with base as (
    select s.id, s.name, c.name as cls,
      case p_kind
        when 'stars' then (select coalesce(sum(p.stars + p.adv), 0) from public.progress p where p.student_id = s.id)
        when 'test'  then (select coalesce(max(t.score), 0) from public.tests t where t.student_id = s.id
                             and t.pack is not distinct from p_pack
                             and (p_period <> 'week' or (t.created_at at time zone 'Asia/Jakarta')::date >= wk))
        when 'time'  then (select coalesce(sum(u.seconds), 0) / 60 from public.usage_daily u where u.student_id = s.id
                             and (p_period <> 'week' or u.day >= wk))
      end as val
    from public.students s join public.classes c on c.id = s.class_id
    where (not c.hide_rank or s.id = sid) and (p_scope <> 'class' or s.class_id = my_cls)
  ), ranked as (
    select id, name, cls, val, rank() over (order by val desc) as rk from base where val > 0
  )
  select json_build_object(
    'rows', coalesce((select json_agg(json_build_object('rank', rk, 'name', name, 'cls', cls, 'val', val, 'me', id = sid) order by rk, name)
                      from (select * from ranked order by rk, name limit 50) x), '[]'::json),
    'me', (select json_build_object('rank', rk, 'val', val) from ranked where id = sid),
    'total', (select count(*) from ranked))
  into res;
  return res;
end $$;

-- 作业经文包：老师给每个班指定一个（classes.hw_pack），测验榜默认显示它并标“作业”
alter table public.classes add column if not exists hw_pack text check (hw_pack is null or char_length(hw_pack) <= 40);

create or replace function public.leaderboard_packs(p_token text)
returns json
language plpgsql stable security definer set search_path = '' as $$
declare sid bigint := private.student_of(p_token); hw text;
begin
  select c.hw_pack into hw from public.students s join public.classes c on c.id = s.class_id where s.id = sid;
  return json_build_object('hw', hw, 'packs', coalesce((
    select json_agg(json_build_object('pack', pack, 'players', players, 'mine', mine) order by (pack = hw) desc, players desc, pack)
    from (
      select t.pack, count(distinct t.student_id) as players, bool_or(t.student_id = sid) as mine
      from public.tests t join public.students s on s.id = t.student_id join public.classes c on c.id = s.class_id
      where t.pack is not null and (not c.hide_rank or s.id = sid)
      group by t.pack
    ) x), '[]'::json));
end $$;

create or replace function public.teacher_homework()
returns table(id bigint, hw_pack text)
language sql stable security definer set search_path = '' as $$
  select c.id, c.hw_pack from public.classes c where c.teacher_id = private.me()
$$;

create or replace function public.teacher_set_homework(p_class bigint, p_pack text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.owns_class(p_class) then raise exception 'NOT_YOUR_CLASS'; end if;
  update public.classes set hw_pack = nullif(left(trim(p_pack), 40), '') where id = p_class;
end $$;

-- 拦截不可能的测试成绩：每答对一题最多 100×4 倍＋快答 50 = 450 分；一局最多答对 80 题。超出的成绩不记录。
create or replace function public.student_save_test(p_token text, p_score int, p_correct int, p_wrong int, p_combo int, p_pack text)
returns void
language plpgsql security definer set search_path = '' as $$
declare sid bigint := private.student_of(p_token);
begin
  if p_score < 0 or p_correct < 0 or p_correct > 80 or p_score > p_correct * 450 or p_combo > p_correct then return; end if;
  insert into public.tests (student_id, score, correct, wrong, best_combo, pack)
  values (sid, p_score, p_correct, least(greatest(p_wrong, 0), 999), least(greatest(p_combo, 0), 999), left(p_pack, 40));
end $$;

revoke all on function public.leaderboard(text, text, text, text, text) from public;
grant execute on function public.leaderboard(text, text, text, text, text) to anon, authenticated;
revoke all on function public.leaderboard_packs(text) from public;
grant execute on function public.leaderboard_packs(text) to anon, authenticated;
revoke all on function public.teacher_homework() from public;
grant execute on function public.teacher_homework() to anon, authenticated;
revoke all on function public.teacher_set_homework(bigint, text) from public;
grant execute on function public.teacher_set_homework(bigint, text) to anon, authenticated;
