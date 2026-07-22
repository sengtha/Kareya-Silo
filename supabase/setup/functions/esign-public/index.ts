// esign-public — external e-signature endpoint (no login required).
//
// A signature_request created with signer_kind='external' carries an
// unguessable public_token. This function serves a minimal signing page for
// that token (GET) and records the signature (POST). It runs with the service
// role — RLS does not apply — so IT is the gatekeeper: it only ever exposes a
// request looked up by exact token, only while status='pending' and not
// expired, and it writes exactly one signature then flips the request to
// 'signed'. Deploy with --no-verify-jwt (config: verify_jwt = false).
//
// GET  ?token=...          → HTML signing page (title, hash, pad, consent)
// POST { token, signerName, signatureKind, signatureImage?, typedName? }
//      → { ok: true } and the request becomes 'signed'.
import { createClient } from 'npm:@supabase/supabase-js@2.39.3'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })

const esc = (s: string) => s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string))

const admin = () => createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  { auth: { persistSession: false } },
)

async function loadRequest(token: string) {
  if (!token || token.length < 20) return null
  const { data } = await admin().from('signature_requests').select('*').eq('public_token', token).maybeSingle()
  if (!data) return null
  if (data.status !== 'pending') return { ...data, _closed: true }
  if (data.expires_at && new Date(data.expires_at) < new Date()) {
    await admin().from('signature_requests').update({ status: 'expired' }).eq('id', data.id)
    return { ...data, status: 'expired', _closed: true }
  }
  return data
}

