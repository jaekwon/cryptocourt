// Strip comments from the overlay, for the copy that ships.
//
//   node scripts/strip-comments.js in.html out.html
//
// WHY. web/index.html is 733KB, of which 112KB is comments — this codebase
// argues with itself in prose and that prose is the reason it is maintainable.
// It is also 15% of what every reader downloads and 15% of what their browser
// parses before the first paint. The repo keeps every word; the deployed copy
// does not need them. deploy.sh already stamps a COPY (chain config, LOCKED),
// so this is one more thing done to that copy and never to the tree.
//
// WHY A TOKENIZER AND NOT A REGULAR EXPRESSION. Because a regular expression
// gets this wrong, and gets it wrong silently. This file is full of:
//
//   "https://kourt.xyz"        // a // that is not a comment
//   `…${x}//${y}…`             // and one inside a template
//   /\/\*[\s\S]*?\*\//g        // a regex literal containing a comment opener
//   `/* not a comment */`      // a comment opener inside a template literal
//
// Earlier in this project a block comment inside a template literal rendered as
// page text, and its replacement contained */ in the prose and closed the
// comment early, blanking the page. A scanner that understands strings,
// templates (nested, with ${} back into code) and regex literals is the only
// honest way to do this.
//
// The output is checked before it is returned: it must parse, and every string
// and template literal in the input must still be present, in order.
"use strict";
const fs = require("fs");

// ---------------------------------------------------------------- the scanner
// Returns {out, stripped, literals}. `literals` is every string/template body in
// source order — the invariant the caller checks.
function stripJs(src) {
  let out = "";
  const literals = [];
  let i = 0, stripped = 0;
  // What the last significant character was, for the regex-vs-division call.
  let prev = "", prevWord = "";
  // Template literals nest: `a${ `b` }c`. Each entry is the brace depth at which
  // the template resumes.
  const tstack = [];
  let depth = 0;

  const isIdChar = c => /[A-Za-z0-9_$]/.test(c);
  // After these, a slash begins a REGEX, not a division — `return /x/` is the
  // one that bites, because the character before the slash is a letter.
  const KEYWORD_BEFORE_REGEX = new Set(["return","typeof","instanceof","in","of",
    "new","delete","void","throw","case","do","else","yield","await"]);

  while (i < src.length) {
    const c = src[i], d = src[i+1];

    // --- inside a template's ${ }: fall through to normal scanning, but a }
    // that closes the interpolation returns us to template text.
    if (c === "`") {
      // read the template, honouring ${ } and \escapes
      let j = i + 1, body = "";
      for (;;) {
        if (j >= src.length) throw new Error("unterminated template literal");
        if (src[j] === "\\") { body += src[j] + src[j+1]; j += 2; continue; }
        if (src[j] === "`") { j++; break; }
        if (src[j] === "$" && src[j+1] === "{") {
          // an interpolation: scan it as CODE, so comments inside it are stripped
          // too, and nested templates work.
          let k = j + 2, d2 = 1, inner = "";
          while (k < src.length && d2 > 0) {
            // find the matching }, respecting nested strings/templates
            const piece = scanOne(src, k);
            if (piece.text === "{") d2++;
            else if (piece.text === "}") { d2--; if (d2 === 0) { k = piece.end; break; } }
            inner += piece.text; k = piece.end;
            if (piece.literals) literals.push(...piece.literals);
          }
          const sub = stripJs(inner);
          literals.push(...sub.literals);
          stripped += sub.stripped;
          body += "${" + sub.out + "}";
          j = k;
          continue;
        }
        body += src[j]; j++;
      }
      out += "`" + body + "`";
      literals.push("`" + body + "`");
      prev = "`"; prevWord = ""; i = j; continue;
    }

    if (c === '"' || c === "'") {
      let j = i + 1, body = "";
      for (;;) {
        if (j >= src.length) throw new Error("unterminated string");
        if (src[j] === "\\") { body += src[j] + src[j+1]; j += 2; continue; }
        if (src[j] === c) { j++; break; }
        if (src[j] === "\n") throw new Error("newline in string");
        body += src[j]; j++;
      }
      out += c + body + c;
      literals.push(c + body + c);
      prev = c; prevWord = ""; i = j; continue;
    }

    if (c === "/" && d === "/") {
      let j = i; while (j < src.length && src[j] !== "\n") j++;
      stripped += j - i;
      i = j;                       // the newline itself is kept
      continue;
    }

    if (c === "/" && d === "*") {
      const j = src.indexOf("*/", i + 2);
      if (j < 0) throw new Error("unterminated block comment");
      const chunk = src.slice(i, j + 2);
      stripped += chunk.length;
      // Keep the newlines: line numbers in a stack trace still mean something,
      // and it costs one byte per line against 112KB saved.
      out += chunk.replace(/[^\n]/g, "");
      i = j + 2;
      continue;
    }

    if (c === "/") {
      // regex literal, or division?
      const regexOk = !(prev && (isIdChar(prev) || prev === ")" || prev === "]"))
                      || KEYWORD_BEFORE_REGEX.has(prevWord);
      if (regexOk) {
        let j = i + 1, cls = false, body = "";
        for (;;) {
          if (j >= src.length || src[j] === "\n") throw new Error("unterminated regex");
          if (src[j] === "\\") { body += src[j] + src[j+1]; j += 2; continue; }
          if (src[j] === "[") cls = true;
          else if (src[j] === "]") cls = false;
          else if (src[j] === "/" && !cls) { j++; break; }
          body += src[j]; j++;
        }
        while (j < src.length && /[a-z]/.test(src[j])) j++;   // flags
        out += src.slice(i, j);
        prev = "/"; prevWord = ""; i = j; continue;
      }
    }

    if (c === "{") depth++;
    if (c === "}") depth--;
    out += c;
    if (!/\s/.test(c)) { prev = c; prevWord = isIdChar(c) ? prevWord + c : ""; }
    i++;
  }
  return { out, stripped, literals };
}

