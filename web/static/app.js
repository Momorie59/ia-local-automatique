// ── Tab navigation ────────────────────────────────────────────────────────
let activeTab='stats';
let _hubLoaded=false, _powerLoaded=false;
function switchTab(t){
  activeTab=t;
  document.querySelectorAll('.tab').forEach(e=>e.classList.remove('active'));
  document.querySelectorAll('.panel').forEach(e=>e.classList.remove('active'));
  document.getElementById('tab-'+t).classList.add('active');
  document.getElementById('p-'+t).classList.add('active');
  if(t==='admin' && !_admAuth) document.getElementById('adm-user').focus();
  if(t==='admin' && _admAuth) admLoadStatus();
  if(t==='hub' && !_hubLoaded){ loadNotes(); _hubLoaded=true; }
  if(t==='power' && !_powerLoaded){ loadPowerSettings(); setPowerPeriod('24h'); _powerLoaded=true; }
}
function aTab(el){
  document.querySelectorAll('.atab').forEach(e=>e.classList.remove('active'));
  document.querySelectorAll('.asect').forEach(e=>e.classList.remove('active'));
  el.classList.add('active');
  document.getElementById('as-'+el.dataset.s).classList.add('active');
  if(el.dataset.s==='mdl') loadModels();
  if(el.dataset.s==='logs') loadLogs();
}

// ── Toast ─────────────────────────────────────────────────────────────────
let _tt;
function toast(msg,type='ok'){
  const e=document.getElementById('toast');
  e.textContent=msg; e.className='show '+type;
  clearTimeout(_tt); _tt=setTimeout(()=>e.className='',4000);
}

// ── Helpers ───────────────────────────────────────────────────────────────
function st(id,v){const e=document.getElementById(id);if(e)e.textContent=v}
function setDot(id,on){const e=document.getElementById(id);if(e)e.className='sd '+(on?'on':'off')}
const pCol=p=>p>=85?'var(--red)':p>=65?'var(--yellow)':'var(--neon)';
const fCls=p=>p>=85?'fr':p>=65?'fy':'fn';
const bCls=p=>p>=85?'badge bct':p>=65?'badge bwn':'badge bok';
const bTxt=p=>p>=85?'CRITIQUE':p>=65?'ÉLEVÉ':'OK';
function fKB(kb){if(kb>=1024*100)return{v:(kb/1024/1024).toFixed(2),u:'Go/s'};if(kb>=1024)return{v:(kb/1024).toFixed(1),u:'Mo/s'};return{v:kb,u:'Ko/s'}}
function fMB(mb){return mb>=1024?(mb/1024).toFixed(1)+' Go':mb+' Mo'}
function setBar(id,p){const e=document.getElementById(id);if(!e)return;e.style.width=p+'%';e.className='bf '+fCls(p)}
function sBdg(id,p,lbl=null){const e=document.getElementById(id);if(!e)return;e.className=bCls(p);e.textContent=lbl||bTxt(p)}

// ── Sparklines ────────────────────────────────────────────────────────────
const N=60,H={cpu:[],ram:[],rx:[],tx:[]};
const push=(k,v)=>{H[k].push(v);if(H[k].length>N)H[k].shift()};
function spPaths(d,w=300,h=48,mx=null){
  if(d.length<2)return{l:'',a:''};
  const M=mx??Math.max(...d,1),step=w/(N-1);
  const pad=Array(N-d.length).fill(0).concat(d);
  const pts=pad.map((v,i)=>[i*step,h-(v/M)*(h*.88)-h*.06]);
  const l=pts.map((p,i)=>(i===0?`M${p[0].toFixed(1)},${p[1].toFixed(1)}`:`L${p[0].toFixed(1)},${p[1].toFixed(1)}`)).join('');
  return{l,a:l+` L${pts[pts.length-1][0].toFixed(1)},${h} L0,${h} Z`};
}
function setSp(li,ai,d,mx=null){const{l,a}=spPaths(d,300,48,mx);const le=document.getElementById(li),ae=ai?document.getElementById(ai):null;if(le)le.setAttribute('d',l);if(ae)ae.setAttribute('d',a)}

// ── Gauge ─────────────────────────────────────────────────────────────────
const CIRC=2*Math.PI*42,ARC=CIRC*(240/360);
function setG(id,pct,col){const e=document.getElementById(id);if(!e)return;const off=ARC-(pct/100)*ARC;e.style.strokeDasharray=`${ARC} ${CIRC-ARC}`;e.style.strokeDashoffset=off;e.style.stroke=col}

