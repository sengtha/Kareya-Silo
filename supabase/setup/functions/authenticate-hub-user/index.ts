import { createClient } from 'npm:@supabase/supabase-js@2.39.3'
import { SignJWT } from 'npm:jose@5.2.0'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// 🌍 DEFAULT KAREYA HUB CONFIGURATION
// Override via edge-function secrets HUB_URL / HUB_ANON_KEY on this Silo.
//
// HUB_URL is the Hub's SUPABASE API host — not the web app. hub.kareya.io is
// the custom domain in front of Supabase project nwfipfbdhksucqdsyaho;
// kareya.io serves the React app and would 404 every RPC made here.
// If the custom domain is ever unavailable, set HUB_URL on this Silo to
// https://nwfipfbdhksucqdsyaho.supabase.co — the same project, addressed
// directly.
const DEFAULT_HUB_URL = 'https://hub.kareya.io'

// The Hub anon key is public by design (it is shipped in the Kareya browser
// bundle) and grants nothing on its own — every table behind it is under RLS,
// and redeem_silo_ticket does its own membership check. Defaulting it means a
// Silo can redeem tickets against the official Hub with no secrets set at all;
// a self-hosted Hub still overrides it with HUB_ANON_KEY.
const DEFAULT_HUB_ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im53ZmlwZmJkaGtzdWNxZHN5YWhvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjUyOTQ0NjAsImV4cCI6MjA4MDg3MDQ2MH0.AKx0l4RCWLYQgPRSevVtEvQ7mO-IN9Vd72PkWXevRE4'

/** A Supabase anon key names its project in the `ref` claim. When HUB_URL is a
 *  *.supabase.co host, the two must agree — if they do not, every Hub call
 *  returns a bare 401 with nothing to explain it. Warn loudly rather than let
 *  that be debugged from an empty log. A custom domain carries no ref, so it
 *  is skipped rather than guessed at. */
function warnOnHubMismatch(hubUrl: string, hubKey: string) {
  const host = (() => { try { return new URL(hubUrl).hostname } catch { return '' } })()
  if (!host.endsWith('.supabase.co')) return
  const urlRef = host.split('.')[0]
  let keyRef = ''
  try { keyRef = JSON.parse(atob(hubKey.split('.')[1] || '')).ref || '' } catch { /* not a JWT */ }
  if (keyRef && urlRef && keyRef !== urlRef) {
    console.error(
      `[authenticate-hub-user] HUB_URL points at project "${urlRef}" but the Hub key is for ` +
      `"${keyRef}". Every Hub call will fail with 401. Fix HUB_URL or HUB_ANON_KEY.`,
    )
  }
}

// Map the Hub silo role -> Silo ERP roles for auto-provisioning the roster.
function rolesForHubRole(hubRole: string): string[] {
  switch (hubRole) {
    case 'admin':
      return ['Admin', 'Founder']
    case 'moderator':
      return ['Manager']
    default:
      return ['Staff']
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { ticket_id } = await req.json()
    if (!ticket_id) {
      return new Response(JSON.stringify({ error: 'Missing ticket_id' }), {
        status: 400,
        headers: corsHeaders,
      })
    }

    // 1. Resolve Hub credentials
    const hubUrl = Deno.env.get('HUB_URL') || DEFAULT_HUB_URL
    const hubKey =
      Deno.env.get('HUB_PUBLISHABLE_KEY') ||
      Deno.env.get('HUB_ANON_KEY') ||
      DEFAULT_HUB_ANON_KEY
    warnOnHubMismatch(hubUrl, hubKey)

    const hubClient = createClient(hubUrl, hubKey)

    // 2. Redeem the ticket at the Hub. This RPC deletes the ticket
    //    (single use) and verifies active membership before returning.
    const { data: hubData, error: redeemError } = await hubClient.rpc(
      'redeem_silo_ticket',
      { p_ticket_id: ticket_id },
    )

    if (redeemError || !hubData) {
      return new Response(JSON.stringify({ error: 'Invalid or expired ticket' }), {
        status: 401,
        headers: corsHeaders,
      })
    }

    // 3. Best-effort: keep this Silo's employee roster in sync with the
    //    authoritative Hub membership/role. Never blocks authentication.
    try {
      const supabaseUrl = Deno.env.get('SUPABASE_URL')
      const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
      if (supabaseUrl && serviceKey && hubData.email) {
        const admin = createClient(supabaseUrl, serviceKey, {
          auth: { persistSession: false },
        })

        const { data: existing } = await admin
          .from('employees')
          .select('id')
          .eq('email', String(hubData.email).toLowerCase())
          .maybeSingle()

        if (existing) {
          // Bind the Hub user id; do NOT overwrite locally-managed roles.
          await admin
            .from('employees')
            .update({ user_id: hubData.user_id })
            .eq('id', existing.id)
        } else {
          await admin.from('employees').insert({
            user_id: hubData.user_id,
            email: String(hubData.email).toLowerCase(),
            name: String(hubData.email).split('@')[0],
            roles: rolesForHubRole(hubData.role),
            department: hubData.role === 'admin' ? 'Management' : 'General',
            status: 'active',
          })
        }
      }
    } catch (provisionErr) {
      console.error('Roster provisioning (non-fatal):', provisionErr)
    }

    // 4. Mint this Silo's native JWT (PostgREST/GoTrue compliant).
    const siloSecretString = Deno.env.get('SILO_JWT_SECRET')
    if (!siloSecretString) throw new Error('Missing SILO_JWT_SECRET in environment')
    const secret = new TextEncoder().encode(siloSecretString)

    const jwt = await new SignJWT({
      aud: 'authenticated',
      role: 'authenticated',
      sub: hubData.user_id,
      email: hubData.email,
      session_id: crypto.randomUUID(),
      aal: 'aal1',
      is_anonymous: false,
      app_metadata: {
        provider: 'hub_ticket',
        silo_id: hubData.silo_id,
        silo_role: hubData.role,
      },
    })
      .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
      .setIssuedAt()
      .setExpirationTime('15m')
      .sign(secret)

    return new Response(JSON.stringify({ token: jwt }), {
      status: 200,
      headers: corsHeaders,
    })
  } catch (error) {
    console.error('authenticate-hub-user error:', error)
    return new Response(JSON.stringify({ error: 'Internal Server Error' }), {
      status: 500,
      headers: corsHeaders,
    })
  }
})