// Reads ONE token-ish piece starting at k, used only to walk an interpolation to
// its closing brace without being fooled by a } inside a string.
function scanOne(src, k) {
  const c = src[k];
  if (c === '"' || c === "'" || c === "`") {
    const q = c; let j = k + 1;
    for (;;) {
      if (j >= src.length) throw new Error("unterminated literal in interpolation");
      if (src[j] === "\\") { j += 2; continue; }
      if (q === "`" && src[j] === "$" && src[j+1] === "{") {
        let d = 1, m = j + 2;
        while (m < src.length && d > 0) {
          const p = scanOne(src, m);
          if (p.text === "{") d++; else if (p.text === "}") d--;
          m = p.end;
        }
        j = m; continue;
      }
      if (src[j] === q) { j++; break; }
      j++;
    }
    return { text: src.slice(k, j), end: j, literals: [src.slice(k, j)] };
  }
  if (c === "/" && src[k+1] === "/") { let j = k; while (j < src.length && src[j] !== "\n") j++;
    return { text: src.slice(k, j), end: j }; }
  if (c === "/" && src[k+1] === "*") { const j = src.indexOf("*/", k + 2);
    return { text: src.slice(k, j + 2), end: j + 2 }; }
  return { text: c, end: k + 1 };
}

// CSS has no regex literals and no templates — strings and comments only.
function stripCss(src) {
  let out = "", i = 0, stripped = 0;
  while (i < src.length) {
    const c = src[i];
    if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < src.length && src[j] !== c) { if (src[j] === "\\") j++; j++; }
      out += src.slice(i, j + 1); i = j + 1; continue;
    }
    if (c === "/" && src[i+1] === "*") {
      const j = src.indexOf("*/", i + 2);
      if (j < 0) throw new Error("unterminated css comment");
      stripped += j + 2 - i;
      out += src.slice(i, j + 2).replace(/[^\n]/g, "");
      i = j + 2; continue;
    }
    out += c; i++;
  }
  return { out, stripped };
}

// ------------------------------------------------------------------- the file
function stripHtml(html) {
  let out = "", i = 0, saved = 0;
  const lits = [];
  for (;;) {
    // <script> without src, and <style>
    const m = /<(script)(?![^>]*\bsrc=)[^>]*>|<(style)[^>]*>/i.exec(html.slice(i));
    if (!m) { out += html.slice(i); break; }
    const openAt = i + m.index, bodyAt = openAt + m[0].length;
    const tag = (m[1] || m[2]).toLowerCase();
    const closeAt = html.toLowerCase().indexOf("</" + tag + ">", bodyAt);
    if (closeAt < 0) { out += html.slice(i); break; }
    out += html.slice(i, bodyAt);
    const body = html.slice(bodyAt, closeAt);
    const r = tag === "script" ? stripJs(body) : stripCss(body);
    if (r.literals) lits.push(...r.literals);
    out += r.out;
    saved += r.stripped;
    i = closeAt;
  }
  return { out, saved, literals: lits };
}

// ------------------------------------------------------------------- the check
// Never trust the scanner: prove the output before handing it back.
function verify(inHtml, outHtml) {
  const a = stripHtml(inHtml), b = stripHtml(outHtml);
  if (b.saved !== 0) throw new Error(`the output still holds ${b.saved} bytes of comment`);
  if (a.literals.length !== b.literals.length)
    throw new Error(`literal count changed: ${a.literals.length} -> ${b.literals.length}`);
  for (let k = 0; k < a.literals.length; k++)
    if (a.literals[k] !== b.literals[k])
      throw new Error(`literal ${k} changed:\n  in  ${a.literals[k].slice(0,90)}\n  out ${b.literals[k].slice(0,90)}`);
  // and it has to parse
  const js = [...outHtml.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi)]
    .map(x => x[1]).join("\n;\n");
  new Function(js);            // throws on a syntax error
}

if (require.main === module) {
  const [, , inPath, outPath] = process.argv;
  if (!inPath || !outPath) { console.error("usage: strip-comments.js in.html out.html"); process.exit(2); }
  const src = fs.readFileSync(inPath, "utf8");
  const { out, saved } = stripHtml(src);
  verify(src, out);
  fs.writeFileSync(outPath, out);
  const pct = (100 * saved / src.length).toFixed(1);
  console.log(`strip-comments: ${src.length.toLocaleString()} -> ${out.length.toLocaleString()} bytes `
            + `(${saved.toLocaleString()} of comment, ${pct}%)`);
}

module.exports = { stripJs, stripCss, stripHtml, verify };