// ── Stats update ──────────────────────────────────────────────────────────
function update(d){
  if(!d)return;
  updateBanner(d.install_progress||null);
  updatePendingConfirm(d.pending_confirm||null);
  renderHubLinks(d.services||{});
  renderPowerLive(d.power||null);
  renderMomoryCard(d.momory||null);
  st('ch',d.hostname||'—');st('cu',d.uptime?.human||'—');
  const cpu=d.cpu||{},cp=cpu.pct||0; push('cpu',cp);
  st('mt-cpu',Math.round(cp));st('mt-cpu-s',`${cpu.freq_mhz>0?cpu.freq_mhz:'N/A'} MHz · ${cpu.temp_c?cpu.temp_c+'°C':'N/A'}`);
  st('cg-p',Math.round(cp)+'%');setG('cg-g',cp,pCol(cp));
  st('cf',cpu.freq_mhz>0?cpu.freq_mhz:'N/A');st('ct2',cpu.temp_c?`Temp: ${cpu.temp_c}°C`:'Temp: N/A');st('cm2',cpu.model||'—');
  sBdg('cb',cp);setSp('spc-l','spc-a',H.cpu,100);
  const cg=document.getElementById('cores');
  if(cpu.cores?.length)cg.innerHTML=cpu.cores.map(c=>{const p=Math.round(c.pct||0);return`<div class="ci"><div class="cin">${c.name.replace('cpu','c')}</div><div class="civ" style="color:${pCol(p)}">${p}%</div><div class="cib"><div class="cif" style="width:${p}%;background:${pCol(p)}"></div></div></div>`}).join('');
  const mem=d.memory||{},rp=mem.ram_pct||0; push('ram',rp);
  st('mt-ram',fMB(mem.ram_used_mb||0));st('mt-ram-s',`${fMB(mem.ram_used_mb||0)} / ${fMB(mem.ram_total_mb||0)}`);
  st('rg-p',Math.round(rp)+'%');setG('rg-g',rp,pCol(rp));
  st('ru',fMB(mem.ram_used_mb||0));st('rt2',`/ ${fMB(mem.ram_total_mb||0)} total`);
  st('rpl',(rp||0).toFixed(1)+'%');st('spl',(mem.swap_pct||0).toFixed(1)+'%');
  setBar('rb_',rp);setBar('sb_',mem.swap_pct||0);sBdg('rb',rp);setSp('spr-l','spr-a',H.ram,100);
  const gpu=d.gpu||{},gd=document.getElementById('gpd');
  if(gpu.available){
    const gp=gpu.util_pct||0,mp=gpu.mem_pct||0,tp=gpu.temp_c||0;
    sBdg('gpb',gp,gpu.name?.split(' ')[0]||'GPU');st('mt-gpu',Math.round(gp)+'%');st('mt-gpu-s',`VRAM ${fMB(gpu.mem_used_mb||0)} · ${tp}°C`);
    gd.innerHTML=`<div style="font-size:11px;color:var(--muted);font-family:var(--mono);margin-bottom:10px">${gpu.name||'GPU'}</div><div class="gg"><div class="gb"><div class="gbl">Utilisation</div><div class="gbv" style="color:${pCol(gp)}">${Math.round(gp)}<span style="font-size:13px;color:var(--muted)">%</span></div><div class="bg" style="margin-top:5px"><div class="bt"><div class="bf ${fCls(gp)}" style="width:${gp}%"></div></div></div></div><div class="gb"><div class="gbl">Température</div><div class="gbv" style="color:${tp>=80?'var(--red)':tp>=70?'var(--yellow)':'var(--neon)'}">${tp}<span style="font-size:12px;color:var(--muted)">°C</span></div></div><div class="gb"><div class="gbl">VRAM</div><div class="gbv" style="color:var(--purple);font-size:15px">${fMB(gpu.mem_used_mb||0)}<span style="font-size:9px;color:var(--muted)"> / ${fMB(gpu.mem_total_mb||0)}</span></div><div class="bg" style="margin-top:5px"><div class="bt"><div class="bf fp" style="width:${mp}%"></div></div></div></div><div class="gb"><div class="gbl">Puissance</div><div class="gbv" style="font-size:15px">${Math.round(gpu.power_w||0)}<span style="font-size:10px;color:var(--muted)"> W</span></div>${gpu.power_limit_w?`<div style="font-size:9px;color:var(--muted);font-family:var(--mono);margin-top:2px">/ ${Math.round(gpu.power_limit_w)} W max</div>`:''}</div></div>`;
  }else{document.getElementById('gpb').textContent='N/A';document.getElementById('gpb').className='badge bwn';st('mt-gpu','N/A');st('mt-gpu-s','CPU only');gd.innerHTML='<div style="color:var(--muted);font-size:12px;padding:16px 0">Aucun GPU dédié</div>'}
  const svc=d.services||{};
  setDot('do',svc.ollama?.active);setDot('dw',svc.webui?.active);setDot('dd',svc.docker?.active);
  const ou=svc.ollama?.url||'http://localhost:11434',wu=svc.webui?.url||'http://localhost:8080';
  const lo=document.getElementById('lo'),lw=document.getElementById('lw');
  if(lo)lo.href=ou;if(lw)lw.href=wu;
  st('mo',svc.ollama?.active?`${svc.ollama.model_count||0} modèle(s) · ${ou}`:'Arrêté');
  st('mw2',svc.webui?.active?svc.webui.status||'actif':'Container arrêté');
  st('md',svc.docker?.active?`${svc.docker.containers||0} container(s)`:'Arrêté');
  const mw=document.getElementById('mw'),ms=svc.ollama?.models||[];
  if(mw)mw.innerHTML=ms.slice(0,6).map(m=>`<span class="mtag">${m.split(':')[0]}</span>`).join('')+(ms.length>6?`<span class="mtag" style="opacity:.5">+${ms.length-6}</span>`:'');
  const net=d.network||{};st('ni',net.default_iface||'—');st('nip',net.local_ip||'—');
  const iface=(net.interfaces||[]).find(i=>i.name===net.default_iface)||(net.interfaces||[])[0];
  if(iface){
    const rx=fKB(iface.rx_kb_s||0),tx=fKB(iface.tx_kb_s||0);
    push('rx',iface.rx_kb_s||0);push('tx',iface.tx_kb_s||0);
    st('nrx',rx.v);st('nrxu',rx.u);st('ntx',tx.v);st('ntxu',tx.u);
    st('nrxt',`Total: ${iface.rx_total_mb} Mo`);st('ntxt',`Total: ${iface.tx_total_mb} Mo`);
    st('mt-net',rx.v+' '+rx.u);st('mt-net-s',`↓ ${rx.v}${rx.u} · ↑ ${tx.v}${tx.u}`);
    const nm=Math.max(...H.rx,...H.tx,1);setSp('spn-l','spn-a',H.rx,nm);setSp('spn-t',null,H.tx,nm);
  }
  const dl=document.getElementById('dl2');
  if(dl)dl.innerHTML=(d.disks||[]).map(dk=>{const p=dk.pct||0;const io=(dk.read_kb_s!=null)?`R: ${fKB(dk.read_kb_s).v}${fKB(dk.read_kb_s).u} · W: ${fKB(dk.write_kb_s||0).v}${fKB(dk.write_kb_s||0).u}`:'';return`<div class="dr"><div class="dh"><div><div class="dd">${dk.device.replace('/dev/','')}</div><div class="dm">${dk.mount}</div></div><span class="${bCls(p)}">${bTxt(p)}</span></div><div style="display:flex;justify-content:space-between;font-size:10px;color:var(--muted);font-family:var(--mono);margin-bottom:4px"><span>${fMB(dk.used_mb)} utilisé</span><span>${p}%</span></div><div class="bt"><div class="bf ${fCls(p)}" style="width:${p}%"></div></div><div class="dns"><span>Libre: ${fMB(dk.avail_mb)}</span><span>Total: ${fMB(dk.size_mb)}</span></div>${io?`<div class="dio">${io}</div>`:''}</div>`;}).join('');
}


