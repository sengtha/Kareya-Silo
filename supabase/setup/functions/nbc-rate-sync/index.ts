// =====================================================================
// nbc-rate-sync — fetch the National Bank of Cambodia's official daily
// USD/KHR rate and record it.
// ---------------------------------------------------------------------
// Scheduled for 10:30 Phnom Penh time on business days (03:30 UTC).
//
// TWO THINGS SHAPE THIS FUNCTION:
//
// 1. NBC PUBLISHES FOR HUMANS, NOT MACHINES. There is no documented,
//    stable public API. The parser therefore tries JSON first and falls
//    back to reading the rate out of the page, and NBC_RATE_URL /
//    NBC_RATE_JSON_PATH are configurable so a changed page or a new
//    endpoint is a settings change rather than a redeploy.
//
//    This parser has NOT been verified against a live response — the
//    build environment has no route to nbc.gov.kh. Check the first run
//    in the sync log and adjust the selector if needed.
//
// 2. A SILENT FAILURE IS WORSE THAN NO SYNC. If the fetch quietly does
//    nothing, invoices keep issuing against a stale rate and nobody
//    notices for weeks. So every attempt is written to nbc_sync_log
//    with its status, HTTP code and message, successful or not.
//
// A rate already entered by hand is never overwritten: a human who
// corrected a figure outranks a scraper.
// =====================================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const DEFAULT_URL = 'https://www.nbc.gov.kh/english/economic_research/exchange_rate.php';

/** Pull a plausible USD/KHR rate out of whatever came back.
 *  Riel trades near 4,000 to the dollar, so a value far outside
 *  3,000–5,000 is a parse error rather than a rate — better to fail
 *  loudly than to record a number that quietly corrupts every invoice. */
function extractRate(body: string, jsonPath?: string): number | null {
  const plausible = (n: number) => Number.isFinite(n) && n >= 3000 && n <= 5000;

  try {
    const data = JSON.parse(body);
    if (jsonPath) {
      const v = jsonPath.split('.').reduce<any>((o, k) => (o == null ? o : o[k]), data);
      const n = Number(v);
      if (plausible(n)) return n;
    }
    for (const key of ['usd_khr', 'usdKhr', 'rate', 'official_rate', 'value']) {
      const n = Number((data as any)?.[key]);
      if (plausible(n)) return n;
    }
  } catch { /* not JSON — fall through to the page */ }

  // Numbers formatted as 4,062 or 4062.00, near a USD mention where possible.
  const near = body.match(/USD[\s\S]{0,400}?([34],?\d{3}(?:\.\d+)?)/i);
  if (near) {
    const n = Number(near[1].replace(/,/g, ''));
    if (plausible(n)) return n;
  }
  for (const m of body.matchAll(/([34],?\d{3}(?:\.\d+)?)/g)) {
    const n = Number(m[1].replace(/,/g, ''));
    if (plausible(n)) return n;
  }
  return null;
}

Deno.serve(async (req: Request) => {
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const url = Deno.env.get('NBC_RATE_URL') || DEFAULT_URL;
  const jsonPath = Deno.env.get('NBC_RATE_JSON_PATH') || undefined;
  const today = new Date().toISOString().split('T')[0];

  const log = (status: string, fields: Record<string, unknown>) =>
    supabase.from('nbc_sync_log').insert({ status, source_url: url, ...fields });

  try {
    // A rate a person entered by hand is authoritative. Do not clobber it.
    const { data: existing } = await supabase
      .from('nbc_exchange_rates').select('rate_date, source').eq('rate_date', today).maybeSingle();
    if (existing && existing.source === 'manual') {
      await log('skipped', { rate_date: today, message: 'A manually entered rate already exists for today' });
      return new Response(JSON.stringify({ ok: true, skipped: 'manual rate present' }), { status: 200 });
    }

    const res = await fetch(url, { headers: { 'User-Agent': 'Kareya/1.0 (+tax compliance)' } });
    const body = await res.text();

    if (!res.ok) {
      await log('failed', { http_status: res.status, message: `NBC returned HTTP ${res.status}` });
      return new Response(JSON.stringify({ ok: false, error: `HTTP ${res.status}` }), { status: 502 });
    }

    const rate = extractRate(body, jsonPath);
    if (rate === null) {
      await log('failed', {
        http_status: res.status,
        message: 'Could not find a plausible USD/KHR rate in the response. ' +
                 'Set NBC_RATE_URL / NBC_RATE_JSON_PATH, or enter today\'s rate by hand.',
      });
      return new Response(JSON.stringify({ ok: false, error: 'rate not found' }), { status: 422 });
    }

    const { error } = await supabase.from('nbc_exchange_rates')
      .upsert({ rate_date: today, usd_to_khr: rate, source: 'nbc', note: 'Auto-synced from NBC' },
              { onConflict: 'rate_date' });
    if (error) {
      await log('failed', { http_status: res.status, usd_to_khr: rate, message: error.message });
      return new Response(JSON.stringify({ ok: false, error: error.message }), { status: 500 });
    }

    await log('ok', { rate_date: today, usd_to_khr: rate, http_status: res.status, message: 'Synced' });
    return new Response(JSON.stringify({ ok: true, rate_date: today, usd_to_khr: rate }), { status: 200 });
  } catch (e) {
    await log('failed', { message: (e as Error).message });
    return new Response(JSON.stringify({ ok: false, error: (e as Error).message }), { status: 500 });
  }
});
