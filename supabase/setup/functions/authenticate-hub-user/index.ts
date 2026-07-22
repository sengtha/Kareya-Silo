import { createClient } from 'npm:@supabase/supabase-js@2.39.3'
import { SignJWT } from 'npm:jose@5.2.0'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// 🌍 DEFAULT KAREYA HUB CONFIGURATION
// Override via edge-function secrets HUB_URL / HUB_ANON_KEY on this Silo.
const DEFAULT_HUB_URL = 'https://nwfipfbdhksucqdsyaho.supabase.co'

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
      Deno.env.get('HUB_ANON_KEY')
    if (!hubKey) throw new Error('Missing Hub anon/publishable key in Silo environment')

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