// ── Bannière installation ─────────────────────────────────────────────────
function updateBanner(prog){
  const bEl=document.getElementById('install-banner');
  if(!prog||!prog.active){bEl.style.display='none';return}
  bEl.style.display='block';
  const pct=prog.pct||0;
  document.getElementById('ib-bar').style.width=pct+'%';
  document.getElementById('ib-pct').textContent=pct;
  document.getElementById('ib-label').textContent=prog.substep_label
    ? `${prog.substep_label} — ${prog.substep_pct||0}%`
    : (prog.label||prog.step_desc||prog.step_name||'Installation…');
  const sc=prog.step_current||0,st=prog.step_total||0;
  document.getElementById('ib-step').textContent=st?`Étape ${sc}/${st}`:'';
  // Points de progression
  const dotsEl=document.getElementById('ib-dots');
  if(prog.plan&&prog.plan.length){
    dotsEl.innerHTML=prog.plan.map((_,i)=>{
      const cls=i<sc-1?'ib-dot done':i===sc-1?'ib-dot curr':'ib-dot';
      return`<div class="${cls}" title="${prog.plan[i]}"></div>`;
    }).join('');
  }
}

let _lastConfirmQid=null;
function updatePendingConfirm(pc){
  let modal=document.getElementById('confirm-modal');
  if(!pc || !pc.pending){
    if(modal) modal.remove();
    _lastConfirmQid=null;
    return;
  }
  if(pc.qid===_lastConfirmQid && modal) return;   // déjà affiché, ne pas re-render
  _lastConfirmQid=pc.qid;
  if(modal) modal.remove();
  modal=document.createElement('div');
  modal.id='confirm-modal';
  modal.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:9999;display:flex;align-items:center;justify-content:center';
  modal.innerHTML=`
    <div style="background:var(--bg2,#1a1a2e);border:1px solid var(--neon);border-radius:10px;padding:24px;max-width:420px;width:90%">
      <div style="font-size:14px;color:var(--yellow);margin-bottom:14px">⚠ Confirmation requise (installation en cours)</div>
      <div style="font-size:14px;color:#fff;margin-bottom:20px;line-height:1.4">${pc.question||''}</div>
      <div style="display:flex;gap:10px;justify-content:flex-end">
        <button onclick="answerConfirm('${pc.qid}','non')" style="background:#444;color:#fff;border:none;padding:8px 16px;border-radius:6px;cursor:pointer">Non</button>
        <button onclick="answerConfirm('${pc.qid}','oui')" style="background:var(--green,#2ecc71);color:#000;border:none;padding:8px 16px;border-radius:6px;cursor:pointer;font-weight:600">Oui</button>
      </div>
    </div>`;
  document.body.appendChild(modal);
}
async function answerConfirm(qid,answer){
  try{
    const d=await _aapi('/api/admin/confirm-answer',{qid,answer});
    if(d?.ok){
      document.getElementById('confirm-modal')?.remove();
      _lastConfirmQid=null;
      toast(`Réponse '${answer}' envoyée`,'ok');
    }else{
      toast(d?.msg||'Erreur','err');
    }
  }catch(e){ toast('Erreur réseau: '+e,'err'); }
}

// ── HUB : accès rapide, notes, dev tools ────────────────────────────────────
const GITHUB_URL='https://github.com/Momorie59/ia-local-automatique';

function renderHubLinks(svc){
  const ol=svc.ollama||{}, wu=svc.webui||{};
  const olUrl=ol.url||'http://127.0.0.1:11434';
  const wuUrl=wu.url||'http://localhost:8080';

  const cards=[
    {icon:'🦙',name:'Ollama (API)',up:!!ol.active,url:olUrl,
     meta:ol.active?`${ol.model_count||0} modèle(s) installé(s)`:'Service arrêté',
     actions:`<button class="btn-s btn-go" onclick="window.open('${olUrl}/api/tags','_blank')">Ouvrir</button>
              <button class="btn-s" onclick="copyText('${olUrl}')">📋 Copier</button>`},
    {icon:'💬',name:'Open WebUI',up:!!wu.active,url:wuUrl,
     meta:wu.active?'En ligne — clique pour discuter avec tes modèles':'Service arrêté',
     actions:`<button class="btn-s btn-go" onclick="window.open('${wuUrl}','_blank')">Ouvrir</button>
              <button class="btn-s" onclick="copyText('${wuUrl}')">📋 Copier</button>`},
    {icon:'🐙',name:'Projet GitHub',up:null,url:GITHUB_URL,
     meta:'Code source, issues, mises à jour',
     actions:`<button class="btn-s btn-go" onclick="window.open('${GITHUB_URL}','_blank')">Ouvrir</button>
              <button class="btn-s" onclick="copyText('${GITHUB_URL}')">📋 Copier</button>`},
  ];

  const el=document.getElementById('hub-links');
  if(el) el.innerHTML=cards.map(c=>`
    <div class="link-card">
      <div class="lc-top">
        <div class="lc-name"><span class="lc-icon">${c.icon}</span>${c.name}</div>
        ${c.up===null?'':`<div class="lc-status ${c.up?'up':'down'}"></div>`}
      </div>
      <div class="lc-url">${c.url}</div>
      <div class="lc-actions">${c.actions}</div>
      <div class="lc-meta">${c.meta}</div>
    </div>`).join('');

  // Rafraîchit aussi le snippet de connexion éditeur (Android Studio / IntelliJ)
  const apiEl=document.getElementById('dev-api-url');
  if(apiEl) apiEl.textContent=olUrl+'/v1';
  const hintEl=document.getElementById('dev-models-hint');
  if(hintEl) hintEl.textContent='Modèles disponibles : '+((ol.models&&ol.models.length)?ol.models.join(', '):'aucun pour le moment');
}

