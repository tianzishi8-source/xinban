-- ========== 2026-11-26（三）：排行榜加“今日”，星星榜也分今日 / 本周 / 总榜 ==========
-- p_period: 'day'（今天，雅加达时间）| 'week'（本周，周一起）| 'all'（总榜）
-- 星星榜的今日、本周：这段时间里过关拿到的星星，同一关同一种训练只算最高的一次（来自 plays）；总榜仍用 progress。
create or replace function public.leaderboard(p_token text, p_kind text, p_period text default 'all', p_scope text default 'all', p_pack text default null)
returns json
language plpgsql stable security definer set search_path = '' as $$
declare sid bigint := private.student_of(p_token); my_cls bigint; d date := private.today(); since date; res json;
begin
  select class_id into my_cls from public.students where id = sid;
  since := case p_period when 'day' then d when 'week' then date_trunc('week', d)::date else null end;
  with base as (
    select s.id, s.name, c.name as cls,
      case p_kind
        when 'stars' then case when since is null
          then (select coalesce(sum(p.stars + p.adv), 0) from public.progress p where p.student_id = s.id)
          else (select coalesce(sum(m), 0) from (select max(pl.stars) m from public.plays pl
                  where pl.student_id = s.id and (pl.at at time zone 'Asia/Jakarta')::date >= since
                  group by pl.unit_key, pl.mode) x) end
        when 'test'  then (select coalesce(max(t.score), 0) from public.tests t where t.student_id = s.id
                             and t.pack is not distinct from p_pack
                             and (since is null or (t.created_at at time zone 'Asia/Jakarta')::date >= since))
        when 'time'  then (select coalesce(sum(u.seconds), 0) / 60 from public.usage_daily u where u.student_id = s.id
                             and (since is null or u.day >= since))
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

create index if not exists plays_student_at_idx on public.plays (student_id, at);
