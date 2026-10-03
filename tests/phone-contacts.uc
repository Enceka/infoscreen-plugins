'use strict';
import { readfile } from 'fs';
let source=ARGV[0] ?? '/src/plugins/phone';
let backend=loadfile(source+'/backend.uc')();
let ctx={
 sh:()=>'{"modem.voice.call":[]}\n__E5_VOICE_RC__0\n', sh_json:()=>null,
 run:cmd=>system(cmd)
};
let routes=backend(ctx);
let contact={name:"测试 O'Brien $(never-execute)",number:'10099'};
let result=routes['POST /contacts']({body:{contacts:[contact]}});
assert(result.ok, 'contact save failed');
let saved=json(readfile('/etc/e5/contacts.json'));
assert(saved[0].name==contact.name, 'contact was shell-interpreted or JSON damaged');
assert(routes['GET /status']({}).contacts[0].number=='10099','round-trip failed');
assert(routes['POST /contacts']({body:{contacts:[]}}).ok,'delete last contact failed');
assert(length(json(readfile('/etc/e5/contacts.json')))==0,'delete re-added old contact');
assert(routes['POST /contacts']({body:{contacts:[{name:'bad',number:'x'}]}}).status==400,'invalid number accepted');
print('Phone contact checks passed\n');