let _momoryCardFilled = false;
function renderMomoryCard(momory){
  if(!momory) return;
  window._momoryInfo = momory;

  // Le bloc config (résumé) et le hint modèles peuvent se rafraîchir en direct,
  // ce ne sont pas des champs édités par l'utilisateur.
  const hint=document.getElementById('momory-models-hint');
  if(hint) hint.textContent=`Modèle chat : ${momory.chat_model||'aucun'}  ·  Modèle coder : ${momory.coder_model||'aucun'}`;

  // Les commandes/le config snippet sont "contenteditable" : on ne les
  // remplit qu'UNE fois au chargement pour ne jamais écraser une édition
  // en cours de l'utilisateur au poll suivant (toutes les 2s).
  if(_momoryCardFilled) return;
  _momoryCardFilled = true;

  const host = momory.host || location.hostname || '—';
  const port = location.port || '7842';
  const dlUrl = `http://${host}:${port}/download/momory-cli.zip`;

  const el=document.getElementById('momory-config-snippet');
  if(el) el.textContent=`host: ${momory.host||'—'} · port: ${momory.port||11434}`+
    (momory.qdrant_port?` · qdrant: ${momory.qdrant_port}`:'');

  const dlLink = document.getElementById('momory-download-link');
  if(dlLink) dlLink.href = dlUrl;

  const psEl = document.getElementById('momory-cmd-ps');
  if(psEl) psEl.textContent = `Invoke-WebRequest ${dlUrl} -OutFile momory-cli.zip; Expand-Archive momory-cli.zip -Force; cd momory-cli; npm install; npm run build; npm link`;

  const cmdEl = document.getElementById('momory-cmd-cmd');
  if(cmdEl) cmdEl.textContent = `curl -o momory-cli.zip ${dlUrl} && tar -xf momory-cli.zip && cd momory-cli && npm install && npm run build && npm link`;

  const nixEl = document.getElementById('momory-cmd-nix');
  if(nixEl) nixEl.textContent = `curl -O ${dlUrl} && unzip -o momory-cli.zip && cd momory-cli && npm install && npm run build && npm link`;
}
function copyMomoryConfig(){
  const m=window._momoryInfo;
  if(!m){ toast('Infos pas encore chargées','err'); return; }
  const yaml=`server:\n  host: ${m.host}\n  port: ${m.port}\nmodels:\n  chat: ${m.chat_model||'?'}\n  coder: ${m.coder_model||'?'}\n  embed: nomic-embed-text`+
    (m.qdrant_port?`\nmemory:\n  enabled: true\n  qdrant:\n    host: ${m.host}\n    port: ${m.qdrant_port}`:'');
  copyText(yaml);
}

function copyText(txt){
  navigator.clipboard?.writeText(txt).then(()=>toast('Copié dans le presse-papier','ok'))
    .catch(()=>toast('Impossible de copier','err'));
}
function copySnippet(id){
  const t=document.getElementById(id)?.textContent||'';
  copyText(t);
}

let _allNotes=[], _notesLoaded=false, _trashOpen=false;

async function loadNotes(){
  try{
    const r=await fetch('/api/notes'); const d=await r.json();
    _allNotes = d.notes||[];
    _notesLoaded = true;
    renderNotes();
  }catch(e){ /* silencieux — pas bloquant */ }
}

function renderNotes(){
  const active = _allNotes.filter(n=>!n.deleted).sort((a,b)=>b.created_at-a.created_at);
  const trashed = _allNotes.filter(n=>n.deleted).sort((a,b)=>(b.deleted_at||0)-(a.deleted_at||0));

  const listEl = document.getElementById('notes-list');
  if(listEl) listEl.innerHTML = active.length
    ? active.map(n=>`
      <div class="note-item">
        <div style="flex:1">
          <div class="note-text">${_esc(n.text)}</div>
          <div class="note-meta">${new Date(n.created_at*1000).toLocaleString('fr-FR')}</div>
        </div>
        <div class="note-actions">
          <button class="note-btn danger" onclick="deleteNote('${n.id}')" title="Supprimer (récupérable dans la corbeille)">🗑</button>
        </div>
      </div>`).join('')
    : '<div class="notes-empty">Aucune note pour le moment.</div>';

  document.getElementById('trash-count').textContent = `(${trashed.length})`;
  const trashListEl = document.getElementById('trash-list');
  if(trashListEl) trashListEl.innerHTML = trashed.length
    ? trashed.map(n=>`
      <div class="note-item trashed">
        <div style="flex:1">
          <div class="note-text">${_esc(n.text)}</div>
          <div class="note-meta">Supprimée le ${n.deleted_at?new Date(n.deleted_at*1000).toLocaleString('fr-FR'):'?'}</div>
        </div>
        <div class="note-actions">
          <button class="note-btn ok" onclick="restoreNote('${n.id}')" title="Restaurer">↩ Restaurer</button>
        </div>
      </div>`).join('')
    : '<div class="notes-empty">Corbeille vide.</div>';
}

