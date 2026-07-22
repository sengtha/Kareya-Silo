// notify — Silo → Hub push relay trigger for workspace events.
//
// The Silo cannot deliver Web Push itself (browsers hold one subscription,
// bound to the Hub's VAPID key). This function resolves the RIGHT recipients
// server-side under the CALLER's JWT (RLS applies), then POSTs a content-light
// alert to the Hub's hub-push-relay, authenticated by the Silo's API key.
//
// Kinds:
//   document_pending  { document_id }   → approvers of the current workflow step
//   leave_request     {}                → HR / admins
//   leave_decided     { employee_ids }  → the requester
//   expense_claim     {}                → accountants / admins
//   ticket_created    {}                → support / admins
//   ticket_assigned   { employee_ids }  → the assignee
//   task_assigned     { employee_ids }  → the assignee
//   low_stock         {}                → managers / admins
//   kitchen_order     {}                → kitchen staff
//   housekeeping_task {}                → housekeeping staff
//   appointment_booked{ employee_ids }  → the provider
//
// The caller is always excluded (no self-notifications). Body is caller-authored
// and capped; the title is fixed per kind. Recipients are re-intersected with
// Silo membership by the Hub, so nothing here can notify outside the workspace.
//
// Secrets (Silo): HUB_URL, HUB_SILO_API_KEY, optionally HUB_PUBLISHABLE_KEY.
import { createClient } from 'npm:@supabase/supabase-js@2.39.3'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })

// Which roles receive each team-wide (role-based) alert.
const KIND_ROLES: Record<string, string[]> = {
  leave_request: ['hr', 'hr manager', 'admin', 'founder'],
  expense_claim: ['accountant', 'admin', 'founder'],
  ticket_created: ['support', 'admin', 'founder'],
  low_stock: ['manager', 'admin', 'founder'],
  kitchen_order: ['kitchen', 'manager', 'admin', 'founder'],
  housekeeping_task: ['housekeeping', 'manager', 'admin', 'founder'],
}
// Kinds that target specific people (employee ids supplied by the caller).
const ASSIGNEE_KINDS = new Set(['leave_decided', 'task_assigned', 'ticket_assigned', 'appointment_booked'])

const KIND_TITLE: Record<string, string> = {
  document_pending: 'Approval needed',
  leave_request: 'Leave request',
  leave_decided: 'Leave update',
  expense_claim: 'Expense claim',
  ticket_created: 'New support ticket',
  ticket_assigned: 'Ticket assigned',
  task_assigned: 'Task assigned',
  low_stock: 'Low stock',
  kitchen_order: 'New kitchen order',
  housekeeping_task: 'Housekeeping',
  appointment_booked: 'New appointment',
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  try {
    const authHeader = req.headers.get('Authorization') || ''
    if (!authHeader) return json({ error: 'Missing authorization' }, 401)

    const url = Deno.env.get('SUPABASE_URL')!
    const userClient = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      auth: { persistSession: false },
      global: { headers: { Authorization: authHeader } },
    })
    const { data: me } = await userClient.auth.getUser()
    if (!me?.user) return json({ error: 'Not authenticated' }, 401)
    const callerUserId = me.user.id

    const payload = await req.json()
    const kind = String(payload.kind || '')
    const title = KIND_TITLE[kind]
    if (!title) return json({ error: 'Unknown kind' }, 400)

    let recipientUserIds: string[] = []
    let body = String(payload.body ?? '').slice(0, 140)
    const path = String(payload.url ?? '/').slice(0, 300) || '/'

    if (kind === 'document_pending') {
      const documentId = payload.document_id
      if (!documentId) return json({ error: 'document_id required' }, 400)
      const { data: doc } = await userClient
        .from('document_requests')
        .select('id, title, status, current_step_id, requester_id, template_id')
        .eq('id', documentId).maybeSingle()
      if (!doc || doc.status !== 'pending') return json({ success: true, sent: 0, reason: 'not_pending' })
      const { data: tpl } = await userClient
        .from('document_templates').select('workflow').eq('id', doc.template_id).maybeSingle()
      const steps: any[] = Array.isArray(tpl?.workflow) ? tpl!.workflow : []
      const step = steps.find((s) => s?.id === doc.current_step_id)
      const allowed: string[] = (step?.allowedRoles ?? []).map((r: string) => String(r).toLowerCase())
      if (allowed.length === 0) return json({ success: true, sent: 0, reason: 'no_allowed_roles' })
      const { data: emps } = await userClient.from('employees').select('id, user_id, roles').not('user_id', 'is', null)
      recipientUserIds = (emps ?? [])
        .filter((e: any) => e.id !== doc.requester_id)
        .filter((e: any) => Array.isArray(e.roles) && e.roles.some((r: string) => allowed.includes(String(r).toLowerCase())))
        .map((e: any) => e.user_id as string)
      if (!body) body = `"${String(doc.title || 'A document').slice(0, 80)}" is awaiting your approval.`
    } else if (KIND_ROLES[kind]) {
      const roles = KIND_ROLES[kind]
      const { data: emps } = await userClient.from('employees').select('user_id, roles').not('user_id', 'is', null)
      recipientUserIds = (emps ?? [])
        .filter((e: any) => Array.isArray(e.roles) && e.roles.some((r: string) => roles.includes(String(r).toLowerCase())))
        .map((e: any) => e.user_id as string)
    } else if (ASSIGNEE_KINDS.has(kind)) {
      const empIds = (payload.employee_ids ?? []) as string[]
      if (!Array.isArray(empIds) || empIds.length === 0) return json({ success: true, sent: 0, reason: 'no_targets' })
      const { data: emps } = await userClient
        .from('employees').select('user_id').in('id', empIds).not('user_id', 'is', null)
      recipientUserIds = (emps ?? []).map((e: any) => e.user_id as string)
    }

    // Never notify the caller; de-dupe.
    recipientUserIds = Array.from(new Set(recipientUserIds)).filter((id) => id && id !== callerUserId)
    if (recipientUserIds.length === 0) return json({ success: true, sent: 0 })

    const hubUrl = Deno.env.get('HUB_URL')
    const siloKey = Deno.env.get('HUB_SILO_API_KEY')
    if (!hubUrl || !siloKey) return json({ success: true, sent: 0, reason: 'relay_not_configured' })
    const hubPublishable = Deno.env.get('HUB_PUBLISHABLE_KEY') || Deno.env.get('HUB_ANON_KEY') || siloKey

    const resp = await fetch(`${hubUrl.replace(/\/$/, '')}/functions/v1/hub-push-relay`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'apikey': hubPublishable,
        'Authorization': `Bearer ${hubPublishable}`,
        'x-silo-api-key': siloKey,
      },
      body: JSON.stringify({ recipient_ids: recipientUserIds, title, body, url: path, tag: `${kind}` }),
    })
    const relay = await resp.json().catch(() => ({}))
    return json({ success: resp.ok, relay })
  } catch (error) {
    console.error('notify error:', error)
    return json({ error: String((error as Error).message || error) }, 500)
  }
})
