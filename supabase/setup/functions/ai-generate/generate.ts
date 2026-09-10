// Single-shot, provider-agnostic content generation (no tool loop).
// Same three providers as ai-chat, reading whichever the silo owner configured.
// Supports an optional inline image part (vision) and a JSON-output hint, which
// is what the legacy one-off AI helpers needed.

export interface GenPart {
  text?: string
  image?: { mime: string; data: string } // base64 (no data: prefix)
}
export interface GenArgs {
  apiKey: string
  model?: string
  system: string
  parts: GenPart[]
  temperature: number
  json?: boolean // ask the model to emit JSON (best-effort per provider)
}

// ─────────────────────────────── Claude ───────────────────────────────
// Sampling parameters were REMOVED from the current Claude models. Opus 4.7
// and everything after it — Opus 4.8, Opus 5, Sonnet 5, the Fable family —
// answer any request carrying `temperature` with
//
//     400 invalid_request_error: temperature is deprecated for this model.
//
// so every one-shot helper failed outright. Depth and spend are controlled by
// `output_config.effort` on those models instead; there is no temperature
// equivalent, so the configured value is simply not sent.
//
// The list below names the models that STILL ACCEPT temperature rather than
// the ones that reject it. A rejection list would need editing every time
// Anthropic ships a model, and would fail the wrong way for anything it had
// not heard of yet — sending the parameter and breaking generation. This way
// an unknown model is assumed to be current, which is the safe default.
const CLAUDE_TAKES_TEMPERATURE = [
  'claude-opus-4-6', 'claude-sonnet-4-6', 'claude-haiku-4-5',
  'claude-opus-4-5', 'claude-sonnet-4-5', 'claude-3',
]

async function genClaude(a: GenArgs): Promise<string> {
  const content = a.parts.map((p) =>
    p.image
      ? { type: 'image', source: { type: 'base64', media_type: p.image.mime, data: p.image.data } }
      : { type: 'text', text: p.text || '' },
  )
  const model = a.model || 'claude-opus-5'
  const body: Record<string, unknown> = {
    model,
    max_tokens: 4096,
    system: a.system,
    messages: [{ role: 'user', content }],
  }
  if (CLAUDE_TAKES_TEMPERATURE.some((m) => model.startsWith(m))) body.temperature = a.temperature
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-api-key': a.apiKey, 'anthropic-version': '2023-06-01' },
    body: JSON.stringify(body),
  })
  if (!res.ok) throw new Error(`Claude error ${res.status}: ${await res.text()}`)
  const data = await res.json()
  return (data.content || []).filter((b: any) => b.type === 'text').map((b: any) => b.text).join('\n')
}

// ─────────────────────────────── OpenAI ───────────────────────────────
async function genOpenAI(a: GenArgs): Promise<string> {
  const content = a.parts.map((p) =>
    p.image
      ? { type: 'image_url', image_url: { url: `data:${p.image.mime};base64,${p.image.data}` } }
      : { type: 'text', text: p.text || '' },
  )
  const res = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${a.apiKey}` },
    body: JSON.stringify({
      model: a.model || 'gpt-4o',
      temperature: a.temperature,
      messages: [{ role: 'system', content: a.system }, { role: 'user', content }],
      ...(a.json ? { response_format: { type: 'json_object' } } : {}),
    }),
  })
  if (!res.ok) throw new Error(`OpenAI error ${res.status}: ${await res.text()}`)
  const data = await res.json()
  return data.choices?.[0]?.message?.content || ''
}

// ─────────────────────────────── Gemini ───────────────────────────────
async function genGemini(a: GenArgs): Promise<string> {
  const model = a.model || 'gemini-3-flash-preview'
  const parts = a.parts.map((p) =>
    p.image ? { inlineData: { mimeType: p.image.mime, data: p.image.data } } : { text: p.text || '' },
  )
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${a.apiKey}`,
    {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: a.system }] },
        contents: [{ role: 'user', parts }],
        generationConfig: {
          temperature: a.temperature,
          ...(a.json ? { responseMimeType: 'application/json' } : {}),
        },
      }),
    },
  )
  if (!res.ok) throw new Error(`Gemini error ${res.status}: ${await res.text()}`)
  const data = await res.json()
  return (data.candidates?.[0]?.content?.parts || []).filter((p: any) => p.text).map((p: any) => p.text).join('\n')
}

export function generate(provider: string, args: GenArgs): Promise<string> {
  if (provider === 'openai') return genOpenAI(args)
  if (provider === 'gemini') return genGemini(args)
  return genClaude(args)
}

// Strip Markdown code fences and parse JSON defensively (providers differ in how
// strictly they honour a JSON request).
export function parseJsonLoose(raw: string): unknown {
  const s = raw.replace(/```json/gi, '').replace(/```/g, '').trim()
  try {
    return JSON.parse(s)
  } catch {
    const first = s.search(/[[{]/)
    const last = Math.max(s.lastIndexOf(']'), s.lastIndexOf('}'))
    if (first >= 0 && last > first) {
      try { return JSON.parse(s.slice(first, last + 1)) } catch { /* fall through */ }
    }
    return null
  }
}