function _esc(s){
  const d=document.createElement('div'); d.textContent=s; return d.innerHTML;
}

async function _notesApi(action, extra={}){
  try{
    const r=await fetch('/api/notes',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({action, ...extra})});
    const d=await r.json();
    if(d.ok){ _allNotes = d.notes; renderNotes(); }
    else toast(d.msg||'Erreur','err');
    return d;
  }catch(e){ toast('Erreur réseau: '+e,'err'); }
}

async function addNote(){
  const input = document.getElementById('note-new-input');
  const text = input.value.trim();
  if(!text) return;
  const d = await _notesApi('create', {text});
  if(d?.ok) input.value='';
}
async function deleteNote(id){ await _notesApi('delete', {id}); }
async function restoreNote(id){ await _notesApi('restore', {id}); toast('Note restaurée','ok'); }
async function emptyTrash(){
  if(!confirm('Supprimer définitivement toutes les notes de la corbeille ? Cette action est irréversible.')) return;
  await _notesApi('empty_trash');
  toast('Corbeille vidée','ok');
}
function toggleTrash(){
  _trashOpen = !_trashOpen;
  document.getElementById('trash-panel').style.display = _trashOpen ? 'block' : 'none';
}

document.addEventListener('DOMContentLoaded',()=>{
  document.getElementById('note-new-input')?.addEventListener('keydown', (e)=>{
    if(e.key==='Enter') addNote();
  });
});

// ── ÉNERGIE ──────────────────────────────────────────────────────────────
let _pwSettings = {kwh_price: 0.2016, provider: '', retention_days: 90};
let _pwPeriod = '24h';

function renderPowerLive(power){
  if(!power) return;
  const errBox = document.getElementById('pw-error-box');
  if(errBox){
    if(power.error && power.error !== 'pas encore échantillonné'){
      errBox.style.display = 'block';
      errBox.textContent = '⚠ Erreur de calcul côté serveur : ' + power.error;
    } else {
      errBox.style.display = 'none';
    }
  }
  const set=(id,val)=>{const e=document.getElementById(id); if(e) e.textContent=val;};
  set('pw-total', `${power.total_w||0} W`);
  set('pw-cpu', `${power.cpu_w||0} W`);
  set('pw-cpu-src', power.cpu_real ? '✓ Mesure réelle (RAPL)' : '≈ Estimation');
  set('pw-gpu', `${power.gpu_w||0} W`);
  set('pw-gpu-src', power.gpu_real ? '✓ Mesure réelle (capteur GPU)' : (power.gpu_w ? '≈ Estimation' : 'Pas de GPU actif'));
  const rest = Math.round(((power.disk_w||0)+(power.ram_w||0)+(power.base_w||0))*10)/10;
  set('pw-rest', `${rest} W`);

  const price = _pwSettings.kwh_price || 0;
  const kw = (power.total_w||0) / 1000;
  const perDay = (kw * 24 * price).toFixed(2);
  const perMonth = (kw * 24 * 30 * price).toFixed(2);
  set('pw-cost-now', `≈ ${perDay} €/jour · ${perMonth} €/mois`);
}

async function loadPowerSettings(){
  try{
    const r = await fetch('/api/power/settings');
    _pwSettings = await r.json();
    document.getElementById('pw-price-input').value = _pwSettings.kwh_price;
    document.getElementById('pw-provider-input').value = _pwSettings.provider || '';
    document.getElementById('pw-retention-input').value = _pwSettings.retention_days;
  }catch(e){ /* silencieux */ }
}

async function savePowerSettings(){
  const stateEl = document.getElementById('pw-settings-state');
  const price = parseFloat(document.getElementById('pw-price-input').value) || 0;
  const provider = document.getElementById('pw-provider-input').value.trim();
  const retention = parseInt(document.getElementById('pw-retention-input').value) || 90;
  try{
    const r = await fetch('/api/power/settings', {method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({kwh_price: price, provider, retention_days: retention})});
    const d = await r.json();
    if(d.ok){
      _pwSettings = d;
      stateEl.textContent = 'Enregistré · ' + new Date().toLocaleTimeString('fr-FR');
      toast('Réglages énergie enregistrés', 'ok');
      setPowerPeriod(_pwPeriod);   // recalcule le coût affiché avec le nouveau prix
    } else {
      stateEl.textContent = 'Erreur : ' + (d.msg||'?');
    }
  }catch(e){ stateEl.textContent = 'Erreur réseau'; }
}

function setPowerPeriod(period){
  _pwPeriod = period;
  document.querySelectorAll('.pw-period').forEach(b=>b.classList.toggle('active', b.dataset.period===period));
  loadPowerHistory(period);
}

async function loadPowerHistory(period){
  try{
    const r = await fetch('/api/power/history?period='+encodeURIComponent(period));
    const d = await r.json();
    drawPowerChart(d.points||[]);
    const price = _pwSettings.kwh_price || 0;
    const cost = (d.kwh_period * price).toFixed(2);
    const labels = {'24h':'les dernières 24h','7d':'les 7 derniers jours','30d':'les 30 derniers jours'};
    const summary = document.getElementById('pw-period-summary');
    if(d.points.length===0){
      summary.textContent = `Pas encore assez d'historique pour ${labels[period]} — reviens un peu plus tard (un point est enregistré chaque minute).`;
    } else {
      summary.textContent = `Moyenne sur ${labels[period]} : ${d.avg_w} W · ${d.kwh_period} kWh consommés · ≈ ${cost} €`;
    }
  }catch(e){ /* silencieux */ }
}

