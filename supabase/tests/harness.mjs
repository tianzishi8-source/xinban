// 本地测试库：用 PGlite（内存里的 Postgres）重建线上结构。只用来跑测试，不连线上。
import { PGlite } from "@electric-sql/pglite";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SB = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = f => readFileSync(join(SB, f), "utf8");

// Supabase 自带、本地没有的东西：auth.users、auth.uid()、角色、extensions schema
const STUBS = `
create schema if not exists extensions; create extension if not exists pgcrypto with schema extensions;
create schema if not exists auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text, created_at timestamptz default now());
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
do $$ begin create role anon; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated; exception when duplicate_object then null; end $$;
create schema if not exists private;`;

// 线上有、仓库 SQL 里没有的部分（2026-11-28 从线上读出）
const PROD_EXTRA = `
alter table public.students add column if not exists pw_view text;
alter table public.usage_daily add column if not exists first_at timestamptz, add column if not exists last_at timestamptz;
create table if not exists public.writings (
  id bigint generated always as identity primary key,
  student_id bigint not null references public.students(id) on delete cascade,
  word text not null, kind text not null check (kind in ('translate','write','assess')),
  body text not null, ref text, at timestamptz not null default now(), note text, noted_at timestamptz);
alter table public.writings enable row level security;
create or replace function public.student_save_writing(p_token text, p_word text, p_kind text, p_body text, p_ref text default null)
returns void language plpgsql security definer set search_path to '' as $f$
declare sid bigint := private.student_of(p_token);
begin
  if p_kind not in ('translate', 'write', 'assess') or coalesce(trim(p_body), '') = '' then raise exception 'BAD_INPUT'; end if;
  insert into public.writings (student_id, word, kind, body, ref) values (sid, left(trim(p_word), 60), p_kind, left(trim(p_body), 400), left(p_ref, 2000));
end $f$;
create or replace function public.student_writings(p_token text) returns json language sql stable security definer set search_path to '' as $f$
  select coalesce(json_agg(json_build_object('id', w.id, 'word', w.word, 'kind', w.kind, 'body', w.body, 'at', w.at, 'note', w.note) order by w.at desc), '[]')
  from (select * from public.writings where student_id = private.student_of(p_token) order by at desc limit 50) w $f$;
create or replace function public.teacher_note_writing(p_id bigint, p_note text) returns void language plpgsql security definer set search_path to '' as $f$
begin
  if not exists (select 1 from public.writings w join public.students s on s.id = w.student_id where w.id = p_id and private.owns_class(s.class_id)) then raise exception 'NOT_YOUR_CLASS'; end if;
  update public.writings set note = nullif(left(trim(p_note), 300), ''), noted_at = now() where id = p_id;
end $f$;
create or replace function public.teacher_writings(p_class bigint, p_days integer default 14) returns json language plpgsql stable security definer set search_path to '' as $f$
declare r json;
begin
  if not private.owns_class(p_class) then raise exception 'NOT_YOUR_CLASS'; end if;
  select coalesce(json_agg(json_build_object('id', w.id, 'sid', s.id, 'name', s.name, 'word', w.word, 'kind', w.kind,
         'body', w.body, 'ref', w.ref, 'at', w.at, 'note', w.note) order by w.at desc), '[]') into r
  from public.writings w join public.students s on s.id = w.student_id
  where s.class_id = p_class and w.at > now() - make_interval(days => least(greatest(p_days, 1), 120));
  return r;
end $f$;`;

const BASE = () => [STUBS, read("schema.sql"),
  ...["migrations_2026-11-23_leaderboard.sql","migrations_2026-11-23_self_register.sql","migrations_2026-11-26_leaderboard_by_pack.sql","migrations_2026-11-26_leaderboard_day.sql","migrations_2026-11-26_homework_review.sql"].map(read), PROD_EXTRA];

// 和线上相似的种子数据：老师 + 6 个班（含开放班、隐藏班）+ 若干学生和记录
export const TEACHER_UID = "11111111-1111-1111-1111-111111111111";
const SEED = `
insert into auth.users(id,email) values ('${TEACHER_UID}','t@x.com'),('22222222-2222-2222-2222-222222222222','other@x.com');
delete from public.classes;
insert into public.classes(teacher_id,name,prefix,is_open,hide_rank) values
 ('${TEACHER_UID}','G7','km',false,false),('${TEACHER_UID}','G8','pq',false,false),
 ('${TEACHER_UID}','老师自己','tt',false,true),('${TEACHER_UID}','自助注册（待分班）','zz',true,false);
insert into public.students(class_id,name,username,pw_hash,pw_view)
 select c.id, n, u, extensions.crypt('123456', extensions.gen_salt('bf',4)), '123456' from (values
  ('G7','甲','km01'),('G7','乙','km02'),('G8','丙','pq01'),('老师自己','老师','teacher'),('自助注册（待分班）','丁','ding')) v(cn,n,u)
 join public.classes c on c.name=v.cn;
insert into public.progress(student_id,unit_key,stars) select id, 'u'||g, 1+(g%3) from public.students, generate_series(1,4) g;
insert into public.plays(student_id,unit_key,mode,stars,misses) select id,'u1','n',3,0 from public.students;
insert into public.tests(student_id,score,correct,wrong,best_combo,pack) select id, 100*id, 5,1,3,'约翰福音' from public.students;
insert into public.usage_daily(student_id,day,seconds) select id, current_date, 60 from public.students;
insert into public.writings(student_id,word,kind,body) select id,'恩典','write','句子' from public.students where username='km01';
insert into private.teacher_keys(key_hash,teacher_id) values (extensions.digest('tk','sha256'),'${TEACHER_UID}');`;

export async function db({ migrate = [] } = {}) {
  const pg = new PGlite({ extensions: { pgcrypto } });
  for (const sql of [...BASE(), SEED, ...migrate.map(f => read(f))]) await pg.exec(sql);
  return pg;
}
// 像 PostgREST 一样：返回表的函数得到数组，其余得到单个值
export const rpc = async (pg, fn, args = {}) => {
  const ks = Object.keys(args), call = `public.${fn}(${ks.map((k, i) => `${k} => $${i + 1}`).join(",")})`, vals = ks.map(k => args[k]);
  const srf = (await pg.query("select bool_or(proretset) s from pg_proc where proname=$1", [fn])).rows[0].s;
  if (srf) return (await pg.query(`select to_json(x) r from ${call} x`, vals)).rows.map(r => r.r);
  return (await pg.query(`select ${call} as r`, vals)).rows[0].r;
};
export const one = async (pg, sql, p = []) => (await pg.query(sql, p)).rows[0];
export const asUid = (pg, uid) => pg.exec(`select set_config('test.uid','${uid ?? ""}',false)`);
export const withKey = (pg, key) => pg.exec(`select set_config('request.headers','${key ? JSON.stringify({ "x-leader-key": key, "x-teacher-key": key }) : ""}',false)`);
