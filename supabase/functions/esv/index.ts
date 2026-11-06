// 心版 · ESV 英文经文取用
// 学生端传来一组出处（例如 "John 3:16"），先查服务器缓存，没有的再向 ESV API 取。
// ESV 密钥存在 public.esv_config（仅 service role 可读），不会出现在网页里。
// 遵守 ESV API v3 规定：每次查询不超过 500 节；每分钟不超过 60 次。
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// 书名 + 章:节（可含 -、逗号）
const REF = /^(?:[1-3] )?[A-Z][A-Za-z ]{1,30} \d{1,3}:\d{1,3}(?:-\d{1,3}(?::\d{1,3})?)?(?:,\d{1,3}(?:-\d{1,3})?)*$/;
const NOTICE =
  "Scripture quotations are from the ESV® Bible (The Holy Bible, English Standard Version®), © 2001 by Crossway, a publishing ministry of Good News Publishers. Used by permission. All rights reserved.";

// 估算节数，用来把一次查询控制在 500 节以内
function verses(ref: string): number {
  const tail = ref.slice(ref.lastIndexOf(" ") + 1);
  let n = 0;
  for (const part of tail.split(",")) {
    const [a, b] = part.split("-");
    const va = +(a.includes(":") ? a.split(":")[1] : a);
    if (!b) n += 1;
    else if (b.includes(":")) n += 40;
    else n += Math.max(1, +b - va + 1);
  }
  return n;
}
const parts = (ref: string) => ref.slice(ref.lastIndexOf(" ") + 1).split(",").length;

let KEY = "";
async function key() {
  if (KEY) return KEY;
  const { data, error } = await sb.from("esv_config").select("api_key").eq("id", 1).single();
  if (error || !data) throw new Error("NO_KEY");
  return (KEY = data.api_key);
}

async function fetchChunk(refs: string[]): Promise<Record<string, string>> {
  const p = new URLSearchParams({
    q: refs.join(";"),
    "include-headings": "false",
    "include-footnotes": "false",
    "include-short-copyright": "false",
    "include-copyright": "false",
    "include-passage-references": "false",
    "include-verse-numbers": "true",
    "include-first-verse-numbers": "true",
    "indent-paragraphs": "0",
    "indent-poetry": "false",
    "include-selahs": "true",
  });
  const r = await fetch("https://api.esv.org/v3/passage/text/?" + p, { headers: { Authorization: "Token " + (await key()) } });
  if (!r.ok) throw new Error("ESV_" + r.status);
  const d = await r.json();
  const ps: string[] = d.passages || [];
  const out: Record<string, string> = {};
  let k = 0;
  for (const ref of refs) {
    const n = parts(ref);
    // 逗号分开的出处，ESV 会拆成几段；按顺序拼回来。去掉诗篇标题等第一个节号之前的文字。
    const txt = ps.slice(k, k + n).map((s) => {
      const i = s.indexOf("[");
      return (i >= 0 ? s.slice(i) : s).replace(/\s+/g, " ").trim();
    }).join(" ");
    k += n;
    if (txt) out[ref] = txt;
  }
  return out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "METHOD" }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const refs: unknown = body?.refs;
    if (!Array.isArray(refs) || refs.length > 400) return json({ error: "BAD_INPUT" }, 400);
    const list = [...new Set(refs.filter((r): r is string => typeof r === "string" && REF.test(r)))];
    const texts: Record<string, string> = {};
    for (let i = 0; i < list.length; i += 200) {
      const { data } = await sb.from("esv_cache").select("ref,text").in("ref", list.slice(i, i + 200));
      for (const row of data || []) texts[row.ref] = row.text;
    }
    const miss = list.filter((r) => !(r in texts));
    // 分批：每批不超过 60 个出处、约 400 节
    const chunks: string[][] = [];
    let cur: string[] = [], cnt = 0;
    for (const r of miss) {
      const v = verses(r);
      if (cur.length && (cur.length >= 60 || cnt + v > 400)) { chunks.push(cur); cur = []; cnt = 0; }
      cur.push(r); cnt += v;
    }
    if (cur.length) chunks.push(cur);
    for (const c of chunks.slice(0, 8)) {
      const got = await fetchChunk(c);
      const rows = Object.entries(got).map(([ref, text]) => ({ ref, text, fetched_at: new Date().toISOString() }));
      if (rows.length) await sb.from("esv_cache").upsert(rows);
      Object.assign(texts, got);
    }
    return json({ texts, notice: NOTICE });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 502);
  }
});
