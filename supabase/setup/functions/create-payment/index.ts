// create-payment — the payment seam, production side.
//
// Bakong is NOT a direct production acceptance gateway. Real fee collection
// goes through a bank / PSP merchant API (ABA PayWay, ACLEDA, Wing, ...) that
// issues a checkout (hosted page and/or a KHQR) and later confirms settlement
// via a signed WEBHOOK (see payment-webhook). This function is where a fee is
// requested: it reads the Silo's payment_config, dispatches to the configured
// provider, marks the target row 'requested', and returns whatever the payer
// needs (a checkout URL / provider QR).
//
// 'manual' provider = no PSP wired: we return { manual: true } and the app
// shows an in-app KHQR for manual/offline reconciliation (dev + small orgs).
// The bank branches are stubbed with the exact shape to fill in per PSP.
// Deploy JWT-on (only our employees request a fee).
import { createClient } from 'npm:@supabase/supabase-js@2.39.3'

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' }
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } })

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const caller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: req.headers.get('Authorization') || '' } }, auth: { persistSession: false },
  })
  let body: any
  try { body = await req.json() } catch { return json({ error: 'Invalid body' }, 400) }
  const { amount, currency, reference, targetTable, targetId } = body || {}
  if (!amount || amount <= 0 || !reference) return json({ error: 'amount and reference required' }, 400)
  if (!['connect_requests', 'form_submissions'].includes(targetTable)) return json({ error: 'invalid target' }, 400)

  const { data: cfg, error: cfgErr } = await caller.from('payment_config').select('provider, merchant_id, base_url').maybeSingle()
  if (cfgErr) return json({ error: 'Unauthorized' }, 401)
  const provider = cfg?.provider || 'manual'

  // Mark the target row as fee 'requested' (RLS: caller is an employee).
  const providerRef = `PAY-${reference}`
  await caller.from(targetTable).update({ fee_amount: amount, fee_currency: currency || 'USD', fee_status: 'requested', fee_provider_ref: providerRef }).eq('id', targetId)

  if (provider === 'manual') {
    // App renders an in-app KHQR from the payee's Bakong account; settlement is
    // reconciled manually and confirmed by "mark paid" or the webhook.
    return json({ ok: true, provider: 'manual', providerRef })
  }

  // --- Bank / PSP branches (fill per integration; key from Vault) ----------
  // const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY)
  // const { data: key } = await admin.rpc('payment_get_key')
  // switch (provider) {
  //   case 'aba_payway': POST cfg.base_url + '/payment' with HMAC(key) → { checkoutUrl, qrImage }
  //   case 'acleda':     ...
  //   case 'wing':       ...
  // }
  return json({ error: `Provider '${provider}' not wired on this deployment`, provider, providerRef }, 501)
})
