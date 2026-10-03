// Headless UI checks with intercepted requests; never opens the phone's network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.E5_PLAYWRIGHT || 'playwright');
const www = path.resolve(__dirname, '../plugins');
const shots = process.env.E5_PHONE_SCREENSHOTS;
(async()=>{
 const browser=await chromium.launch({headless:true});
 const page=await browser.newPage({viewport:{width:320,height:424}});
 let calls=[],contacts=[],posts=[],mode='ok',errors=[];
 let audio={available:true,active:true,speaker:false,muted:false,error:null};
 page.on('pageerror',e=>errors.push(e.message));
 await page.route('http://phone.test/**',async route=>{
  const url=new URL(route.request().url()),p=url.pathname;
  if(p.startsWith('/api/plugins/phone/')){
   if(p.endsWith('/status'))return route.fulfill({json:{calls,contacts,audio,error:null}});
   const body=route.request().postDataJSON();posts.push({p,body});
   if(mode==='error')return route.fulfill({status:502,json:{ok:false,stage:'start',error:'NO CARRIER'}});
   if(p.endsWith('/contacts')){contacts=body.contacts;return route.fulfill({json:{ok:true,contacts}});}
   if(p.endsWith('/audio')){Object.assign(audio,body);return route.fulfill({json:{ok:true}});}
   if(p.endsWith('/call'))await new Promise(resolve=>setTimeout(resolve,150));
   return route.fulfill({json:{ok:true,id:'42'}});
  }
  const file=p==='/sdk/e5.js' ? process.env.E5_INFOSCREEN_SDK : path.join(www,p.replace(/^\/plugins/,''));
  if(!file||!fs.existsSync(file))return route.fulfill({status:404,body:''});
  const type=p.endsWith('.js')?'text/javascript':p.endsWith('.css')?'text/css':'text/html';
  return route.fulfill({contentType:type,body:fs.readFileSync(file)});
 });
 async function layout(){const r=await page.evaluate(()=>({w:document.documentElement.clientWidth,scroll:document.documentElement.scrollWidth,h:document.documentElement.clientHeight,scrollH:document.documentElement.scrollHeight,bodyH:document.body.scrollHeight}));assert(r.scroll<=r.w&&r.scrollH<=r.h&&r.bodyH<=r.h,JSON.stringify(r));}
 async function shot(name){if(shots){fs.mkdirSync(shots,{recursive:true});await page.screenshot({path:path.join(shots,name+'.png')});}}
 await page.goto('http://phone.test/plugins/phone/index.html');
 await page.waitForSelector('#contacts .empty');assert.equal(posts.length,0);await layout();await shot('empty');
 for(const key of '10099')await page.click('[data-key="'+key+'"]');
 assert.equal(await page.locator('#number').textContent(),'10099');
 mode='error';await page.click('#dial');
 await page.waitForFunction(()=>document.getElementById('feedback').textContent.includes('NO CARRIER'));
 await page.waitForTimeout(2200);assert((await page.locator('#feedback').textContent()).includes('NO CARRIER'),'poll overwrote the error');await layout();await shot('error');
 mode='ok';posts=[];
 await page.evaluate(()=>{document.getElementById('dial').click();document.getElementById('dial').click();});
 await page.waitForTimeout(400);assert.equal(posts.filter(p=>p.p.endsWith('/call')).length,1,'duplicate dial');
 contacts=[{name:'服务电话',number:'10099'},{name:'联系人',number:'12345'},{name:'第三位联系人',number:'23456'}];
 await page.waitForTimeout(2200);await layout();await shot('dialer');
 await page.click('#save-number');await page.fill('#contact-name','测试联系人');
 await page.click('#editor-save');await page.waitForSelector('#editor[hidden]',{state:'attached'});
 assert.equal(contacts[0].name,'测试联系人');
 await page.click('.contact-remove');await page.click('#delete-confirm');
 await page.waitForSelector('#delete-sheet[hidden]',{state:'attached'});assert(!contacts.some(c=>c.name==='测试联系人'),'delete re-added the removed contact');
 calls=[{id:'42',number:'10099',state:'ringing-in',direction:'incoming'}];
 await page.waitForTimeout(2200);assert(await page.locator('#accept').isVisible());await layout();await shot('incoming');
 const before=posts.length;await page.waitForTimeout(2200);assert.equal(posts.length,before,'poll answered/hung up');
 await page.click('#accept');assert.equal(posts.at(-1).p,'/api/plugins/phone/answer');
 calls[0].state='active';await page.waitForTimeout(2200);assert(!(await page.locator('#accept').isVisible()),'incoming direction treated as ringing after answer');await layout();await shot('active');
 await page.click('#speaker');await page.waitForTimeout(300);assert(audio.speaker);
 await page.click('#mute');await page.waitForTimeout(300);assert(audio.muted);
 await page.setViewportSize({width:320,height:320});await layout();await shot('active-compact');await page.setViewportSize({width:320,height:424});
 await page.click('#hangup');assert.equal(posts.at(-1).p,'/api/plugins/phone/hangup');
 calls=[];await page.waitForTimeout(2200);
 await page.setViewportSize({width:320,height:320});await layout();await shot('compact');
 await page.setViewportSize({width:320,height:424});
 // Known physical menu/unknown events select a button; they never dial from
 // an unfocused empty page. No input-device mapping is changed by this app.
 await page.evaluate(()=>{document.activeElement.blur();});posts=[];
 await page.keyboard.press('Enter');assert.equal(posts.length,0);
 assert.deepEqual(errors,[],'browser errors');
 console.log('Phone UI checks passed');await browser.close();
})().catch(e=>{console.error(e);process.exit(1);});
