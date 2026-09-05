// THE NAME IS WHO YOU ARE, UNTIL YOU GO TO CHANGE IT.
//
// At rest the moniker field wore the same empty box as the message beside it,
// which said "type here" about a field that already holds an answer — you are
// anon — and put two identical invitations in a row where only one of them is
// asking for anything. It rests as a chip in the send button's clothes now, and
// turns back into a field the moment it is focused.
//
// MEASURED, AND MEASURED AGAINST send RATHER THAN AGAINST A COLOUR. Asked for as
// "white like send"; send is not white, it is a translucent grey that reads light
// on a dark page and stays right on a light one. Pinning a hex would pass while
// the two drifted apart, and would be wrong in one theme — which is exactly what
// these inputs looked like before anyone styled them, unstyled and browser-white.
// So the assertion is that the chip and the button match, whatever they are.
const puppeteer = require('puppeteer');
const path = require('path');
const PAGE = 'file://' + path.join(__dirname, '..', '..', 'index.html');

(async () => {
  const browser = await puppeteer.launch({headless: 'new'});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  for (const scheme of ['dark', 'light']) {
    const page = await browser.newPage();
    await page.emulateMediaFeatures([{name: 'prefers-color-scheme', value: scheme}]);
    await page.evaluateOnNewDocument(() => {
      localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo"}));
      localStorage.setItem("cc.intro", "1");
    });
    await page.setViewport({width: 1150, height: 1000});
    await page.goto(PAGE + '#/c/orem', {waitUntil: 'networkidle0'});
    await new Promise(z => setTimeout(z, 1400));

    const look = () => page.evaluate(() => {
      const m = document.querySelector(".chatmoniker");
      if (!m) return {none: true};
      const g = e => { const c = getComputedStyle(e);
        return {bg: c.backgroundColor, bd: c.borderTopColor, align: c.textAlign, cursor: c.cursor}; };
      return {moniker: g(m), send: g(document.querySelector(".chatsend")),
              input: g(document.querySelector(".chatinput")),
              focused: document.activeElement === m};
    });

    const rest = await look();
    if (rest.none) { ok(`${scheme}: the composer is on the page`, false); await page.close(); continue; }
    ok(`${scheme}: at rest the name wears the send button's clothes`,
       rest.moniker.bg === rest.send.bg && rest.moniker.bd === rest.send.bd, JSON.stringify(rest));
    /* AND IS NOT THE EMPTY BOX BESIDE IT. The message field is the one asking for
       something; two identical boxes made them look like one question asked
       twice. */
    ok(`${scheme}: ...and not the message field's`,
       rest.moniker.bg !== rest.input.bg, JSON.stringify(rest));
    ok(`${scheme}: ...reading as something to press, not to fill`,
       rest.moniker.cursor === "pointer", JSON.stringify(rest.moniker));

    await page.evaluate(() => document.querySelector(".chatmoniker").focus());
    await new Promise(z => setTimeout(z, 200));
    const on = await look();
    /* A CHIP YOU CANNOT EDIT IS THE FAILURE MODE. The whole point of the chip is
       that it is still a field; if focusing it changed nothing it would be a
       button that does nothing, and the name could never be changed. */
    ok(`${scheme}: focusing it turns it back into a field`,
       on.focused && on.moniker.bg !== rest.moniker.bg && on.moniker.cursor === "text",
       JSON.stringify(on.moniker));
    ok(`${scheme}: ...and it takes what you type`,
       await page.evaluate(async () => {
         const m = document.querySelector(".chatmoniker");
         m.focus(); m.value = ""; 
         document.execCommand && document.execCommand("insertText", false, "kourtney");
         if (!m.value) m.value = "kourtney";
         m.dispatchEvent(new Event("input", {bubbles: true}));
         await new Promise(z => setTimeout(z, 80));
         return m.value === "kourtney" && !m.disabled && !m.readOnly;
       }), "the field refused the edit");
    await page.close();
  }

  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
