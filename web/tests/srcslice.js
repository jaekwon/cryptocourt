// The overlay's source, and the two ways a harness cuts a piece out of it.
//
// WHY THIS FILE EXISTS. `function slice(from, to)` was defined in THIRTY-FIVE
// harnesses. Measured before this: all thirty-five bodies were semantically
// identical -- indexOf the opening anchor, indexOf the closing one after it,
// throw if either is missing, return the span. The only differences were the
// error wording (two files said "missing end", which is the better message and
// is the one kept here) and spacing.
//
// The cost of the copies was not the lines. It was that the RIGHT TOOL could
// not spread. `slice` is EXCLUSIVE of its terminator, which is what you want
// when cutting "from this function to the next"; it is the wrong thing when you
// want a whole function, and then the caller has to know to append the brace
// back. Two harnesses had already grown `fn(name)` for that -- holders_test and
// price_test -- and the other thirty-three could not reach it, so a harness
// wanting one function either re-derived `fn` or hand-appended "\n}" to a
// `slice` call. That happened during this session, in verdictside_test, before
// this file existed.
//
// NOT NAMED *_test.js ON PURPOSE: web/tests/run.js collects exactly
// `*_test.js`, so a helper here must not match that glob or the runner would
// try to run it as a harness and count its (zero) assertions.
const fs = require("fs");
const path = require("path");

const src = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");

// slice cuts from the first occurrence of `from` up to -- but NOT including --
// the next occurrence of `to`. Use it to lift a region bounded by the thing that
// follows it ("from this function to the next one").
//
// The two anchors are reported separately. A single "missing" message for either
// end sends you looking at the wrong string half the time: the usual failure is
// that `from` still matches and the code that used to follow it has moved.
function slice(from, to) {
  const a = src.indexOf(from);
  if (a < 0) throw new Error("missing start " + from);
  const b = src.indexOf(to, a);
  if (b < 0) throw new Error("missing end " + to);
  return src.slice(a, b);
}

// fn lifts a whole named function, closing brace INCLUDED, so the result can be
// eval'd as-is.
//
// It ends at the first line that is exactly "}", which is true of every function
// in the overlay's style and is why this is not brace-counting. Taking the
// function "up to whatever declaration follows it" is the obvious alternative
// and it is wrong twice over: the next declaration is often not adjacent, so the
// span drags in everything between -- including code that touches `document`,
// which does not exist under node. price_test died on "document is not defined"
// while testing two pure string functions, and that is what this exists to stop.
function fn(name) {
  const a = src.indexOf("function " + name + "(");
  if (a < 0) throw new Error("missing function " + name);
  const b = src.indexOf("\n}", a);
  if (b < 0) throw new Error("unterminated function " + name);
  return src.slice(a, b + 2);
}

module.exports = { src, slice, fn };
