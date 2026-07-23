// connect-inbound — the door a partner Silo knocks on.
//
// A partner posts a Connect envelope here. This function (service role) is the
// receiver's gatekeeper: it authenticates the caller by the shared inbound key
// (identity seam — swap for CamDigiKey / asymmetric signatures later), then
// materialises the message on THIS Silo:
//   kind='request' → create an INBOUND connect_requests row (status 'received')
//   kind='status'  → update the matching inbound/outbound row we already hold
//                    (the counterpart accepted/rejected/fulfilled, or a fee was
//                    requested/paid)
// Data never pools: each side keeps its own row; only the envelope crosses.
// Deploy PUBLIC (--no-verify-jwt): partners have no Silo JWT — the inbound key
// is the credential this function validates itself.
import { createClient } from 'npm:@supabase/supabase-js@2.39.3'

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-connect-key, content-type' }
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } })

const admin = () => createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  // Identity seam: verify the shared inbound key against our config.
  const db = admin()
  const { data: cfg } = await db.from('connect_config').select('inbound_api_key').maybeSingle()
  const presented = req.headers.get('x-connect-key') || ''
  if (!cfg?.inbound_api_key || presented !== cfg.inbound_api_key) return json({ error: 'Unauthorized partner' }, 401)

  let env: any
  try { env = await req.json() } catch { return json({ error: 'Invalid envelope' }, 400) }
  const { kind } = env || {}

  if (kind === 'request') {
    // Materialise an inbound request. senderRef is the id on the SENDER's side;
    // we store it as external_ref so status updates can round-trip.
    const { requestType, reference, subject, payload, contentHash, senderRef, senderName } = env
    if (!senderRef) return json({ error: 'senderRef required' }, 400)
    // Idempotency: if we already have this senderRef, return the existing id.
    const { data: existing } = await db.from('connect_requests').select('id').eq('direction', 'inbound').eq('external_ref', senderRef).maybeSingle()
    if (existing) return json({ ok: true, externalRef: existing.id })
    // The partner is recorded loosely by name (a reverse channel is optional).
    const { data, error } = await db.from('connect_requests').insert({
      direction: 'inbound', request_type: requestType || 'referral', reference: reference || null,
      subject: subject || null, payload: payload || {}, content_hash: contentHash || null,
      status: 'received', external_ref: senderRef,
    }).select('id').single()
    if (error || !data) return json({ error: 'Failed to record request' }, 500)
    await db.from('connect_messages').insert({ request_id: data.id, actor: senderName || 'partner', type: 'received', note: 'Received from partner' })
    return json({ ok: true, externalRef: data.id })
  }

  if (kind === 'status') {
    // The counterpart changed state. Find our row by the ref they quote (which
    // is OUR id, stored on their side as external_ref → echoed back as targetRef).
    const { targetRef, status, feeAmount, feeCurrency, feeStatus, feeKhqr, note, actor } = env
    if (!targetRef) return json({ error: 'targetRef required' }, 400)
    const { data: row } = await db.from('connect_requests').select('id').eq('id', targetRef).maybeSingle()
    if (!row) return json({ error: 'Unknown request' }, 404)
    const patch: any = { updated_at: new Date().toISOString() }
    if (status) patch.status = status
    if (feeAmount != null) patch.fee_amount = feeAmount
    if (feeCurrency) patch.fee_currency = feeCurrency
    if (feeStatus) patch.fee_status = feeStatus
    if (feeKhqr !== undefined) patch.fee_khqr = feeKhqr
    await db.from('connect_requests').update(patch).eq('id', targetRef)
    await db.from('connect_messages').insert({ request_id: targetRef, actor: actor || 'partner', type: feeStatus === 'requested' ? 'fee_requested' : feeStatus === 'paid' ? 'fee_paid' : (status || 'note'), note: note || null })
    return json({ ok: true })
  }

  return json({ error: 'Unknown envelope kind' }, 400)
})
