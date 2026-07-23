// connect-send — the transport seam, server side.
//
// Called by our own Silo (JWT-verified employee) to push a Connect envelope to
// a partner. It looks up the partner's endpoint + api key and delivers by the
// partner's chosen TRANSPORT. Today that's a direct Silo→Silo edge call
// ('edge'); the whole point of isolating it here is that a future 'camdx'
// branch can wrap the SAME envelope in an X-Road message and ride CamDX with
// zero change to the callers or the database.
//
// The frontend uses this for real partners; the single-Silo demo uses the
// 'loopback' transport (handled entirely client-side) and never calls this.
// Deploy with JWT verification ON (default): only our employees may send.
import { createClient } from 'npm:@supabase/supabase-js@2.39.3'

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' }
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } })

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  // Caller must be an employee of this Silo (RLS-checked read under their JWT).
  const caller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: req.headers.get('Authorization') || '' } }, auth: { persistSession: false },
  })
  let body: any
  try { body = await req.json() } catch { return json({ error: 'Invalid body' }, 400) }
  const { partnerId, envelope } = body || {}
  if (!partnerId || !envelope) return json({ error: 'partnerId and envelope required' }, 400)

  const { data: partner, error } = await caller.from('connect_partners').select('*').eq('id', partnerId).maybeSingle()
  if (error) return json({ error: 'Unauthorized' }, 401)
  if (!partner || partner.status !== 'active') return json({ error: 'Partner not active' }, 409)

  // --- Transport dispatch -------------------------------------------------
  if (partner.transport === 'camdx') {
    // FUTURE: wrap `envelope` in an X-Road SOAP/REST message and POST to our
    // CamDX security server, addressed to the partner's subsystem. The envelope
    // body is identical — only the outer transport differs.
    return json({ error: 'CamDX transport not configured on this deployment' }, 501)
  }

  // Default 'edge': direct Silo→Silo call to the partner's inbound door.
  if (!partner.endpoint_url) return json({ error: 'Partner has no endpoint' }, 409)
  try {
    const res = await fetch(partner.endpoint_url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-connect-key': partner.api_key || '' },
      body: JSON.stringify(envelope),
    })
    const out = await res.json().catch(() => ({}))
    if (!res.ok) return json({ error: out?.error || `Partner rejected (${res.status})` }, 502)
    return json({ ok: true, ...out })
  } catch (e) {
    console.error('connect-send transport failure:', e)
    return json({ error: 'Could not reach partner' }, 502)
  }
})
