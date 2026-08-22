const puppeteer=require('puppeteer');
// check-browser-checks: not-a-check — it prints a snapshot rather than asserting, so a gate running it would prove nothing; it is a diff tool for showing a refactor changed nothing.
const ROUTES=["/","/c/orem","/c/orem/1","/c/orem/3","/c/orem/4","/c/orem/7","/c/ledger","/c/ledger/1","/c/annex","/me","/needs","/c/orem/map","/c/orem/f/0"];
(async()=>{
  const b=await puppeteer.launch({headless:'new'});
  const p=await b.newPage();
  const errs=[]; p.on('pageerror',e=>errs.push(String(e).slice(0,120)));
  await p.setViewport({width:1440,height:1200});
  await p.evaluateOnNewDocument(()=>{localStorage.setItem("cc.cfg",JSON.stringify({mode:"demo"}));localStorage.setItem("cc.intro","1");});
  const out={};
  for(const r of ROUTES){
    await p.goto('file://' + require('path').join(__dirname,'..','..','index.html') + '#' + r,{waitUntil:'domcontentloaded'});
    await new Promise(x=>setTimeout(x,900));
    out[r]=await p.evaluate(()=>document.querySelector('.main').innerText.replace(/\s+/g,' ').trim());
  }
  out.__errors=errs;
  console.log(JSON.stringify(out));
  await b.close();
})();
