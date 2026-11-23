-- ========== 2026-11-23（二）：排行榜，所有登录的学生都能看到 ==========
-- p_kind  : 'stars'（闯关星星，普通＋高阶）| 'test'（60 秒测试最高分）| 'time'（练习分钟）
-- p_period: 'week'（本周，周一起算，雅加达时间）| 'all'（累计）。星星榜只有累计。
-- p_scope : 'all'（全部学生）| 'class'（只看我的班）
-- 只返回前 50 名的名字、班级和成绩，以及“我”的名次。不返回账号、密码或其他信息。
create or replace function public.leaderboard(p_token text, p_kind text, p_period text default 'all', p_scope text default 'all')
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

revoke all on function public.leaderboard(text, text, text, text) from public;
grant execute on function public.leaderboard(text, text, text, text) to anon, authenticated;

-- 不上榜的班（老师自己的测试账号等）：classes.hide_rank = true。这个班的学生自己看榜时仍能看到自己的名次。
alter table public.classes add column if not exists hide_rank boolean not null default false;
update public.classes set hide_rank = true where name = '老师自己';
