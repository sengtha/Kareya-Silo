// Provider adapters. Each takes the same normalized inputs and returns
// { reply, toolsUsed }, running its own tool-call loop in the provider's native
// wire format. Non-streaming (single JSON out).
import type { ToolDef } from './tools.ts'

export interface ChatMsg { role: 'user' | 'assistant'; content: string }
export interface RunArgs {
  apiKey: string
  model: string
  system: string
  messages: ChatMsg[]
  tools: ToolDef[]
  temperature: number
  maxRounds?: number
}
export interface RunResult { reply: string; toolsUsed: string[] }

const byName = (tools: ToolDef[]) => Object.fromEntries(tools.map((t) => [t.name, t]))

// ─────────────────────────────── Claude ───────────────────────────────
export async function runClaude(a: RunArgs): Promise<RunResult> {
  const reg = byName(a.tools)
  const used: string[] = []
  const messages: any[] = a.messages.map((m) => ({ role: m.role, content: m.content }))
  const toolDefs = a.tools.map((t) => ({ name: t.name, description: t.description, input_schema: t.parameters }))

  for (let round = 0; round < (a.maxRounds || 5); round++) {
    const res = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-api-key': a.apiKey, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({
        model: a.model || 'claude-opus-4-8',
        max_tokens: 2048,
        system: a.system,
        messages,
        ...(toolDefs.length ? { tools: toolDefs } : {}),
      }),
    })
    if (!res.ok) throw new Error(`Claude error ${res.status}: ${await res.text()}`)
    const data = await res.json()
    messages.push({ role: 'assistant', content: data.content })

    if (data.stop_reason === 'tool_use') {
      const results: any[] = []
      for (const block of data.content) {
        if (block.type === 'tool_use') {
          used.push(block.name)
          let out: unknown
          try { out = reg[block.name] ? await reg[block.name].run(block.input) : { error: 'unknown tool' } }
          catch (e) { out = { error: String((e as Error).message) } }
          results.push({ type: 'tool_result', tool_use_id: block.id, content: JSON.stringify(out) })
        }
      }
      messages.push({ role: 'user', content: results })
      continue
    }
    const text = (data.content || []).filter((b: any) => b.type === 'text').map((b: any) => b.text).join('\n')
    return { reply: text, toolsUsed: used }
  }
  return { reply: "I wasn't able to finish that within the tool-call limit.", toolsUsed: used }
}

// ─────────────────────────────── OpenAI ───────────────────────────────
export async function runOpenAI(a: RunArgs): Promise<RunResult> {
  const reg = byName(a.tools)
  const used: string[] = []
  const messages: any[] = [{ role: 'system', content: a.system }, ...a.messages]
  const toolDefs = a.tools.map((t) => ({ type: 'function', function: { name: t.name, description: t.description, parameters: t.parameters } }))

  for (let round = 0; round < (a.maxRounds || 5); round++) {
    const res = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${a.apiKey}` },
      body: JSON.stringify({
        model: a.model || 'gpt-4o',
        temperature: a.temperature,
        messages,
        ...(toolDefs.length ? { tools: toolDefs } : {}),
      }),
    })
    if (!res.ok) throw new Error(`OpenAI error ${res.status}: ${await res.text()}`)
    const data = await res.json()
    const msg = data.choices?.[0]?.message
    messages.push(msg)

    if (msg?.tool_calls?.length) {
      for (const call of msg.tool_calls) {
        used.push(call.function.name)
        let out: unknown
        try {
          const args = call.function.arguments ? JSON.parse(call.function.arguments) : {}
          out = reg[call.function.name] ? await reg[call.function.name].run(args) : { error: 'unknown tool' }
        } catch (e) { out = { error: String((e as Error).message) } }
        messages.push({ role: 'tool', tool_call_id: call.id, content: JSON.stringify(out) })
      }
      continue
    }
    return { reply: msg?.content || '', toolsUsed: used }
  }
  return { reply: "I wasn't able to finish that within the tool-call limit.", toolsUsed: used }
}

// ─────────────────────────────── Gemini ───────────────────────────────
export async function runGemini(a: RunArgs): Promise<RunResult> {
  const reg = byName(a.tools)
  const used: string[] = []
  const model = a.model || 'gemini-3-flash-preview'
  const contents: any[] = a.messages.map((m) => ({ role: m.role === 'assistant' ? 'model' : 'user', parts: [{ text: m.content }] }))
  const toolDecls = a.tools.length
    ? [{ functionDeclarations: a.tools.map((t) => ({ name: t.name, description: t.description, parameters: t.parameters })) }]
    : undefined

  for (let round = 0; round < (a.maxRounds || 5); round++) {
    const res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${a.apiKey}`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: a.system }] },
          contents,
          ...(toolDecls ? { tools: toolDecls } : {}),
          generationConfig: { temperature: a.temperature },
        }),
      },
    )
    if (!res.ok) throw new Error(`Gemini error ${res.status}: ${await res.text()}`)
    const data = await res.json()
    const parts = data.candidates?.[0]?.content?.parts || []
    contents.push({ role: 'model', parts })

    const calls = parts.filter((p: any) => p.functionCall)
    if (calls.length) {
      const responses: any[] = []
      for (const p of calls) {
        const fc = p.functionCall
        used.push(fc.name)
        let out: unknown
        try { out = reg[fc.name] ? await reg[fc.name].run(fc.args || {}) : { error: 'unknown tool' } }
        catch (e) { out = { error: String((e as Error).message) } }
        responses.push({ functionResponse: { name: fc.name, response: { result: out } } })
      }
      contents.push({ role: 'user', parts: responses })
      continue
    }
    const text = parts.filter((p: any) => p.text).map((p: any) => p.text).join('\n')
    return { reply: text, toolsUsed: used }
  }
  return { reply: "I wasn't able to finish that within the tool-call limit.", toolsUsed: used }
}

export function runProvider(provider: string, args: RunArgs): Promise<RunResult> {
  if (provider === 'openai') return runOpenAI(args)
  if (provider === 'gemini') return runGemini(args)
  return runClaude(args)
}
