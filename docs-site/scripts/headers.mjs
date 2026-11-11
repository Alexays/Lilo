// Prepends the security headers to the _headers file Blume wrote, keeping Blume's rules below. Blume
// has no CSP support and renders its theme and layout scripts inline, so each inline script gets a
// hash instead of allowing 'unsafe-inline'.
import { createHash } from "node:crypto";
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const dist = fileURLToPath(new URL("../dist", import.meta.url));
// Cloudflare's limits for _headers: https://developers.cloudflare.com/workers/static-assets/headers/
const MAX_LINE = 2000;
const MAX_RULES = 100;

/** The source of every inline script a browser executes; JSON data blocks run nothing. */
export function inlineScripts(html) {
  const scripts = [];
  for (const [, attrs, body] of html.matchAll(/<script([^>]*)>([\s\S]*?)<\/script>/gu)) {
    if (body && !/\ssrc=/u.test(attrs) && !/type="application\/(?:ld\+)?json"/u.test(attrs)) {
      scripts.push(body);
    }
  }
  return scripts;
}

export const scriptHash = (body) => `'sha256-${createHash("sha256").update(body).digest("base64")}'`;

function main() {
  const hashes = new Set();
  for (const entry of readdirSync(dist, { recursive: true })) {
    if (entry.endsWith(".html")) {
      for (const body of inlineScripts(readFileSync(join(dist, entry), "utf-8"))) {
        hashes.add(scriptHash(body));
      }
    }
  }
  const csp = [
    "default-src 'none'",
    `script-src 'self' ${[...hashes].sort().join(" ")}`,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data:",
    "font-src 'self'",
    "connect-src 'self'",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'none'",
  ].join("; ");
  const file = join(dist, "_headers");
  const headers = `/*
  Content-Security-Policy: ${csp}
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()
  Strict-Transport-Security: max-age=31536000; includeSubDomains

/_astro/*
  Cache-Control: public, max-age=31536000, immutable

${readFileSync(file, "utf-8")}`;
  const lines = headers.split("\n");
  const long = lines.find((line) => line.length > MAX_LINE);
  if (long) {
    throw new Error(`_headers line of ${long.length} characters exceeds Cloudflare's ${MAX_LINE}: ${long.slice(0, 80)}…`);
  }
  const rules = lines.filter((line) => line.startsWith("/")).length;
  if (rules > MAX_RULES) {
    throw new Error(`_headers has ${rules} rules, more than Cloudflare's ${MAX_RULES}`);
  }
  writeFileSync(file, headers);
  console.log(`_headers: ${hashes.size} inline script hashes, ${rules} rules, CSP line ${csp.length} characters`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main();
}