function drawPowerChart(points){
  const svg = document.getElementById('pw-chart');
  if(!svg) return;
  if(points.length < 2){
    svg.innerHTML = '';
    return;
  }
  const W=700, H=220, padL=40, padR=10, padT=15, padB=25;
  const plotW = W-padL-padR, plotH = H-padT-padB;

  const vals = points.map(p=>p.total_w);
  const maxV = Math.max(...vals, 10) * 1.1;
  const minV = 0;
  const x = i => padL + (i/(points.length-1)) * plotW;
  const y = v => padT + plotH - ((v-minV)/(maxV-minV)) * plotH;

  let line = points.map((p,i)=>`${i===0?'M':'L'}${x(i).toFixed(1)},${y(p.total_w).toFixed(1)}`).join('');
  let area = line + ` L${x(points.length-1).toFixed(1)},${padT+plotH} L${padL},${padT+plotH} Z`;

  const firstTs = new Date(points[0].ts*1000);
  const lastTs = new Date(points[points.length-1].ts*1000);
  const fmt = d => d.toLocaleString('fr-FR', {day:'2-digit', month:'2-digit', hour:'2-digit', minute:'2-digit'});

  svg.innerHTML = `
    <line x1="${padL}" y1="${padT}" x2="${padL}" y2="${padT+plotH}" stroke="var(--br2)" stroke-width="1"/>
    <line x1="${padL}" y1="${padT+plotH}" x2="${W-padR}" y2="${padT+plotH}" stroke="var(--br2)" stroke-width="1"/>
    <text x="4" y="${padT+4}" fill="var(--muted2)" font-size="10" font-family="var(--mono)">${Math.round(maxV)}W</text>
    <text x="4" y="${padT+plotH}" fill="var(--muted2)" font-size="10" font-family="var(--mono)">0W</text>
    <path d="${area}" fill="var(--yellow)" opacity="0.12"/>
    <path d="${line}" fill="none" stroke="var(--yellow)" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round"/>
    <text x="${padL}" y="${H-6}" fill="var(--muted2)" font-size="9" font-family="var(--mono)">${fmt(firstTs)}</text>
    <text x="${W-padR}" y="${H-6}" fill="var(--muted2)" font-size="9" font-family="var(--mono)" text-anchor="end">${fmt(lastTs)}</text>
  `;
}


// ── Stats polling ─────────────────────────────────────────────────────────
let _errs=0;
async function pollStats(){
  try{
    const r=await fetch('/api/stats');
    if(!r.ok)throw new Error(r.status);
    const d=await r.json();
    if(d&&Object.keys(d).length>1){  // cache rempli (plus que {ts:...})
      update(d);_errs=0;
      document.getElementById('lp').style.background='var(--neon)';
    }
  }catch(e){
    _errs++;
    document.getElementById('lp').style.background=_errs>3?'var(--red)':'var(--yellow)';
  }
}

// ── Clock ─────────────────────────────────────────────────────────────────
function clk(){const t=new Date().toLocaleTimeString('fr-FR');st('ntime',t);st('ft',t)}
setInterval(clk,1000);clk();

// ══════════════════════════════════════════════════════════════════════════
// ADMIN
// ══════════════════════════════════════════════════════════════════════════
let _admAuth=false, _admUser='';

async function _aapi(ep,body={}){
  try{
    const r=await fetch(ep,{
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body:JSON.stringify(body)
    });
    if(!r.ok) return {ok:false,msg:'HTTP '+r.status};
    return await r.json();
  }catch(e){
    console.warn('[api]',ep,e.message);
    return {ok:false,msg:'Réseau: '+e.message};
  }
}

// Login
async function doLogin(){
  const u=document.getElementById('adm-user').value.trim();
  const p=document.getElementById('adm-pass').value;
  document.getElementById('lf-err').textContent='';
  const d=await _aapi('/api/admin/login',{user:u,pass:p});
  if(d?.ok){
    _admAuth=true;_admUser=u;
    document.getElementById('adm-login').style.display='none';
    document.getElementById('adm-content').style.display='block';
    document.getElementById('adm-username').textContent=u;
    document.getElementById('tab-lock').textContent='🔓';
    admLoadStatus();
  }else{
    document.getElementById('lf-err').textContent=d?.msg||'Identifiants incorrects';
  }
}

function doLogout(){
  _admAuth=false;
  document.getElementById('adm-login').style.display='flex';
  document.getElementById('adm-content').style.display='none';
  document.getElementById('adm-pass').value='';
  document.getElementById('tab-lock').textContent='🔒';
  _aapi('/api/admin/logout');
}

// Services admin
async function admLoadStatus(){
  const d=await _aapi('/api/admin/status');
  if(!d||!d.ok) return;
  const s=d.data||{};
  const SVCS=[
    {k:'ollama',    ic:'🦙',nm:'Ollama'},
    {k:'webui',     ic:'🖥️',nm:'Open WebUI'},
    {k:'docker',    ic:'🐋',nm:'Docker'},
    {k:'dashboard', ic:'📊',nm:'Dashboard'},
  ];
  document.getElementById('adm-svc-grid').innerHTML=SVCS.map(({k,ic,nm})=>{
    const sv=s.services?.[k]||{};const on=sv.active;
    const mt=[sv.version?`v${sv.version}`:null].filter(Boolean).join(' ')|| (on?'actif':'arrêté');
    const lnk=sv.url?`<a class="btn-s btn-lnk" href="${sv.url}" target="_blank">↗</a>`:'';
    return`<div class="svc-card"><div class="svc-hd"><div class="sled ${on?'on':'off'}"></div><div class="svc-nm">${ic} ${nm}</div></div><div class="svc-mt">${mt}</div><div class="svc-bts"><button class="btn-s btn-go" onclick="svcAct('${k}','start')">Démarrer</button><button class="btn-s btn-stop" onclick="svcAct('${k}','stop')">Arrêter</button><button class="btn-s btn-re" onclick="svcAct('${k}','restart')">Redémarrer</button>${lnk}</div></div>`;
  }).join('');
  // Afficher/cacher l'alerte mot de passe par défaut
  const pwAlert=document.getElementById('adm-pw-alert');
  if(pwAlert) pwAlert.style.display=s.is_default_password?'flex':'none';
  // Infos système (onglet Système)
  const sysInfo=[
    {k:'Hôte',    v:s.hostname||'—'},
    {k:'Uptime',  v:s.uptime||'—'},
    {k:'Disque',  v:s.disk||'—'},
    {k:'Modèles', v:(s.models?.length||0)+' installé(s)'},
    {k:'Admin',   v:s.admin_user||'admin'},
    {k:'MDP',     v:s.is_default_password?'⚠ Défaut':'✓ Personnalisé'},
  ];
  const sysEl=document.getElementById('adm-sysinfo2')||document.getElementById('adm-sysinfo');
  if(sysEl) sysEl.innerHTML=sysInfo.map(i=>`<div style="background:var(--s2);border:1px solid var(--br);border-radius:8px;padding:9px 12px"><div style="font-size:9px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:var(--muted);margin-bottom:3px">${i.k}</div><div style="font-size:12px;font-family:var(--mono);color:${i.k==='MDP'&&i.v.includes('⚠')?'var(--red)':'#fff'}">${i.v}</div></div>`).join('');
}

