// payment-webhook — the ONLY trustworthy confirmation of a fee.
//
// The bank / PSP calls this when money actually settles. It authenticates the
// callback by the shared webhook secret (swap for the PSP's HMAC signature per
// integration), then flips the matching fee to 'paid'. A fee is only ever
// marked paid here — never by a client — so payment state can't be forged from
// the app. Matches by fee_provider_ref (preferred) or reference, across both
// connect_requests and form_submissions.
// Deploy PUBLIC (--no-verify-jwt): the PSP has no Silo JWT; the secret is the
// credential this function validates itself.
import { createClient } from 'npm:@supabase/supabase-js@2.39.3'

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-webhook-secret, content-type' }
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } })
const admin = () => createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const db = admin()
  const { data: cfg } = await db.from('payment_config').select('webhook_secret').maybeSingle()
  const presented = req.headers.get('x-webhook-secret') || ''
  // Production: replace this equality with the PSP's signature verification
  // (HMAC of the raw body with the merchant key).
  if (!cfg?.webhook_secret || presented !== cfg.webhook_secret) return json({ error: 'Unauthorized' }, 401)

  let body: any
  try { body = await req.json() } catch { return json({ error: 'Invalid body' }, 400) }
  const { providerRef, reference, status } = body || {}
  if (status && status !== 'paid') return json({ ok: true, ignored: status })
  if (!providerRef && !reference) return json({ error: 'providerRef or reference required' }, 400)

  let hit = false
  for (const table of ['connect_requests', 'form_submissions']) {
    let q = db.from(table).update({ fee_status: 'paid', updated_at: new Date().toISOString() })
    q = providerRef ? q.eq('fee_provider_ref', providerRef) : q.eq('reference', reference)
    const { data } = await q.select('id')
    if (data && data.length) hit = true
  }
  if (!hit) return json({ error: 'No matching fee' }, 404)
  return json({ ok: true })
})
