// Normalized tool registry for the assistant. Every tool executes against the
// caller's RLS-scoped Supabase client (userClient) or the RAG search RPC, so
// the assistant can never read data the user couldn't read themselves.
//
// Read tools query tables directly (RLS filters the rows). Write tools MUST be
// routed through an existing SECURITY DEFINER RPC that re-enforces the same
// authorization the UI relies on — never a raw table mutation. process_document
// below is the reference: the RPC itself checks the caller is an employee, is
// not actioning their own request, and holds a role allowed at the current
// workflow step, so the assistant can approve nothing the user couldn't.

export interface ToolCtx {
  userClient: any
  // Embed a query with Gemini (null when no embedding key / RAG disabled).
  embed: ((text: string) => Promise<number[]>) | null
  ragEnabled: boolean
}

export interface ToolDef {
  name: string
  description: string
  parameters: Record<string, unknown> // JSON Schema (object)
  run: (args: any) => Promise<unknown>
}

const today = () => new Date().toISOString().split('T')[0]

export function buildTools(ctx: ToolCtx): ToolDef[] {
  const tools: ToolDef[] = []

  if (ctx.ragEnabled && ctx.embed) {
    tools.push({
      name: 'search_knowledge',
      description:
        'Search the business knowledge base (help articles, manuals, uploaded documents) for relevant information. Use this whenever the user asks about policies, procedures, how-to, or anything that would be documented rather than stored as structured records.',
      parameters: {
        type: 'object',
        properties: { query: { type: 'string', description: 'The search query' } },
        required: ['query'],
      },
      run: async ({ query }: { query: string }) => {
        const vec = await ctx.embed!(query)
        const { data, error } = await ctx.userClient.rpc('match_kb_chunks', {
          query_embedding: vec, match_count: 6, min_similarity: 0.45,
        })
        if (error) return { error: error.message }
        return (data || []).map((r: any) => ({ title: r.title, content: r.content, similarity: r.similarity }))
      },
    })
  }

  tools.push({
    name: 'list_overdue_invoices',
    description: 'List unpaid invoices whose due date has passed. Returns invoice number, amount, due date and status.',
    parameters: { type: 'object', properties: {}, required: [] },
    run: async () => {
      const { data, error } = await ctx.userClient
        .from('invoices')
        .select('invoice_number, amount, due_date, status')
        .neq('status', 'paid')
        .lt('due_date', today())
        .order('due_date', { ascending: true })
        .limit(50)
      if (error) return { error: error.message }
      const total = (data || []).reduce((s: number, r: any) => s + (Number(r.amount) || 0), 0)
      return { count: data?.length || 0, total_outstanding: total, invoices: data }
    },
  })

  tools.push({
    name: 'low_stock_items',
    description: 'List inventory items at or below their reorder level (need restocking). Returns sku, name, on-hand quantity and reorder level.',
    parameters: { type: 'object', properties: {}, required: [] },
    run: async () => {
      const { data, error } = await ctx.userClient
        .from('stock_items')
        .select('sku, name, quantity, reorder_level')
        .limit(500)
      if (error) return { error: error.message }
      const low = (data || []).filter((r: any) => Number(r.quantity) <= Number(r.reorder_level))
      return { count: low.length, items: low }
    },
  })

  tools.push({
    name: 'sales_summary',
    description: 'Summarize invoiced sales over the last N days (default 30): total invoiced, total paid, and counts.',
    parameters: {
      type: 'object',
      properties: { days: { type: 'integer', description: 'Look-back window in days (default 30)' } },
      required: [],
    },
    run: async ({ days }: { days?: number }) => {
      const since = new Date(Date.now() - (days || 30) * 86400000).toISOString().split('T')[0]
      const { data, error } = await ctx.userClient
        .from('invoices')
        .select('amount, status, date')
        .gte('date', since)
        .limit(2000)
      if (error) return { error: error.message }
      const rows = data || []
      const invoiced = rows.reduce((s: number, r: any) => s + (Number(r.amount) || 0), 0)
      const paid = rows.filter((r: any) => r.status === 'paid').reduce((s: number, r: any) => s + (Number(r.amount) || 0), 0)
      return { since, invoiced_total: invoiced, paid_total: paid, invoice_count: rows.length }
    },
  })

  // ─── Document-approval workflow (read + guarded write) ───────────────────
  tools.push({
    name: 'list_document_requests',
    description:
      'List document requests visible to the user (RLS-scoped). Use before approving/rejecting so you have the exact request id and can confirm it is awaiting approval. Optionally filter by status (pending, approved, rejected, returned).',
    parameters: {
      type: 'object',
      properties: {
        status: {
          type: 'string',
          enum: ['pending', 'approved', 'rejected', 'returned'],
          description: 'Filter to one status. Omit to list the most recent across all statuses.',
        },
      },
      required: [],
    },
    run: async ({ status }: { status?: string }) => {
      let q = ctx.userClient
        .from('document_requests')
        .select('id, title, status, current_step_order, requester_id, created_at')
        .order('created_at', { ascending: false })
        .limit(50)
      if (status) q = q.eq('status', status)
      const { data, error } = await q
      if (error) return { error: error.message }
      return { count: data?.length || 0, requests: data }
    },
  })

  tools.push({
    name: 'process_document_request',
    description:
      "Advance a document request through its approval workflow. action must be one of: approve, reject, return, resubmit. This performs a REAL state change. The workflow rules are enforced server-side — you may only act on a request the user is authorized to action (the user cannot approve their own request, and must hold a role allowed at the current step); if not, this returns an error. Always call list_document_requests first to obtain the id and confirm the request is still pending. Only call this when the user has clearly asked to approve/reject/return/resubmit a specific document.",
    parameters: {
      type: 'object',
      properties: {
        document_id: { type: 'string', description: 'The document request id (UUID) from list_document_requests.' },
        action: { type: 'string', enum: ['approve', 'reject', 'return', 'resubmit'], description: 'The workflow transition to apply.' },
        comment: { type: 'string', description: 'Optional note recorded in the approval history.' },
      },
      required: ['document_id', 'action'],
    },
    run: async ({ document_id, action, comment }: { document_id: string; action: string; comment?: string }) => {
      // Routed through the SECURITY DEFINER RPC under the caller's JWT, so the
      // same role/ownership checks the UI relies on apply here unchanged.
      const { data, error } = await ctx.userClient.rpc('process_document', {
        p_doc_id: document_id,
        p_action: action,
        p_comment: comment || '',
      })
      if (error) return { error: error.message }
      return { ok: true, id: data?.id, title: data?.title, status: data?.status, current_step_order: data?.current_step_order }
    },
  })

  return tools
}