async function svcAct(svc,act){
  toast(`${act} ${svc}…`,'inf');
  const d=await _aapi('/api/admin/service',{action:act,service:svc});
  toast(d?.msg||(d?.ok?'OK':'Erreur'),d?.ok?'ok':'err');
  setTimeout(admLoadStatus,1500);
}

// Updates
async function doUpd(t,btn){
  btn.disabled=true;btn.innerHTML='<span class="spin"></span>En cours…';
  const out=document.getElementById('upd-out');
  out.style.display='block';out.textContent='Mise à jour en cours, patientez…';
  const d=await _aapi('/api/admin/update',{target:t});
  colorLog2(out,d?.msg||'');
  toast(d?.ok?'Mise à jour terminée ✓':'Erreur lors de la MAJ',d?.ok?'ok':'err');
  btn.disabled=false;btn.textContent='Mettre à jour';
}

// Models
async function loadModels(){
  const g=document.getElementById('mdl-grid');g.innerHTML='<div style="color:var(--muted);font-size:12px">Chargement…</div>';
  const d=await _aapi('/api/admin/models',{action:'list'});
  const ms=d?.models||[];
  st('mdl-count',ms.length?`${ms.length} modèle(s)`:'');
  if(!ms.length){g.innerHTML='<div style="color:var(--muted);font-size:12px;padding:12px 0">Aucun modèle installé</div>';return}
  g.innerHTML=ms.map(m=>{const nm=m.name||m;const sz=m.size?(m.size/1e9).toFixed(1)+' Go':'?';return`<div class="mc"><div class="mc-ico">🧠</div><div class="mc-b"><div class="mc-n">${nm}</div><div class="mc-s">${sz}</div></div><button class="mc-del" onclick="delMdl('${nm}',this)">Suppr.</button></div>`}).join('');
}

async function doPull(){
  const nm=document.getElementById('pull-nm').value.trim();if(!nm)return;
  const btn=document.getElementById('pull-btn');
  const input=document.getElementById('pull-nm');
  toast(`Téléchargement de ${nm} lancé…`,'inf');
  const d=await _aapi('/api/admin/models',{action:'pull',name:nm});
  if(!d?.ok){ toast(d?.msg||'Erreur','err'); return; }
  if(btn){ btn.disabled=true; btn.textContent='⏳ En cours…'; }
  if(input) input.disabled=true;

  // On interroge le vrai statut du téléchargement au lieu de considérer
  // "lancé" comme "terminé" — la liste ne se rafraîchissait jamais avant,
  // et un échec (mauvais nom, réseau) passait totalement inaperçu.
  const started=Date.now();
  const maxWaitMs=20*60*1000;   // 20 min — large pour les gros modèles
  const poll=async()=>{
    if(Date.now()-started > maxWaitMs){
      toast(`${nm} : toujours en cours après 20 min — vérifie manuellement plus tard`,'err');
      resetPullUI(); return;
    }
    const s=await _aapi('/api/admin/models',{action:'pull_status',name:nm});
    if(s?.status==='running' || s?.status==='unknown'){
      setTimeout(poll, 4000);
      return;
    }
    if(s?.status==='done'){
      toast(`✓ ${nm} installé`,'ok');
      document.getElementById('pull-nm').value='';
      loadModels();
    } else {
      toast(`✗ Échec du téléchargement de ${nm}`,'err');
      if(s?.detail) console.warn('Détail échec pull:', s.detail);
    }
    resetPullUI();
  };
  setTimeout(poll, 3000);   // laisse le process démarrer avant le 1er check
}
function resetPullUI(){
  const btn=document.getElementById('pull-btn');
  const input=document.getElementById('pull-nm');
  if(btn){ btn.disabled=false; btn.textContent='Pull'; }
  if(input) input.disabled=false;
}

async function delMdl(nm,btn){
  if(!confirm(`Supprimer "${nm}" ?`))return;
  btn.disabled=true;btn.textContent='…';
  const d=await _aapi('/api/admin/models',{action:'delete',name:nm});
  toast(d?.msg||(d?.ok?'Supprimé':'Erreur'),d?.ok?'ok':'err');
  loadModels();
}

// Logs
function colorLog2(el,text){
  el.innerHTML='';
  (Array.isArray(text)?text:String(text).split('\n')).forEach(line=>{
    const s=document.createElement('span');s.className='ll';
    if(/error|fail|crit|fatal/i.test(line))s.classList.add('err');
    else if(/warn/i.test(line))s.classList.add('warn');
    else if(/start|ready|active|ok|success/i.test(line))s.classList.add('ok2');
    s.textContent=line;el.appendChild(s);el.appendChild(document.createTextNode('\n'));
  });
  el.scrollTop=el.scrollHeight;
}

