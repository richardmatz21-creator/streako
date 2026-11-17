// =====================================================================
// Streako – Edge Function "push"
// Supabase > Edge Functions > Deploy a new function > Via Editor
// Name: push  ·  diesen ganzen Code einfügen  ·  Deploy
// Danach in den Function-Einstellungen "Verify JWT" AUSSCHALTEN
// (die Funktion prüft den Login selbst, und die Abend-Erinnerung hat keinen Login).
//
// Secrets (Edge Functions > Secrets): VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, CRON_SECRET
// Optional: REMINDER_HOURS (Standard "19", z. B. "19,21"), VAPID_SUBJECT
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const env = (k: string) => Deno.env.get(k) ?? '';
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

function serviceKey(): string {
  const k = env('SUPABASE_SERVICE_ROLE_KEY');
  if (k) return k;
  try { const j = JSON.parse(env('SUPABASE_SECRET_KEYS')); return j.default ?? Object.values(j)[0]; } catch { return ''; }
}
const admin = createClient(env('SUPABASE_URL'), serviceKey(), { auth: { persistSession: false, autoRefreshToken: false } });

// --- webpush start (reines JavaScript + WebCrypto, RFC 8291 / RFC 8292) ---
const te = new TextEncoder();
const b64uEnc = (buf) => {
  const b = new Uint8Array(buf); let s = '';
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};
const b64uDec = (str) => {
  const s = str.replace(/-/g, '+').replace(/_/g, '/');
  const bin = atob(s + '==='.slice((s.length + 3) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
};
const concat = (...arrs) => {
  const out = new Uint8Array(arrs.reduce((n, a) => n + a.length, 0)); let o = 0;
  for (const a of arrs) { out.set(a, o); o += a.length; }
  return out;
};
async function hmac(key, data) {
  const k = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, data));
}
// Verschlüsselt eine Nachricht für ein Browser-Abo (aes128gcm).
// test: { asPrivateJwk, salt } nur für Testvektoren.
async function encryptPayload(p256dh, authSecret, plaintext, test) {
  const uaPublic = b64uDec(p256dh);
  const auth = b64uDec(authSecret);
  let asPriv, asPublic;
  if (test) {
    asPriv = await crypto.subtle.importKey('jwk', test.asPrivateJwk, { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
    asPublic = concat(new Uint8Array([4]), b64uDec(test.asPrivateJwk.x), b64uDec(test.asPrivateJwk.y));
  } else {
    const kp = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
    asPriv = kp.privateKey;
    asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', kp.publicKey));
  }
  const uaKey = await crypto.subtle.importKey('raw', uaPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, asPriv, 256));
  const prkKey = await hmac(auth, ecdh);
  const ikm = await hmac(prkKey, concat(te.encode('WebPush: info\0'), uaPublic, asPublic, new Uint8Array([1])));
  const salt = test ? b64uDec(test.salt) : crypto.getRandomValues(new Uint8Array(16));
  const prk = await hmac(salt, ikm);
  const cek = (await hmac(prk, concat(te.encode('Content-Encoding: aes128gcm\0'), new Uint8Array([1])))).slice(0, 16);
  const nonce = (await hmac(prk, concat(te.encode('Content-Encoding: nonce\0'), new Uint8Array([1])))).slice(0, 12);
  const key = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const padded = concat(typeof plaintext === 'string' ? te.encode(plaintext) : plaintext, new Uint8Array([2]));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, key, padded));
  const header = new Uint8Array(21 + asPublic.length);
  header.set(salt, 0);
  new DataView(header.buffer).setUint32(16, 4096);
  header[20] = asPublic.length;
  header.set(asPublic, 21);
  return concat(header, ct);
}
// VAPID-Login (JWT mit ES256)
async function vapidAuth(endpoint, publicKey, privateKey, subject) {
  const pub = b64uDec(publicKey);
  const jwk = { kty: 'EC', crv: 'P-256', d: privateKey, x: b64uEnc(pub.slice(1, 33)), y: b64uEnc(pub.slice(33, 65)), ext: true };
  const key = await crypto.subtle.importKey('jwk', jwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const head = b64uEnc(te.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const body = b64uEnc(te.encode(JSON.stringify({
    aud: new URL(endpoint).origin, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: subject,
  })));
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, te.encode(head + '.' + body));
  return `vapid t=${head}.${body}.${b64uEnc(sig)}, k=${publicKey}`;
}
// Schickt eine Nachricht an ein Abo. Gibt den HTTP-Status zurück.
async function sendWebPush(sub, payload, vapid) {
  const body = await encryptPayload(sub.p256dh, sub.auth, JSON.stringify(payload));
  const res = await fetch(sub.endpoint, {
    method: 'POST',
    headers: {
      'Authorization': await vapidAuth(sub.endpoint, vapid.publicKey, vapid.privateKey, vapid.subject),
      'Content-Encoding': 'aes128gcm',
      'Content-Type': 'application/octet-stream',
      'TTL': '86400',
      'Urgency': 'high',
    },
    body,
  });
  try { await res.arrayBuffer(); } catch (_) { /* egal */ }
  return res.status;
}
// --- webpush end ---

const VAPID = {
  publicKey: env('VAPID_PUBLIC_KEY'),
  privateKey: env('VAPID_PRIVATE_KEY'),
  subject: env('VAPID_SUBJECT') || 'https://richardmatz21-creator.github.io/streako/',
};

async function sendTo(userId: string, payload: Record<string, unknown>): Promise<number> {
  const { data: subs, error } = await admin.from('push_subscriptions').select('endpoint,p256dh,auth').eq('user_id', userId);
  if (error) throw error;
  let sent = 0;
  for (const s of subs ?? []) {
    try {
      const status = await sendWebPush(s, payload, VAPID);
      if (status === 404 || status === 410) await admin.from('push_subscriptions').delete().eq('endpoint', s.endpoint);
      else if (status >= 200 && status < 300) sent++;
      else console.log('push status', status, new URL(s.endpoint).host);
    } catch (e) { console.log('push error', String(e)); }
  }
  return sent;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  if (!VAPID.publicKey || !VAPID.privateKey) return json({ error: 'VAPID-Secrets fehlen' }, 500);
  try {
    const body = await req.json().catch(() => ({}));

    // ---- Abend-Erinnerung (vom Cron-Job, jede volle Stunde) ----
    if (body.mode === 'reminder') {
      const secret = env('CRON_SECRET');
      if (!secret || req.headers.get('x-cron-secret') !== secret) return json({ error: 'forbidden' }, 403);
      const hour = Number(new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/Berlin', hour: '2-digit', hourCycle: 'h23' }).format(new Date()));
      const hours = (env('REMINDER_HOURS') || '19').split(',').map((h) => Number(h.trim()));
      if (!hours.includes(hour) && !body.force) return json({ skipped: true, hour });
      const { data, error } = await admin.rpc('reminder_targets');
      if (error) throw error;
      let sent = 0;
      for (const r of data ?? []) {
        if (r.open_count > 0) {
          sent += await sendTo(r.user_id, {
            title: 'Dein Streak ist in Gefahr 🔥',
            body: r.open_count === 1 ? 'Heute ist noch 1 Challenge offen.' : `Heute sind noch ${r.open_count} Challenges offen.`,
            tag: 'reminder',
          });
        }
      }
      return json({ sent });
    }

    // ---- Nachricht aus der App an die andere Person ----
    const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
    if (!jwt) return json({ error: 'unauthorized' }, 401);
    const { data: u, error: ue } = await admin.auth.getUser(jwt);
    if (ue || !u?.user) return json({ error: 'unauthorized' }, 401);
    const { data: players, error: pe } = await admin.from('players').select('id');
    if (pe) throw pe;
    const me = (players ?? []).find((p) => p.id === u.user.id);
    if (!me) return json({ error: 'kein Spieler' }, 403);
    const target = body.to === 'self' ? me : (players ?? []).find((p) => p.id !== me.id);
    if (!target) return json({ sent: 0 });
    const sent = await sendTo(target.id, {
      title: String(body.title ?? 'Streako').slice(0, 80),
      body: String(body.body ?? '').slice(0, 200),
    });
    return json({ sent });
  } catch (e) {
    console.log('error', String(e?.message ?? e));
    return json({ error: String(e?.message ?? e) }, 500);
  }
});
