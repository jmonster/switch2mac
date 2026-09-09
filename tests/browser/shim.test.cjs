const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

function fixture() {
  let now = 0, next = 0; const timers = new Map(), listeners = new Map(), commands = [], events = [], nativePads = [];
  class Event {constructor(type, options={}) {this.type=type; Object.assign(this,options);}}
  class Navigator {getGamepads() {return nativePads;}}
  const navigator = new Navigator();
  const document = {hidden:false,
    addEventListener(type, fn) {listeners.set(type,fn);},
    dispatchEvent(ev) {if(ev.type==='ftcw-up') commands.push(JSON.parse(ev.detail)); else listeners.get(ev.type)?.(ev);},
  };
  const context = {navigator, Navigator, document, window:{dispatchEvent(event){events.push(event);}}, Event, CustomEvent:Event,
    localStorage:{getItem(){return null;}}, location:{host:'hardwaretester.com'}, performance:{now:()=>now},
    setTimeout(fn, ms=0) {timers.set(++next,{fn,at:now+ms});return next;},
    clearTimeout(id){timers.delete(id);},
    setInterval(fn, ms) {timers.set(++next,{fn,at:now+ms,interval:ms});return next;},
    clearInterval(id){timers.delete(id);},
  };
  vm.runInNewContext(fs.readFileSync(process.env.SHIM_SOURCE || path.join(__dirname,'../../browser/extension/shim.js'),'utf8'),context);
  const emit = m => document.dispatchEvent(new Event('ftcw-bridge',{detail:JSON.stringify(m)}));
  function advance(ms) {
    const end = now+ms;
    for(let i=0;i<10000;i++) {
      const pending = [...timers].filter(([,t])=>t.at<=end).sort((a,b)=>a[1].at-b[1].at)[0];
      if(!pending) {now=end; return;}
      const [id,t]=pending; now=t.at;
      if(t.interval) t.at+=t.interval; else timers.delete(id);
      t.fn();
    }
    throw Error('Timer loop did not terminate');
  }
  const pad=()=>navigator.getGamepads().find(Boolean);
  emit({t:'bridge',up:true}); emit({t:'connected',slot:0,model:'Pro Controller 2',name:'pad'});
  return {emit,advance,commands,pad,navigator,events,nativePads};
}

test('long rumble refreshes within the native half-second intent expiry', async()=>{
  const f=fixture(); const promise=f.pad().vibrationActuator.playEffect('dual-rumble',{strongMagnitude:1,duration:1100});
  f.advance(1000);
  assert.ok(f.commands.filter(m=>m.t==='rumble' && m.strong===1).length>=5);
  f.advance(100); assert.equal(await promise,'complete');
  assert.equal(f.commands.at(-1).strong,0);
});

test('disconnect cancels delayed effects and settles their promises', async()=>{
  const f=fixture(); let result;
  const old=f.pad().vibrationActuator;
  old.playEffect('dual-rumble',{strongMagnitude:1,startDelay:100,duration:2000}).then(v=>result=v);
  f.emit({t:'disconnected',slot:0});
  await Promise.resolve();
  assert.equal(result,'preempted');
  f.emit({t:'connected',slot:0,model:'Pro Controller 2',name:'replacement'});
  const count=f.commands.length;
  f.advance(2500);
  assert.equal(f.commands.length,count);
  await old.playEffect('dual-rumble',{strongMagnitude:1,duration:20});
  await old.reset();
  assert.equal(f.commands.length,count, 'A stale actuator must not address the replacement slot');
});

test('preemption stops the old effect during a new start delay', async()=>{
  const f=fixture(), actuator=f.pad().vibrationActuator;
  const first=actuator.playEffect('dual-rumble',{strongMagnitude:1,duration:1000});
  const second=actuator.playEffect('dual-rumble',{weakMagnitude:1,startDelay:400,duration:100});
  assert.equal(await first,'preempted'); assert.equal(f.commands.at(-1).strong,0);
  f.advance(500); assert.equal(await second,'complete');
});

test('input snapshots remain independent and trigger/axis mappings are preserved',()=>{
  const f=fixture();
  f.emit({t:'state',slot:0,b:4,lx:0.3,ly:0.5,rx:-0.1,ry:0,lt:128,rt:255});
  const before=f.pad();
  f.emit({t:'state',slot:0,b:0,lx:0,ly:0,rx:0,ry:0,lt:0,rt:0});
  const after=f.pad();
  assert.equal(before.buttons[0].pressed,true); assert.equal(after.buttons[0].pressed,false);
  assert.equal(before.axes[1],-0.5); assert.equal(before.buttons[6].value,128/255);
  assert.equal(before.buttons[7].value,1);
});


test('native hotplug cannot hide a bridged pad or move unrelated virtual indices',()=>{
  const f=fixture();
  f.emit({t:'connected',slot:1,model:'Pro Controller 2',name:'second'});
  f.emit({t:'state',slot:0,b:4,lx:0.25,ly:0,rx:0,ry:0,lt:0,rt:0});
  const old=f.navigator.getGamepads()[0];
  f.nativePads[0]={id:'native',index:0,connected:true};
  const pads=f.navigator.getGamepads();
  assert.equal(pads[0].id,'native');
  assert.equal(pads[1].__ftcwSlot,1);
  assert.equal(pads[2]?.__ftcwSlot,0,'Native hotplug hid the bridged controller');
  assert.equal(pads[2].buttons[0].pressed,true);
  assert.equal(old.index,0,'Existing snapshots must not be mutated');
  const removal=f.events.findLast(e=>e.type==='gamepaddisconnected');
  assert.equal(removal.gamepad.index,0);
  assert.equal(removal.gamepad.connected,false);
  assert.equal(f.events.at(-1).type,'gamepadconnected');
  assert.equal(f.events.at(-1).gamepad.index,2);
  const count=f.events.length;
  f.navigator.getGamepads();
  assert.equal(f.events.length,count,'Stable indices must not fire duplicate hotplug events');
});