async function loadLogs(){
  const src=document.getElementById('log-src').value;
  const n=document.getElementById('log-n').value;
  const d=await _aapi('/api/admin/logs',{source:src,lines:parseInt(n)});
  colorLog2(document.getElementById('log-box'),d?.lines||[]);
}

// ── Installation depuis l'interface web ───────────────────────────────
async function saveScriptPath(){
  const p=document.getElementById('script-path-in').value.trim();
  if(!p){toast('Entrez un chemin','err');return}
  const d=await _aapi('/api/admin/set-installer-path',{path:p});
  toast(d?.msg||(d?.ok?'Chemin enregistré':'Erreur'),d?.ok?'ok':'err');
}
async function doInstall(){
  const btn=event.target; btn.disabled=true;
  const out=document.getElementById('inst-out');
  out.textContent='⏳ Lancement en cours…';
  try{
    const d=await _aapi('/api/admin/install',{action:'full'});
    out.style.color=d.ok?'var(--neon)':'var(--red)';
    out.textContent=d.msg||'Erreur inconnue';
    if(d.ok){ setTimeout(checkInstallStatus,2000); }
  }catch(e){
    out.style.color='var(--red)'; out.textContent='Erreur réseau: '+e;
  }finally{ btn.disabled=false; }
}

async function cancelInstall(){
  if(!confirm("Annuler l'installation en cours ?\nLes paquets déjà installés resteront en place, mais l'installation sera incomplète.")) return;
  const out=document.getElementById('inst-out');
  if(out){ out.style.color='var(--muted)'; out.textContent='⏳ Annulation en cours…'; }
  try{
    const d=await _aapi('/api/admin/install-cancel',{});
    toast(d?.msg||(d?.ok?'Installation annulée':'Erreur'),d?.ok?'ok':'err');
    checkInstallStatus();
  }catch(e){
    toast('Erreur réseau: '+e,'err');
  }
}

async function checkInstallStatus(){
  try{
    const r=await fetch('/api/stats');
    if(!r.ok) return;
    const d=await r.json();
    const pg=d.progress||{};
    const sec=document.getElementById('inst-progress-sec');
    const logSec=document.getElementById('inst-log-sec');
    const div=document.getElementById('inst-progress');
    if(pg.active){
      // Afficher les sections seulement si installation en cours
      if(sec) sec.style.display='block';
      if(logSec) logSec.style.display='block';
      const pct=pg.pct||0;
      const bar='█'.repeat(Math.round(pct/5))+'░'.repeat(20-Math.round(pct/5));
      const sub = pg.substep_label ? `
        <div style="font-family:var(--mono);font-size:12px;color:var(--muted);margin-bottom:8px">
          ⬇ ${pg.substep_label} — ${pg.substep_pct||0}%
        </div>` : '';
      if(div) div.innerHTML=`
        <div style="font-size:13px;color:var(--neon);margin-bottom:8px">
          ${pg.step_name||'En cours'} — ${pg.step_desc||''}
        </div>
        <div style="font-family:var(--mono);font-size:14px;color:var(--yellow);margin-bottom:8px">
          [${bar}] ${pct}%
        </div>
        ${sub}
        <div style="font-size:12px;color:var(--muted);margin-bottom:10px">
          Étape ${pg.step_current||0}/${pg.step_total||0} · ${pg.label||'Installation en cours'}
        </div>
        <button onclick="cancelInstall()" style="background:var(--red);color:#fff;border:none;padding:6px 14px;border-radius:6px;cursor:pointer;font-size:13px">
          ⛔ Annuler l'installation
        </button>`;
      loadInstallLog();
    } else {
      // Cacher les sections quand pas d'installation
      if(sec) sec.style.display='none';
      if(logSec) logSec.style.display='none';
    }
  }catch(e){}
}

async function loadInstallLog(){
  try{
    const d=await _aapi('/api/admin/logs',{source:'install',lines:60});
    const pre=document.getElementById('inst-log');
    pre.textContent=(d.lines||[]).join('\n')||'Aucun log disponible.';
    pre.scrollTop=pre.scrollHeight;
  }catch(e){}
}

// Rafraîchir l'état d'installation toutes les 3s quand l'onglet est actif
setInterval(()=>{
  const sect=document.getElementById('as-inst');
  if(sect && sect.classList.contains('active')) checkInstallStatus();
},3000);

async function sysDo(action){
  const labels={reboot:'Redémarrer la machine ?',shutdown:'Éteindre la machine ?',update_system:'Lancer la mise à jour système ?'};
  if(!confirm(labels[action]||'Confirmer ?')) return;
  const el=document.getElementById('sys-result');
  if(el) el.textContent='⏳ En cours…';
  const d=await _aapi('/api/admin/system',{action});
  if(el) el.textContent=d?.msg||(d?.ok?'✓ OK':'✗ Erreur');
}
async function changePw(){
  const u=document.getElementById('new-user').value.trim();
  const o=document.getElementById('old-pw').value;
  const n=document.getElementById('new-pw').value;
  const c=document.getElementById('conf-pw').value;
  if(n!==c){toast('Mots de passe différents','err');return}
  const d=await _aapi('/api/admin/change-password',{user:u,old:o,'new':n});
  toast(d?.msg||(d?.ok?'OK':'Erreur'),d?.ok?'ok':'err');
  if(d?.ok){setTimeout(()=>{_admAuth=false;doLogout()},2000)}
}

// Auto-refresh logs
setInterval(()=>{
  if(activeTab==='admin'&&_admAuth&&document.getElementById('as-logs').classList.contains('active'))
    loadLogs();
},10000);

// ── Init ──────────────────────────────────────────────────────────────────
// Poll rapide les 5 premières secondes (cache Python met 1-2s à se remplir)
let _sp=0;
(function _ip(){pollStats();if(++_sp<5)setTimeout(_ip,700);else setInterval(pollStats,2000);})();
