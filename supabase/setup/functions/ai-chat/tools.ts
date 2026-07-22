// Normalized tool registry for the assistant. Every tool executes against the
// caller's RLS-scoped Supabase client (userClient) or the RAG search RPC, so
// the assistant can never read data the user couldn't read themselves.
//
// All tools here are READ-ONLY. Write tools (create invoice, approve document…)
// should be added the same way but routed through the existing RPCs.

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

  return tools
}
