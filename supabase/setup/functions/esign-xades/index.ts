// esign-xades — wrap a UBL invoice in an enveloped XMLDSig / XAdES-BES
// signature using the workspace's configured X.509 certificate.
//
// The private key lives ONLY in Supabase Vault; this function (service role)
// fetches it via esign_get_key(), which anon/authenticated cannot execute.
// The caller must be a logged-in employee: we verify by reading esign_config
// under the CALLER's JWT (RLS: is_employee()) before touching the key.
//
// ── Scope, honestly stated ────────────────────────────────────────────────
// This produces a structurally valid XAdES-BES enveloped signature
// (RSA-SHA256). Two deliberate simplifications, documented for the day GDT
// enforces signing:
//  1. Canonicalization: the input XML is treated as already canonical. That
//     holds because the Hub's ubl.ts generates it deterministically and it is
//     signed byte-for-byte as received — but a third-party validator that
//     re-canonicalizes (C14N) whitespace-shifted copies may compute a
//     different digest. Keep the signed file as the artifact of record.
//  2. Legal weight: with a self-provided certificate this is an "advanced"
//     structure without a qualified CA chain. For CamInvoice/legal validity,
//     load a certificate issued via CamDigiKey / an accredited CA — the code
//     path is identical.
//
// POST { xml: string }  →  { signedXml: string }
import { createClient } from 'npm:@supabase/supabase-js@2.39.3'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })

const b64 = (buf: ArrayBuffer): string => {
  const bytes = new Uint8Array(buf)
  let s = ''
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(s)
}
const pemBody = (pem: string): Uint8Array => {
  const clean = pem.replace(/-----(BEGIN|END)[^-]+-----/g, '').replace(/\s+/g, '')
  const bin = atob(clean)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}
const sha256b64 = async (data: Uint8Array): Promise<string> => b64(await crypto.subtle.digest('SHA-256', data))
const enc = new TextEncoder()

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  let body: any
  try { body = await req.json() } catch { return json({ error: 'Invalid body' }, 400) }
  const xml: string = body?.xml
  if (!xml || typeof xml !== 'string' || xml.length > 2_000_000) return json({ error: 'xml (string, <2MB) is required' }, 400)

  // 1. Caller must be an employee of this silo (RLS-checked read).
  const authHeader = req.headers.get('Authorization') || ''
  const caller = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authHeader } }, auth: { persistSession: false },
  })
  const { data: cfg, error: cfgErr } = await caller.from('esign_config').select('cert_pem, cert_subject').maybeSingle()
  if (cfgErr) return json({ error: 'Unauthorized' }, 401)
  if (!cfg?.cert_pem) return json({ error: 'No signing certificate configured. Add one in Settings → E-Signature.' }, 409)

  // 2. Fetch the private key (service role only).
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })
  const { data: keyPem, error: keyErr } = await admin.rpc('esign_get_key')
  if (keyErr || !keyPem) return json({ error: 'Signing key unavailable' }, 409)

  let privateKey: CryptoKey
  try {
    privateKey = await crypto.subtle.importKey(
      'pkcs8', pemBody(keyPem), { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'],
    )
  } catch {
    return json({ error: 'Private key is not a valid PKCS#8 RSA key (convert with: openssl pkcs8 -topk8 -nocrypt)' }, 400)
  }

  try {
    const certDer = pemBody(cfg.cert_pem)
    const certB64 = b64(certDer.buffer as ArrayBuffer)
    const certDigest = await sha256b64(certDer)
    const sigId = `SIG-${crypto.randomUUID()}`
    const spId = `${sigId}-SignedProperties`
    const now = new Date().toISOString()

    // Reference 1: the document itself (enveloped — the Signature element we
    // are about to insert is excluded by definition of the transform).
    const docDigest = await sha256b64(enc.encode(xml))

    // XAdES SignedProperties (BES profile: signing time + signing cert digest).
    const signedProps =
      `<xades:SignedProperties xmlns:xades="http://uri.etsi.org/01903/v1.3.2#" xmlns:ds="http://www.w3.org/2000/09/xmldsig#" Id="${spId}">` +
      `<xades:SignedSignatureProperties>` +
      `<xades:SigningTime>${now}</xades:SigningTime>` +
      `<xades:SigningCertificate><xades:Cert>` +
      `<xades:CertDigest><ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/><ds:DigestValue>${certDigest}</ds:DigestValue></xades:CertDigest>` +
      `<xades:IssuerSerial><ds:X509IssuerName>${(cfg.cert_subject || 'Unknown').replace(/[<>&]/g, '')}</ds:X509IssuerName><ds:X509SerialNumber>0</ds:X509SerialNumber></xades:IssuerSerial>` +
      `</xades:Cert></xades:SigningCertificate>` +
      `</xades:SignedSignatureProperties></xades:SignedProperties>`
    const spDigest = await sha256b64(enc.encode(signedProps))

    const signedInfo =
      `<ds:SignedInfo xmlns:ds="http://www.w3.org/2000/09/xmldsig#">` +
      `<ds:CanonicalizationMethod Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/>` +
      `<ds:SignatureMethod Algorithm="http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"/>` +
      `<ds:Reference Id="${sigId}-ref0" URI="">` +
      `<ds:Transforms><ds:Transform Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature"/></ds:Transforms>` +
      `<ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/><ds:DigestValue>${docDigest}</ds:DigestValue></ds:Reference>` +
      `<ds:Reference Type="http://uri.etsi.org/01903#SignedProperties" URI="#${spId}">` +
      `<ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/><ds:DigestValue>${spDigest}</ds:DigestValue></ds:Reference>` +
      `</ds:SignedInfo>`

    const sigValue = b64(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', privateKey, enc.encode(signedInfo)))

    const signature =
      `<ds:Signature xmlns:ds="http://www.w3.org/2000/09/xmldsig#" Id="${sigId}">` +
      signedInfo +
      `<ds:SignatureValue>${sigValue}</ds:SignatureValue>` +
      `<ds:KeyInfo><ds:X509Data><ds:X509Certificate>${certB64}</ds:X509Certificate></ds:X509Data></ds:KeyInfo>` +
      `<ds:Object><xades:QualifyingProperties xmlns:xades="http://uri.etsi.org/01903/v1.3.2#" Target="#${sigId}">` +
      signedProps.replace(' xmlns:xades="http://uri.etsi.org/01903/v1.3.2#" xmlns:ds="http://www.w3.org/2000/09/xmldsig#"', '') +
      `</xades:QualifyingProperties></ds:Object>` +
      `</ds:Signature>`

    // Insert the signature just before the closing root tag.
    const closeIdx = xml.lastIndexOf('</')
    if (closeIdx < 0) return json({ error: 'Input is not well-formed XML' }, 400)
    const signedXml = xml.slice(0, closeIdx) + signature + xml.slice(closeIdx)

    return json({ signedXml })
  } catch (e) {
    console.error('XAdES signing failure:', e)
    return json({ error: 'Signing failed' }, 500)
  }
})
