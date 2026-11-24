const {run,els}=require('./harness.cjs');
const assert=require('assert');
const T=run("new Date().toLocaleDateString('en-CA')");
run(`db.users.forEach(u=>{u.odd=80;u.commissionPercent=10;u.payment=null});`);
const uid=run('db.users[0].id');
let ok=0;const t=(name,fn)=>{fn();ok++;console.log('ok -',name)};

// morning bets and morning draw
run(`db.entries.push({id:'e1',voucher:'V1',userId:'${uid}',date:'${T}',lines:[{num:'12',amount:1000},{num:'21',amount:500}],created:new Date().toISOString()});save()`);
els.drawDate={...(els.drawDate||{}),value:T};
function setDraw(date,session,number){
  for(const k of ['drawDate','drawSession','drawNumber']) els[k]=els[k]||{value:''};
  els.drawDate.value=date;els.drawSession.value=session;els.drawNumber.value=number;
  run('saveDrawResults()');
}
t('save morning draw',()=>{setDraw(T,'morning','12');assert.strictEqual(run('db.drawResults.length'),1);assert.strictEqual(run('db.drawResults[0].session'),'morning')});
t('save evening draw for same date is a separate row',()=>{setDraw(T,'evening','21');assert.strictEqual(run('db.drawResults.length'),2)});
t('same date+session overwrites',()=>{setDraw(T,'evening','22');assert.strictEqual(run('db.drawResults.length'),2);assert.strictEqual(run("db.drawResults.find(x=>x.session==='evening').number"),'22');setDraw(T,'evening','21')});
t('latest draw = evening of newest date',()=>assert.strictEqual(run('drawSess(sortDraws()[0])'),'evening'));

// finalize: first unfinalized latest = evening; but finalize morning explicitly
t('finalize morning',()=>{
  run(`confirmFinalize('${T}','morning')`);
  const recs=run('db.finalizedRecords.filter(r=>r.userId===db.users[0].id)');
  assert.strictEqual(recs.length,1);
  const r=recs[0];
  assert.strictEqual(r.session,'morning');assert.strictEqual(r.number,'12');
  assert.strictEqual(r.total,1500);assert.strictEqual(r.winAmount,1000);assert.strictEqual(r.payout,80000);
  assert.strictEqual(r.commission,150);assert.strictEqual(r.net,1500-80000-150);
  assert.strictEqual(run('db.entries.length'),0);
  assert.strictEqual(run('db.finalizedRecords.length'),run('db.users.length'));
});
t('same session cannot be finalized twice',()=>{const n=run('db.finalizedRecords.length');run(`confirmFinalize('${T}','morning')`);assert.strictEqual(run('db.finalizedRecords.length'),n)});
t('evening bets entered after morning finalize are finalized separately',()=>{
  run(`db.entries.push({id:'e2',voucher:'V2',userId:'${uid}',date:'${T}',lines:[{num:'21',amount:200}],created:new Date().toISOString()})`);
  run('openFinalizeConfirm()');
  assert.ok(els.modalRoot.innerHTML.includes(`confirmFinalize('${T}','evening')`),'finalize dialog should target the evening draw');
  run(`confirmFinalize('${T}','evening')`);
  const r=run(`db.finalizedRecords.find(r=>r.session==='evening'&&r.userId==='${uid}')`);
  assert.strictEqual(r.total,200);assert.strictEqual(r.number,'21');assert.strictEqual(r.payout,200*80);
});
t('all finalized -> dialog not opened',()=>{els.modalRoot.innerHTML='';run('openFinalizeConfirm()');assert.strictEqual(els.modalRoot.innerHTML,'')});
t('history renders with delete buttons',()=>{run('renderHistory()');const h=els.historyPanel.innerHTML;assert.ok(h.includes('deleteFinalized('));assert.ok(h.includes('<th></th>'))});
t('delete one history record',()=>{const id=run('db.finalizedRecords[0].id');const n=run('db.finalizedRecords.length');run(`deleteFinalized('${id}')`);assert.ok(els.modalRoot.innerHTML.includes('confirmDeleteFinalized'));run(`confirmDeleteFinalized('${id}')`);assert.strictEqual(run('db.finalizedRecords.length'),n-1)});
t('delete a draw result',()=>{const n=run('db.drawResults.length');run(`deleteDrawResult('${T}','morning')`);assert.ok(els.modalRoot.innerHTML.includes('confirmDeleteDraw'));run(`confirmDeleteDraw('${T}','morning')`);assert.strictEqual(run('db.drawResults.length'),n-1);assert.ok(!run(`db.drawResults.some(x=>x.session==='morning')`))});
t('deleting a draw leaves history intact',()=>assert.ok(run(`db.finalizedRecords.some(r=>r.session==='morning')`),'morning history rows of the other user remain after the morning draw was deleted'));

// settlement by session
t('settlement uses date + session',()=>{
  run(`db.entries.push({id:'e3',voucher:'V3',userId:'${uid}',date:'${T}',lines:[{num:'21',amount:1000}],created:new Date().toISOString()})`);
  els.settleDate={value:T};els.settleSession={value:'evening'};els.settlementResult={innerHTML:''};
  run(`calculateUserSettlement('${uid}')`);
  assert.ok(els.settlementResult.innerHTML.includes('21'),'shows evening winning number 21');
  els.settleSession.value='morning';run(`calculateUserSettlement('${uid}')`);
  assert.ok(els.settlementResult.innerHTML.includes('မရှိသေးပါ')||!els.settlementResult.innerHTML.includes('ထွက်ဂဏန်း: <b>21'),'morning draw deleted -> no draw');
});

// Numbers page active count
t('Numbers page shows active count',()=>{
  run(`db.entries.length=0;db.entries.push({id:'e4',voucher:'V4',userId:'${uid}',date:'${T}',lines:[{num:'05',amount:100},{num:'05',amount:50},{num:'33',amount:10},{num:'99',amount:1}],created:new Date().toISOString()})`);
  run('renderNumbers()');
  const h=els.numbersPanel.innerHTML;
  assert.ok(h.includes('Active'));assert.ok(h.includes('3 / 100'),'3 numbers have stake: 05, 33, 99');
  run('db.entries.length=0;renderNumbers()');
  assert.ok(els.numbersPanel.innerHTML.includes('0 / 100'));
});
t('openDrawResults renders',()=>{run('openDrawResults()');assert.ok(els.modalRoot.innerHTML.includes('drawSession'))});
t('full render() has no errors',()=>run('render()'));
console.log(ok+' checks passed');
