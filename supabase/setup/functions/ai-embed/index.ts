// ai-embed — produce embeddings for one or more texts using Gemini.
// Embeddings are ALWAYS Gemini (a vector store must use one embedding model,
// and Anthropic has no embeddings API). The Gemini key is read from Vault via
// the service-role-only ai_get_secret RPC — never from a static env var.
import { createClient } from 'npm:@supabase/supabase-js@2.39.3'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const GEMINI_BASE = 'https://generativelanguage.googleapis.com/v1beta'

async function geminiEmbed(apiKey: string, model: string, texts: string[]): Promise<number[][]> {
  // batchEmbedContents embeds up to 100 texts in one call.
  const out: number[][] = []
  for (let i = 0; i < texts.length; i += 100) {
    const batch = texts.slice(i, i + 100)
    const res = await fetch(`${GEMINI_BASE}/models/${model}:batchEmbedContents?key=${apiKey}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        requests: batch.map((t) => ({
          model: `models/${model}`,
          content: { parts: [{ text: t }] },
        })),
      }),
    })
    if (!res.ok) throw new Error(`Gemini embed failed: ${res.status} ${await res.text()}`)
    const data = await res.json()
    for (const e of data.embeddings || []) out.push(e.values)
  }
  return out
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  try {
    const { texts } = await req.json()
    if (!Array.isArray(texts) || texts.length === 0) {
      return new Response(JSON.stringify({ error: 'texts[] required' }), { status: 400, headers: corsHeaders })
    }

    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false } },
    )
    const { data: cfg } = await admin.from('ai_config').select('embedding_model').eq('id', true).maybeSingle()
    const model = cfg?.embedding_model || 'text-embedding-004'
    const { data: key } = await admin.rpc('ai_get_secret', { p_kind: 'embedding' })
    if (!key) return new Response(JSON.stringify({ error: 'No Gemini embedding key configured' }), { status: 400, headers: corsHeaders })

    const embeddings = await geminiEmbed(String(key), model, texts.map(String))
    return new Response(JSON.stringify({ embeddings, model }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (error) {
    console.error('ai-embed error:', error)
    return new Response(JSON.stringify({ error: String((error as Error).message || error) }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