// The signing page is deliberately dependency-free inline HTML: a canvas pad
// with a typed-name fallback, the content hash shown to the signer, and an
// explicit consent checkbox. It POSTs back to this same function.
function page(req: any): string {
  const closed = req._closed
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sign: ${esc(req.title)}</title>
<style>
  body{font-family:system-ui,sans-serif;background:#f8fafc;color:#0f172a;margin:0;padding:24px;display:flex;justify-content:center}
  .card{background:#fff;border:1px solid #e2e8f0;border-radius:20px;padding:28px;max-width:520px;width:100%;box-shadow:0 4px 20px rgba(0,0,0,.05)}
  h1{font-size:19px;margin:0 0 4px}.muted{color:#64748b;font-size:13px}
  .hash{font-family:monospace;font-size:11px;word-break:break-all;background:#f1f5f9;border-radius:8px;padding:8px;margin:12px 0}
  canvas{border:1.5px dashed #cbd5e1;border-radius:12px;width:100%;height:160px;touch-action:none;background:#fff}
  input[type=text]{width:100%;box-sizing:border-box;padding:10px;border:1px solid #cbd5e1;border-radius:10px;font-size:14px;margin-top:6px}
  button{background:#0d9488;color:#fff;border:0;border-radius:12px;padding:12px 20px;font-weight:800;font-size:14px;cursor:pointer;width:100%;margin-top:14px}
  button:disabled{opacity:.5;cursor:not-allowed}.row{display:flex;gap:8px;align-items:center;margin-top:12px;font-size:13px}
  .clear{background:none;border:0;color:#0d9488;font-size:12px;font-weight:700;cursor:pointer;padding:4px;width:auto;margin:4px 0 0}
  .done{color:#059669;font-weight:800;text-align:center;padding:30px 0}
</style></head><body><div class="card">
<h1>${esc(req.title)}</h1>
<p class="muted">Requested by the business${req.signer_name ? ` for <b>${esc(req.signer_name)}</b>` : ''}. Signing below constitutes your electronic signature on the content identified by this fingerprint:</p>
<div class="hash">SHA-256 · ${esc(req.content_hash)}</div>
${closed ? `<p class="done">This request is ${esc(req.status)} — no further signature can be recorded.</p>` : `
<label class="muted" style="font-weight:700">Your full name</label>
<input type="text" id="name" value="${esc(req.signer_name || '')}" placeholder="Full legal name">
<p class="muted" style="font-weight:700;margin:14px 0 6px">Draw your signature</p>
<canvas id="pad"></canvas><button class="clear" onclick="clearPad()">Clear</button>
<div class="row"><input type="checkbox" id="consent" style="width:auto"><label for="consent">I agree that this constitutes my legally binding electronic signature.</label></div>
<button id="go" onclick="sign()">Sign now</button>
<p class="muted" id="msg"></p>
<script>
const cv=document.getElementById('pad');const cx=cv.getContext('2d');let drew=false;
function fit(){const r=cv.getBoundingClientRect();cv.width=r.width*2;cv.height=r.height*2;cx.scale(2,2);cx.lineWidth=2;cx.lineCap='round';cx.strokeStyle='#0f172a'}fit();
let d=false,lx=0,ly=0;const P=e=>{const r=cv.getBoundingClientRect();const t=e.touches?e.touches[0]:e;return[t.clientX-r.left,t.clientY-r.top]};
const S=e=>{d=true;[lx,ly]=P(e);e.preventDefault()};const M=e=>{if(!d)return;const[x,y]=P(e);cx.beginPath();cx.moveTo(lx,ly);cx.lineTo(x,y);cx.stroke();lx=x;ly=y;drew=true;e.preventDefault()};const E=()=>{d=false};
cv.addEventListener('mousedown',S);cv.addEventListener('mousemove',M);addEventListener('mouseup',E);
cv.addEventListener('touchstart',S,{passive:false});cv.addEventListener('touchmove',M,{passive:false});cv.addEventListener('touchend',E);
function clearPad(){cx.clearRect(0,0,cv.width,cv.height);drew=false}
async function sign(){
  const name=document.getElementById('name').value.trim();const msg=document.getElementById('msg');
  if(!name){msg.textContent='Please enter your full name.';return}
  if(!document.getElementById('consent').checked){msg.textContent='Please tick the consent box.';return}
  if(!drew){msg.textContent='Please draw your signature.';return}
  document.getElementById('go').disabled=true;msg.textContent='Recording signature…';
  const res=await fetch(location.pathname,{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({token:new URLSearchParams(location.search).get('token'),signerName:name,signatureKind:'drawn',signatureImage:cv.toDataURL('image/png')})});
  if(res.ok){document.querySelector('.card').innerHTML='<p class="done">✓ Signed. You can close this page.</p>'}
  else{const b=await res.json().catch(()=>({}));msg.textContent=b.error||'Failed — please try again.';document.getElementById('go').disabled=false}
}
</script>`}
</div></body></html>`
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  if (req.method === 'GET') {
    const token = new URL(req.url).searchParams.get('token') || ''
    const r = await loadRequest(token)
    if (!r) return new Response('Not found', { status: 404, headers: corsHeaders })
    return new Response(page(r), { headers: { ...corsHeaders, 'Content-Type': 'text/html; charset=utf-8' } })
  }

  if (req.method === 'POST') {
    let body: any
    try { body = await req.json() } catch { return json({ error: 'Invalid body' }, 400) }
    const { token, signerName, signatureKind, signatureImage, typedName } = body || {}
    if (!token || !signerName) return json({ error: 'token and signerName are required' }, 400)
    if (typeof signatureImage === 'string' && signatureImage.length > 400_000) return json({ error: 'Signature image too large' }, 400)

    const r = await loadRequest(String(token))
    if (!r) return json({ error: 'Unknown or invalid link' }, 404)
    if (r._closed) return json({ error: `This request is ${r.status}` }, 409)

    const db = admin()
    const { error: sigErr } = await db.from('signatures').insert({
      request_id: r.id,
      signer_name: String(signerName).slice(0, 200),
      signer_identity: r.signer_email || r.signer_phone || 'external',
      signature_kind: signatureKind === 'typed' ? 'typed' : 'drawn',
      signature_image: signatureKind === 'typed' ? null : (signatureImage || null),
      typed_name: signatureKind === 'typed' ? String(typedName || signerName).slice(0, 200) : null,
      content_hash: r.content_hash,
      ip_address: req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() || null,
      user_agent: (req.headers.get('user-agent') || '').slice(0, 300) || null,
    })
    if (sigErr) return json({ error: 'Failed to record signature' }, 500)
    await db.from('signature_requests').update({ status: 'signed', signed_at: new Date().toISOString() }).eq('id', r.id)
    return json({ ok: true })
  }

  return json({ error: 'Method not allowed' }, 405)
})
