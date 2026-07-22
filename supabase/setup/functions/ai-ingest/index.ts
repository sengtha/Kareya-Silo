// ai-ingest — turn a source document into embedded, searchable chunks.
// Accepts inline text, or a path to a file in the 'kb-sources' Storage bucket
// (text/markdown/plain). Chunks the content, embeds each chunk with Gemini,
// and writes rows to kb_chunks. Runs with the service role.
//
// NOTE: PDF/Docx extraction is intentionally out of scope here — send extracted
// text, or pre-convert. A follow-up can add a parser (e.g. unpdf) for binaries.
import { createClient } from 'npm:@supabase/supabase-js@2.39.3'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
const GEMINI_BASE = 'https://generativelanguage.googleapis.com/v1beta'

// Simple paragraph-aware chunker: ~1000 chars/chunk with ~150 char overlap.
function chunkText(text: string, size = 1000, overlap = 150): string[] {
  const clean = text.replace(/\r\n/g, '\n').trim()
  if (clean.length <= size) return clean ? [clean] : []
  const paras = clean.split(/\n{2,}/)
  const chunks: string[] = []
  let cur = ''
  for (const p of paras) {
    if ((cur + '\n\n' + p).length > size && cur) {
      chunks.push(cur.trim())
      cur = cur.slice(Math.max(0, cur.length - overlap)) + '\n\n' + p
    } else {
      cur = cur ? cur + '\n\n' + p : p
    }
    while (cur.length > size * 1.5) {
      chunks.push(cur.slice(0, size).trim())
      cur = cur.slice(size - overlap)
    }
  }
  if (cur.trim()) chunks.push(cur.trim())
  return chunks
}

async function geminiEmbed(apiKey: string, model: string, texts: string[]): Promise<number[][]> {
  const out: number[][] = []
  for (let i = 0; i < texts.length; i += 100) {
    const batch = texts.slice(i, i + 100)
    const res = await fetch(`${GEMINI_BASE}/models/${model}:batchEmbedContents?key=${apiKey}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        requests: batch.map((t) => ({ model: `models/${model}`, content: { parts: [{ text: t }] } })),
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

  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  )
  let docId: string | null = null
  try {
    const body = await req.json()
    const { title, source_type, storage_path } = body
    let text: string | undefined = body.text
    let mime = 'text/plain'

    // Resolve text from Storage if a path was provided.
    if (!text && storage_path) {
      const { data: file, error } = await admin.storage.from('kb-sources').download(storage_path)
      if (error || !file) throw new Error(`Storage download failed: ${error?.message || 'not found'}`)
      mime = file.type || 'text/plain'
      if (mime.includes('pdf') || mime.includes('officedocument') || mime.startsWith('image/')) {
        throw new Error(`Unsupported binary type for ingest: ${mime}. Send extracted text instead.`)
      }
      text = await file.text()
    }
    if (!text || !text.trim()) throw new Error('No text to ingest (provide text or a text/markdown storage_path)')

    // Create the document record.
    const { data: doc, error: docErr } = await admin.from('kb_documents').insert({
      title: title || storage_path || 'Untitled',
      source_type: source_type || (storage_path ? 'file' : 'note'),
      source_ref: storage_path || null,
      mime_type: mime,
      status: 'processing',
    }).select('id').single()
    if (docErr || !doc) throw new Error(`Failed to create document: ${docErr?.message}`)
    docId = doc.id

    // Chunk + embed + insert.
    const chunks = chunkText(text)
    if (chunks.length === 0) throw new Error('Document produced no chunks')

    const { data: cfg } = await admin.from('ai_config').select('embedding_model').eq('id', true).maybeSingle()
    const model = cfg?.embedding_model || 'text-embedding-004'
    const { data: key } = await admin.rpc('ai_get_secret', { p_kind: 'embedding' })
    if (!key) throw new Error('No Gemini embedding key configured')

    const vectors = await geminiEmbed(String(key), model, chunks)
    const rows = chunks.map((content, i) => ({
      document_id: docId,
      chunk_index: i,
      content,
      token_count: Math.round(content.length / 4),
      embedding: vectors[i] as unknown as number[],
    }))
    const { error: insErr } = await admin.from('kb_chunks').insert(rows)
    if (insErr) throw new Error(`Failed to insert chunks: ${insErr.message}`)

    await admin.from('kb_documents').update({
      status: 'indexed', chunk_count: chunks.length, indexed_at: new Date().toISOString(), error: null,
    }).eq('id', docId)

    return new Response(JSON.stringify({ document_id: docId, chunks: chunks.length }), {
      status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (error) {
    const msg = String((error as Error).message || error)
    console.error('ai-ingest error:', msg)
    if (docId) await admin.from('kb_documents').update({ status: 'failed', error: msg }).eq('id', docId)
    return new Response(JSON.stringify({ error: msg }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
