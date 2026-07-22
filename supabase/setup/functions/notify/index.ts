// notify — Silo → Hub push relay trigger.
//
// The Silo cannot deliver Web Push itself (browsers hold one subscription,
// bound to the Hub's VAPID key). This function resolves the RIGHT recipients
// server-side under the CALLER's JWT (so RLS applies and the client cannot
// target arbitrary people), then POSTs a content-light alert to the Hub's
// hub-push-relay, authenticated by the Silo's own API key.
//
// Supported kinds:
//   { kind: 'document_pending', document_id }  → notify employees whose role
//        can approve the current workflow step (excluding the requester).
//
// Secrets (Silo):  HUB_URL, HUB_SILO_API_KEY, and optionally HUB_PUBLISHABLE_KEY.
// If HUB_SILO_API_KEY is missing, the relay is skipped (messaging unaffected).
import { createClient } from 'npm:@supabase/supabase-js@2.39.3'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  try {
    const authHeader = req.headers.get('Authorization') || ''
    if (!authHeader) return json({ error: 'Missing authorization' }, 401)

    const url = Deno.env.get('SUPABASE_URL')!
    // Caller-scoped client — RLS binds, so recipient resolution can't be abused.
    const userClient = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      auth: { persistSession: false },
      global: { headers: { Authorization: authHeader } },
    })
    const { data: me } = await userClient.auth.getUser()
    if (!me?.user) return json({ error: 'Not authenticated' }, 401)

    const { kind, document_id } = await req.json()

    let recipientUserIds: string[] = []
    let title = ''
    let body = ''
    let path = '/'

    if (kind === 'document_pending') {
      if (!document_id) return json({ error: 'document_id required' }, 400)

      const { data: doc } = await userClient
        .from('document_requests')
        .select('id, title, status, current_step_id, requester_id, template_id')
        .eq('id', document_id).maybeSingle()
      if (!doc || doc.status !== 'pending') return json({ success: true, sent: 0, reason: 'not_pending' })

      const { data: tpl } = await userClient
        .from('document_templates').select('workflow').eq('id', doc.template_id).maybeSingle()
      const steps: any[] = Array.isArray(tpl?.workflow) ? tpl!.workflow : []
      const step = steps.find((s) => s?.id === doc.current_step_id)
      const allowed: string[] = (step?.allowedRoles ?? []).map((r: string) => String(r).toLowerCase())
      if (allowed.length === 0) return json({ success: true, sent: 0, reason: 'no_allowed_roles' })

      // Employees whose roles intersect the step's allowedRoles, excluding the
      // requester and anyone without a linked Hub account. RLS lets employees
      // read the employee roster.
      const { data: emps } = await userClient
        .from('employees').select('id, user_id, roles').not('user_id', 'is', null)
      recipientUserIds = (emps ?? [])
        .filter((e: any) => e.id !== doc.requester_id)
        .filter((e: any) => Array.isArray(e.roles) &&
          e.roles.some((r: string) => allowed.includes(String(r).toLowerCase())))
        .map((e: any) => e.user_id as string)

      title = 'Approval needed'
      body = `"${String(doc.title || 'A document').slice(0, 80)}" is awaiting your approval.`
      path = '/'   // opens the app; the Documents inbox surfaces the request
    } else {
      return json({ error: 'Unknown kind' }, 400)
    }

    recipientUserIds = Array.from(new Set(recipientUserIds)).filter(Boolean)
    if (recipientUserIds.length === 0) return json({ success: true, sent: 0 })

    const hubUrl = Deno.env.get('HUB_URL')
    const siloKey = Deno.env.get('HUB_SILO_API_KEY')
    if (!hubUrl || !siloKey) return json({ success: true, sent: 0, reason: 'relay_not_configured' })
    // Hub publishable key lets the request pass Supabase's edge gateway; the
    // Silo's own key travels in x-silo-api-key and is what the relay checks.
    const hubPublishable = Deno.env.get('HUB_PUBLISHABLE_KEY') || Deno.env.get('HUB_ANON_KEY') || siloKey

    const resp = await fetch(`${hubUrl.replace(/\/$/, '')}/functions/v1/hub-push-relay`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'apikey': hubPublishable,
        'Authorization': `Bearer ${hubPublishable}`,
        'x-silo-api-key': siloKey,
      },
      body: JSON.stringify({ recipient_ids: recipientUserIds, title, body, url: path, tag: `doc-${document_id}` }),
    })
    const relay = await resp.json().catch(() => ({}))
    return json({ success: resp.ok, relay })
  } catch (error) {
    console.error('notify error:', error)
    return json({ error: String((error as Error).message || error) }, 500)
  }
})
