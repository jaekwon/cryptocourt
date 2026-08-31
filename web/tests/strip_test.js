// The comment stripper, fed the inputs a regular expression gets wrong.
//
// WHY THIS HARNESS IS THE WHOLE JUSTIFICATION FOR THE SCRIPT. Stripping comments
// is worth ~15% of what every reader downloads and parses, and it is worth
// nothing if the stripper is ever wrong: a scanner that mistakes a URL for a
// comment does not fail loudly, it ships a page with a line missing. This file
// is the argument that it is not wrong — every case below is one this codebase
// actually contains.
const { stripJs, stripHtml, verify } = require("../../scripts/strip-comments.js");
let fail = 0;
const ok = (n, c) => { if(!c){ fail++; console.log("FAIL:", n); } else console.log("ok:", n); };
const js = s => stripJs(s).out;

// ---- the things that are NOT comments ------------------------------------
ok("a // inside a double-quoted string survives",
   js(`const u = "https://kourt.xyz/x";`) === `const u = "https://kourt.xyz/x";`);
ok("a // inside a single-quoted string survives",
   js(`const u = 'a//b';`) === `const u = 'a//b';`);
ok("a // inside a template survives",
   js("const u = `https://kourt.xyz`;") === "const u = `https://kourt.xyz`;");
ok("a /* inside a template survives — this one blanked the page once",
   js("const s = `/* not a comment */`;") === "const s = `/* not a comment */`;");
ok("a comment opener inside a regex survives",
   js("const re = /\\/\\*[\\s\\S]*?\\*\\//g;") === "const re = /\\/\\*[\\s\\S]*?\\*\\//g;");
ok("a slash inside a character class survives",
   js("const re = /[/]/;") === "const re = /[/]/;");
ok("an escaped quote does not end the string",
   js(`const s = "a\\"//b";`) === `const s = "a\\"//b";`);

// ---- the things that ARE comments -----------------------------------------
ok("a line comment goes", js("a();// gone\nb();") === "a();\nb();");
ok("a block comment goes, and its newlines stay",
   js("a();/* one\ntwo */b();") === "a();\nb();");
ok("a comment inside an interpolation goes",
   js("const s = `x${ 1 /* gone */ + 2 }y`;") === "const s = `x${ 1  + 2 }y`;");

// ---- regex versus division, which is where scanners die -------------------
ok("division after an identifier is not a regex",
   js("const r = a / b; // gone\n") === "const r = a / b; \n");
ok("division after a ) is not a regex", js("const r = f(x) / 2;") === "const r = f(x) / 2;");
ok("division after a ] is not a regex", js("const r = a[0] / 2;") === "const r = a[0] / 2;");
ok("a regex after return is a regex, not division",
   js("function f(){ return /a\\/b/.test(s); }") === "function f(){ return /a\\/b/.test(s); }");
ok("a regex after typeof-like keywords too",
   js("if(typeof /x/ === 'object'){}") === "if(typeof /x/ === 'object'){}");
ok("a regex at the start of an argument list",
   js("s.replace(/\\/\\//g, '');") === "s.replace(/\\/\\//g, '');");

// ---- nesting ---------------------------------------------------------------
ok("a template inside an interpolation inside a template",
   js("const s = `a${ `b${ c }d` }e`;") === "const s = `a${ `b${ c }d` }e`;");
ok("and a comment stripped from the innermost one",
   js("const s = `a${ `b${ c /* x */ }d` }e`;") === "const s = `a${ `b${ c  }d` }e`;");

// ---- the whole file, which is the real test -------------------------------
{
  const fs = require("fs");
  const path = require("path");
  const src = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
  let out = null, err = null;
  try { out = stripHtml(src).out; verify(src, out); } catch(e){ err = e; }
  ok("the real overlay strips and passes its own verification" + (err ? " — " + err.message : ""), !err);
  if (out) {
    ok("it got materially smaller", out.length < src.length * 0.9);
    // The page is a single global scope; check-web-dupes counts top-level
    // declarations. Losing one would be a silent, total failure.
    const names = s => (s.match(/^(?:const|let|var|function|async function) [A-Za-z_$][\w$]*/gm) || []).length;
    ok("every top-level declaration survived", names(out) === names(src));
    // EVERYTHING OUTSIDE A SCRIPT OR STYLE IS UNTOUCHED, byte for byte. Stated as
    // an invariant rather than as a list of sentences to look for: a list goes
    // stale the moment somebody edits the copy — this one asserted a tagline that
    // had been recapitalised and a ribbon that had become a chip, and both
    // "failures" were the test being wrong. The markup is not the stripper's
    // business, so the honest check is that it did not touch it at all.
    const shell = t => t.replace(/<script(?![^>]*\bsrc=)[^>]*>[\s\S]*?<\/script>/gi, "<script/>")
                        .replace(/<style[^>]*>[\s\S]*?<\/style>/gi, "<style/>");
    ok("every byte outside the script and style blocks is untouched",
       shell(out) === shell(src));
    ok("and no line comment survived anywhere in the script",
       !/^\s*\/\//m.test(out.slice(out.indexOf("<script"))));
  }
}

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
