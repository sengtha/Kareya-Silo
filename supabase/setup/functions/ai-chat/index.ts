// ai-chat — the silo assistant. Single-JSON (non-streaming).
//
// Security model:
//  • adminClient (service role) is used ONLY to read ai_config and decrypt the
//    provider/embedding keys from Vault (ai_get_secret).
//  • userClient carries the CALLER's JWT, so every tool query and the RAG
//    retrieval run under that user's RLS — the assistant can never see or do
//    anything the user couldn't. This is what keeps it from being a bypass.
import { createClient } from 'npm:@supabase/supabase-js@2.39.3'
import { buildTools } from './tools.ts'
import { runProvider, type ChatMsg } from './providers.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
const GEMINI_BASE = 'https://generativelanguage.googleapis.com/v1beta'

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  try {
    const authHeader = req.headers.get('Authorization') || ''
    if (!authHeader) return new Response(JSON.stringify({ error: 'Missing authorization' }), { status: 401, headers: corsHeaders })

    const { messages } = await req.json() as { messages: ChatMsg[] }
    if (!Array.isArray(messages) || messages.length === 0) {
      return new Response(JSON.stringify({ error: 'messages[] required' }), { status: 400, headers: corsHeaders })
    }

    const url = Deno.env.get('SUPABASE_URL')!
    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
    // RLS-scoped client — every tool/RAG call runs as the caller.
    const userClient = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      auth: { persistSession: false },
      global: { headers: { Authorization: authHeader } },
    })

    // Config + keys (service role only).
    const { data: cfg } = await admin.from('ai_config').select('*').eq('id', true).maybeSingle()
    if (!cfg || !cfg.enabled) {
      return new Response(JSON.stringify({ error: 'The AI assistant is not enabled for this workspace.' }), { status: 400, headers: corsHeaders })
    }
    const { data: chatKey } = await admin.rpc('ai_get_secret', { p_kind: 'chat' })
    if (!chatKey) {
      return new Response(JSON.stringify({ error: 'No API key configured for the selected AI provider.' }), { status: 400, headers: corsHeaders })
    }

    // Optional Gemini embed closure for RAG (only if a Gemini embedding key exists).
    let embed: ((t: string) => Promise<number[]>) | null = null
    const ragEnabled = !!cfg.rag_enabled
    if (ragEnabled) {
      const { data: embKey } = await admin.rpc('ai_get_secret', { p_kind: 'embedding' })
      if (embKey) {
        const model = cfg.embedding_model || 'text-embedding-004'
        embed = async (text: string) => {
          const r = await fetch(`${GEMINI_BASE}/models/${model}:embedContent?key=${embKey}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ model: `models/${model}`, content: { parts: [{ text }] } }),
          })
          if (!r.ok) throw new Error(`Gemini embed failed: ${r.status}`)
          const d = await r.json()
          return d.embedding.values as number[]
        }
      }
    }

    const tools = buildTools({ userClient, embed, ragEnabled, writeEnabled: !!cfg.tools_write_enabled })

    const system =
      (cfg.system_prompt && cfg.system_prompt.trim()) ||
      'You are Kareya, a helpful business assistant embedded in this company\'s ERP. ' +
      'Answer using the available tools to look up real data before responding. ' +
      'Be concise and accurate. If a tool returns no data, say so plainly. ' +
      'Only reference information the tools return — never invent figures.'

    // Appended to whatever prompt the owner wrote, because it describes how the
    // tools behave rather than how the assistant should sound. An owner editing
    // the tone must not be able to delete it by accident.
    const writeRule = cfg.tools_write_enabled
      ? ' Any action that changes something is PROPOSED, not performed: it goes into an approval queue. '
        + 'When a tool replies with state "pending", say it is waiting for approval. Only say it is done '
        + 'when the reply says "applied". Never describe a pending action as completed.'
      : ''

    const result = await runProvider(cfg.chat_provider, {
      apiKey: String(chatKey),
      model: cfg.chat_model,
      system: system + writeRule,
      messages,
      tools,
      temperature: Number(cfg.temperature ?? 0.4),
      maxRounds: 5,
    })

    return new Response(JSON.stringify({
      reply: result.reply,
      tools_used: result.toolsUsed,
      provider: cfg.chat_provider,
    }), { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  } catch (error) {
    console.error('ai-chat error:', error)
    return new Response(JSON.stringify({ error: String((error as Error).message || error) }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
