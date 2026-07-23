// ai-generate — one-shot AI helpers (text, doc templates, holiday OCR, job
// descriptions, schedule briefings). Replaces the legacy `gemini-ai` function.
//
// Why this exists: the old function used a single shared GEMINI_API_KEY env
// secret. This one uses the per-silo, owner-configured provider + Vault key
// (the same model the rest of the AI feature uses), and requires a signed-in
// caller. Provider/key are read with the service role ONLY to talk to the
// upstream API; the caller's JWT is verified first so anonymous callers are
// rejected. Output shape is unchanged: { text } or { holidays }.
import { createClient } from 'npm:@supabase/supabase-js@2.39.3'
import { generate, parseJsonLoose, type GenPart } from './generate.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  try {
    const authHeader = req.headers.get('Authorization') || ''
    if (!authHeader) return json({ error: 'Missing authorization' }, 401)

    const url = Deno.env.get('SUPABASE_URL')!
    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
    const userClient = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      auth: { persistSession: false },
      global: { headers: { Authorization: authHeader } },
    })

    // Reject anonymous callers (legacy function had no auth at all).
    const { data: userData, error: userErr } = await userClient.auth.getUser()
    if (userErr || !userData?.user) return json({ error: 'Not authenticated' }, 401)

    const { action, prompt, context, type, imageBase64, year, mimeType, title, dept, eventsJson } = await req.json()

    // Provider + key from the silo's config (service role reads Vault).
    const { data: cfg } = await admin.from('ai_config').select('*').eq('id', true).maybeSingle()
    if (!cfg || !cfg.enabled) return json({ error: 'The AI assistant is not enabled for this workspace.' }, 400)
    const { data: chatKey } = await admin.rpc('ai_get_secret', { p_kind: 'chat' })
    if (!chatKey) return json({ error: 'No API key configured for the selected AI provider.' }, 400)

    const provider = cfg.chat_provider || 'claude'
    const model = cfg.chat_model || undefined
    const apiKey = String(chatKey)
    const temperature = Number(cfg.temperature ?? 0.4)

    // Map the requested action onto a system prompt + user parts.
    let system = ''
    let parts: GenPart[] = []
    let wantJson = false

    switch (action) {
      case 'generate-text': {
        if (type === 'template') {
          system = 'You are a professional document architect. Convert descriptions into clean Markdown, optimized for readability. Return raw Markdown only.'
        } else if (type === 'html_content') {
          system = 'You are an expert copywriter. Generate rich Markdown content, structured logically with headers and lists. Return raw Markdown only.'
        } else {
          system = `You are KAREYA, an intelligent AI office manager. Tone: professional, concise, helpful. Context: ${context || ''}`
        }
        parts = [{ text: prompt || '' }]
        break
      }
      case 'generate-template-image': {
        system = 'You convert document images into reusable templates. Return ONLY the HTML string, no commentary or code fences.'
        parts = [
          { image: { mime: mimeType || 'image/png', data: imageBase64 } },
          { text: 'Replicate this document layout in HTML using inline Tailwind CSS. Use placeholders like {{companyName}}, {{date}}, {{items}}, and {{total}}. Return ONLY the HTML string.' },
        ]
        break
      }
      case 'extract-holidays': {
        system = 'You extract structured data from images and return strictly valid JSON with no surrounding text.'
        parts = [
          { image: { mime: mimeType || 'image/png', data: imageBase64 } },
          { text: `Identify all public holidays for ${year} from this image. For each, extract the name and the date in YYYY-MM-DD format. Return STRICTLY a JSON array of objects with keys "name" and "date". No other text.` },
        ]
        wantJson = true
        break
      }
      case 'generate-job-desc': {
        system = 'You are an expert HR copywriter.'
        parts = [{ text: `Write a professional job description for "${title}" in the "${dept}" department. Include a role summary, responsibilities, and key requirements. Return Markdown.` }]
        break
      }
      case 'summarize-schedule': {
        system = 'You write friendly, natural spoken-word briefings suitable for a text-to-speech engine.'
        parts = [{ text: `Summarize the following schedule as a friendly morning briefing: ${eventsJson}` }]
        break
      }
      case 'recommend-modules': {
        // Setup Advisor: map a business description to relevant Kareya modules.
        // The authoritative catalog is passed in `context` (built by the Hub, so
        // it stays versioned with the app); the model MUST only choose ids from
        // it — it cannot invent features. Returns strict JSON.
        system = `You are the Kareya Setup Advisor, helping a Cambodian small-business owner pick which Kareya ERP modules to turn on. You are given a CATALOG of available modules (id + what each does). Recommend ONLY the modules that fit the described business, using ONLY ids present in the catalog — never invent an id. Prefer a lean set: the essentials plus the clear industry fit. Reply STRICTLY as JSON: {"modules":[{"id":"<catalog id>","reason":"<one short sentence, plain language>"}],"summary":"<one friendly sentence to the owner>","followUp":"<one optional question to refine, or empty>"}. No prose outside the JSON.`
        parts = [{ text: `CATALOG:\n${context || ''}\n\nBUSINESS:\n${prompt || ''}` }]
        wantJson = true
        break
      }
      default:
        return json({ error: 'Invalid action' }, 400)
    }

    const raw = await generate(provider, { apiKey, model, system, parts, temperature, json: wantJson })

    if (action === 'extract-holidays') {
      const parsed = parseJsonLoose(raw)
      const holidays = Array.isArray(parsed) ? parsed : Array.isArray((parsed as any)?.holidays) ? (parsed as any).holidays : []
      return json({ holidays })
    }
    if (action === 'generate-template-image') {
      return json({ text: raw.replace(/```html/gi, '').replace(/```/g, '').trim() })
    }
    if (action === 'recommend-modules') {
      const parsed = parseJsonLoose(raw) as any
      const modules = Array.isArray(parsed?.modules) ? parsed.modules : []
      return json({ modules, summary: parsed?.summary || '', followUp: parsed?.followUp || '' })
    }
    return json({ text: raw })
  } catch (error) {
    console.error('ai-generate error:', error)
    return json({ error: String((error as Error).message || error) }, 500)
  }
})
