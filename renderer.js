let destinations = []; 
let sources = [];
const defExcludes = [
    { pattern: '/proc/**', enabled: true, sys: true, label: 'System Procs (/proc)' },
    { pattern: '/sys/**', enabled: true, sys: true, label: 'Devices (/sys)' },
    { pattern: '/dev/**', enabled: true, sys: true, label: 'Hardware (/dev)' },
    { pattern: '/run/**', enabled: true, sys: true, label: 'Runtime (/run)' },
    { pattern: '/tmp/**', enabled: true, sys: true, label: 'Temp Files (/tmp)' },
    { pattern: '/mnt/**', enabled: true, sys: true, label: 'Mounts (/mnt)' },
    { pattern: '/media/**', enabled: true, sys: true, label: 'Media (/media)' },
    { pattern: '/lost+found/**', enabled: true, sys: true, label: 'Lost+Found' },
    { pattern: '.cache/**', enabled: true, sys: true, label: 'App Caches' },
    { pattern: '.Trash-*/**', enabled: true, sys: true, label: 'Trash Bins' },
    { pattern: '*.log', enabled: true, sys: true, label: '*.log' },
    { pattern: '*.tmp', enabled: true, sys: true, label: '*.tmp' },
    { pattern: '*.bak', enabled: true, sys: true, label: '*.bak' },
    { pattern: 'System Volume Information/**', enabled: true, sys: true, label: 'Win Sys Vol' },
    { pattern: '$RECYCLE.BIN/**', enabled: true, sys: true, label: 'Win Recycle Bin' }
];
let excludes = JSON.parse(JSON.stringify(defExcludes));
let profiles = {}; 
let schedules = []; 
let cloudModalTarget = 'backup';
window.defaultLoaded = false;

window.bear.getHome().then(h => { 
    sources.push({ type: 'home', path: h, enabled: true }); 
    renderSources(); 
});

['backup', 'cloud', 'restore', 'schedule', 'config', 'about'].forEach(v => { 
    document.getElementById(`btn-${v}`).addEventListener('click', () => switchView(v)); 
});

function switchView(v) {
    document.querySelectorAll('.view-section').forEach(e => e.classList.remove('active')); 
    document.getElementById(`view-${v}`).classList.add('active');
    document.querySelectorAll('.nav-btn').forEach(e => e.classList.remove('active')); 
    document.getElementById(`btn-${v}`).classList.add('active');
    
    if(v==='cloud') loadRemotes(); 
    if(v==='schedule') loadSchedule();
}

// === VIEW PASSWORD LOGIC ===
document.querySelectorAll('.toggle-pw').forEach(btn => {
    btn.addEventListener('click', function() {
        const input = this.previousElementSibling;
        const icon = this.querySelector('i');
        if (input.type === 'password') {
            input.type = 'text';
            icon.classList.replace('bi-eye', 'bi-eye-slash');
        } else {
            input.type = 'password';
            icon.classList.replace('bi-eye-slash', 'bi-eye');
        }
    });
});

// === CONFIG TAB LOGIC ===
async function loadConfig() { 
    const c = await window.bear.invoke('get-config'); 
    document.getElementById('cfg-tray').checked = c.tray; 
    document.getElementById('cfg-updates').checked = c.updates; 
    document.getElementById('cfg-notify').checked = c.notify; 
    document.getElementById('cfg-webhook').value = c.webhook || ''; 
    document.getElementById('cfg-ntfy').value = c.ntfy || ''; 
    document.getElementById('cfg-log-enable').checked = c.logEnabled !== false;
    document.getElementById('cfg-log-path').value = c.logPath || '';
}
loadConfig();

document.getElementById('cfg-log-enable').addEventListener('change', (e) => { 
    document.getElementById('cfg-log-path').disabled = !e.target.checked; 
    document.getElementById('btn-browse-log').disabled = !e.target.checked; 
});
document.getElementById('btn-browse-log').addEventListener('click', async () => { 
    const p = await window.bear.invoke('dialog:save', 'history.log'); 
    if(p) document.getElementById('cfg-log-path').value = p; 
});

const saveConfigAction = async (btnId) => {
    await window.bear.invoke('save-config', { 
        tray: document.getElementById('cfg-tray').checked, 
        updates: document.getElementById('cfg-updates').checked, 
        notify: document.getElementById('cfg-notify').checked, 
        webhook: document.getElementById('cfg-webhook').value.trim(), 
        ntfy: document.getElementById('cfg-ntfy').value.trim(),
        logEnabled: document.getElementById('cfg-log-enable').checked,
        logPath: document.getElementById('cfg-log-path').value.trim()
    }); 
    const b = document.getElementById(btnId); 
    const orig = b.innerText;
    b.innerText = "[OK] SAVED!"; 
    b.classList.replace('btn-warning', 'btn-success');
    b.classList.replace('text-dark', 'text-white');
    setTimeout(() => { 
        b.innerText = orig; 
        b.classList.replace('btn-success', 'btn-warning'); 
        b.classList.replace('text-white', 'text-dark');
    }, 2000); 
};
document.getElementById('btn-save-config').addEventListener('click', () => saveConfigAction('btn-save-config'));
document.getElementById('btn-save-log-config').addEventListener('click', () => saveConfigAction('btn-save-log-config'));

// === PROFILES / JOBS LOGIC ===
async function loadProfiles() {
    profiles = await window.bear.invoke('get-profiles');
    const conf = await window.bear.invoke('get-config');
    
    // Render Job List into the Backup Tab
    const listContainer = document.getElementById('job-list-container');
    listContainer.innerHTML = '';
    
    const keys = Object.keys(profiles);
    if(keys.length === 0) {
        listContainer.innerHTML = '<div class="col-12"><div class="text-secondary small">No saved profiles yet. Add sources and destinations, then save your job!</div></div>';
    } else {
        listContainer.innerHTML = keys.map(k => `
            <div class="col-md-6">
                <div class="card p-2 border-secondary d-flex flex-row align-items-center bg-black cursor-pointer" onclick="loadJob('${k}')" title="Click to load job into active engine">
                    <input type="radio" name="defaultJob" class="form-check-input mt-0 me-3" ${conf.defaultProfile === k ? 'checked' : ''} onclick="setDefaultJob(event, '${k}')" title="Set as default on app startup">
                    <div class="flex-grow-1 text-white fw-bold text-truncate">${k}</div>
                    <button class="btn btn-sm btn-outline-danger p-1 px-2 ms-2" onclick="delJob(event, '${k}')" title="Delete Profile"><i class="bi bi-trash"></i></button>
                </div>
            </div>
        `).join('');
    }
    
    // Schedule Tab & Restore Tab Population
    const s2 = document.getElementById('cron-profile'); 
    s2.innerHTML = '<option value="">-- Select Saved Job --</option>';
    
    const s3 = document.getElementById('res-profile-selector');
    if(s3) s3.innerHTML = '<option value="">-- Select Saved Job --</option>';

    keys.forEach(k => { 
        s2.innerHTML += `<option value="${k}">${k}</option>`; 
        if(s3) s3.innerHTML += `<option value="${k}">${k}</option>`; 
    });
    
    // Auto-load default profile on app startup
    if(conf.defaultProfile && profiles[conf.defaultProfile] && !window.defaultLoaded) {
        window.defaultLoaded = true;
        loadJob(conf.defaultProfile);
    }
}
loadProfiles();

window.loadJob = (name) => {
    const p = profiles[name]; 
    if (!p) {
        document.getElementById('btn-run-backup').innerText = "START BATCH BACKUP";
        return;
    }
    
    sources = (p.sources || []).map(s => ({ ...s, enabled: s.enabled !== false })); 
    destinations = (p.destinations || []).map(d => ({ ...d, enabled: d.enabled !== false })); 
    
    let loadedEx = p.excludes || [];
    if (loadedEx.length > 0 && typeof loadedEx[0] === 'string') { 
        loadedEx = loadedEx.map(str => ({ pattern: str, enabled: true, sys: false })); 
    }
    excludes = JSON.parse(JSON.stringify(defExcludes));
    excludes.forEach(sysDef => { 
        const found = loadedEx.find(l => l.pattern === sysDef.pattern); 
        if(found) sysDef.enabled = found.enabled; 
    });
    loadedEx.filter(l => !l.sys && !excludes.find(sysDef=>sysDef.pattern === l.pattern)).forEach(cust => excludes.push(cust));

    renderSources(); 
    renderDestinations(); 
    renderExcludes();
    
    document.getElementById('mode-full').checked = (p.mode === 'full'); 
    document.getElementById('mode-inc').checked = (p.mode === 'inc'); 
    document.getElementById('bak-comp').value = p.comp || 'none'; 
    document.getElementById('bak-enc').checked = p.encrypt || false; 
    document.getElementById('bak-key').value = p.key || ''; 
    document.getElementById('bak-key-confirm').value = p.key || ''; 
    document.getElementById('bak-bw-val').value = p.bwVal || ''; 
    document.getElementById('bak-bw-unit').value = p.bwUnit || 'M'; 
    document.getElementById('job-name-input').value = name; 
    
    document.getElementById('btn-run-backup').innerText = `START: ${name}`;
    updateCompInfo(); checkPw();
    
    const loadMsg = document.getElementById('job-load-msg');
    loadMsg.style.display = 'inline-block';
    setTimeout(() => { loadMsg.style.display = 'none'; }, 2000);
};

window.setDefaultJob = async (e, name) => {
    e.stopPropagation(); // Prevents loading the job when simply setting default
    await window.bear.invoke('save-config', { defaultProfile: name });
};

window.delJob = async (e, name) => {
    e.stopPropagation();
    if(confirm(`Delete profile: ${name}?`)) {
        profiles = await window.bear.invoke('save-profile', { name: name, delete: true }); 
        
        // Remove from defaults if it was the default
        const conf = await window.bear.invoke('get-config');
        if(conf.defaultProfile === name) {
            await window.bear.invoke('save-config', { defaultProfile: '' });
        }
        
        loadProfiles();
        if(document.getElementById('job-name-input').value === name) {
            document.getElementById('job-name-input').value = '';
            document.getElementById('btn-run-backup').innerText = "START BATCH BACKUP";
        }
    }
};

document.getElementById('btn-save-job').addEventListener('click', async () => {
    const n = document.getElementById('job-name-input').value.trim(); 
    if (!n) return alert("Enter a name!");
    const d = { 
        sources: JSON.parse(JSON.stringify(sources)), 
        destinations: JSON.parse(JSON.stringify(destinations)), 
        excludes: JSON.parse(JSON.stringify(excludes)), 
        mode: document.getElementById('mode-full').checked?'full':'inc', 
        comp: document.getElementById('bak-comp').value, 
        encrypt: document.getElementById('bak-enc').checked, 
        key: document.getElementById('bak-key').value, 
        bwVal: document.getElementById('bak-bw-val').value, 
        bwUnit: document.getElementById('bak-bw-unit').value 
    };
    profiles = await window.bear.invoke('save-profile', { name: n, data: d }); 
    loadProfiles(); 
    
    const b = document.getElementById('btn-save-job'); 
    b.innerText = "[OK] SAVED!"; 
    b.classList.replace('btn-success', 'btn-primary'); 
    setTimeout(() => { 
        b.innerText = "SAVE NEW / OVERWRITE"; 
        b.classList.replace('btn-primary', 'btn-success'); 
    }, 2000);
});

const pw1 = document.getElementById('bak-key'); 
const pw2 = document.getElementById('bak-key-confirm'); 
const pwStat = document.getElementById('pw-status');

function checkPw() { 
    if (!document.getElementById('bak-enc').checked) { 
        pw1.classList.remove('is-invalid','is-valid'); 
        pw2.classList.remove('is-invalid','is-valid'); 
        pwStat.innerHTML=''; 
        return; 
    } 
    if (pw1.value==='' && pw2.value==='') { pwStat.innerHTML=''; return; } 
    if (pw1.value===pw2.value && pw1.value.length>0) { 
        pw1.classList.remove('is-invalid'); pw2.classList.remove('is-invalid'); 
        pw1.classList.add('is-valid'); pw2.classList.add('is-valid'); 
        pwStat.innerHTML='<span class="text-success">Match</span>'; 
    } else { 
        pw1.classList.remove('is-valid'); pw2.classList.remove('is-valid'); 
        if (pw2.value.length>0) { 
            pw2.classList.add('is-invalid'); 
            pwStat.innerHTML='<span class="text-danger">Mismatch</span>'; 
        } else { 
            pw2.classList.remove('is-invalid'); 
            pwStat.innerHTML=''; 
        } 
    } 
}

pw1.addEventListener('input', () => { document.getElementById('bak-enc').checked=true; checkPw(); updateCompInfo(); }); 
pw2.addEventListener('input', () => { document.getElementById('bak-enc').checked=true; checkPw(); updateCompInfo(); }); 

function updateCompInfo() { 
    const c = document.getElementById('bak-comp').value; 
    const isInc = document.getElementById('mode-inc').checked;
    const isEnc = document.getElementById('bak-enc').checked;
    let text = "";
    if (c === 'archive') {
        document.getElementById('mode-full').checked = true; document.getElementById('mode-inc').disabled = true; 
        text += '<span class="text-warning"><b>ARCHIVE MODE:</b> Packs everything into a single .tar.gz file. <b>This forces Snapshot mode.</b> Incremental tracking is disabled.</span> ';
    } else {
        document.getElementById('mode-inc').disabled = false;
        if (c === 'transfer') { text += '<span class="text-info"><b>TRANSFER COMPRESSION:</b> Compresses files <i>during network transit</i>, then unzips them at the destination. <b>Best for remote NAS.</b></span> '; } 
        else { text += '<span class="text-success"><b>NO COMPRESSION:</b> Pure 1:1 file copying. <b>Best and fastest for local USB drives.</b></span> '; }
    }
    if (isEnc) { text += '<br><span class="text-danger mt-1 d-block"><b>ENCRYPTION ACTIVE:</b> Your destination files will be scrambled names and unreadable without BackupBear or your Rclone passphrase.</span>'; }
    document.getElementById('comp-info').innerHTML = text; 
}

document.getElementById('bak-comp').addEventListener('change', updateCompInfo); 
document.getElementById('mode-inc').addEventListener('change', updateCompInfo); 
document.getElementById('mode-full').addEventListener('change', updateCompInfo); 
document.getElementById('bak-enc').addEventListener('change', updateCompInfo); 
updateCompInfo();

window.tglSrc = (i) => { sources[i].enabled = !sources[i].enabled; }; window.rmSrc = (i) => { sources.splice(i,1); renderSources(); };
window.tglDest = (i) => { destinations[i].enabled = !destinations[i].enabled; }; window.rmDest = (i) => { destinations.splice(i,1); renderDestinations(); };
window.tglEx = (i) => { excludes[i].enabled = !excludes[i].enabled; }; window.rmEx = (i) => { excludes.splice(i,1); renderExcludes(); };

function renderSources() { 
    document.getElementById('source-container').innerHTML = sources.map((s,i)=>`<div class="dest-item"><i class="bi ${s.path === '/' ? 'bi-hdd-network-fill text-danger' : s.type === 'home' ? 'bi-house-door-fill text-info' : 'bi-folder-fill'} dest-icon"></i><div class="dest-path text-white" title="${s.path}">${s.path}</div><input type="checkbox" class="dest-check" ${s.enabled!==false?'checked':''} onchange="tglSrc(${i})"><button class="btn btn-sm text-danger ms-2 p-0" onclick="rmSrc(${i})"><i class="bi bi-x-lg"></i></button></div>`).join(''); 
}
function renderDestinations() { 
    document.getElementById('dest-container').innerHTML = destinations.map((d,i)=>`<div class="dest-item"><i class="bi ${d.type==='cloud'?'bi-cloud-fill text-warning':'bi-hdd-fill text-light'} dest-icon"></i><div class="dest-path text-white" title="${d.path}">${d.path}</div><input type="checkbox" class="dest-check" ${d.enabled!==false?'checked':''} onchange="tglDest(${i})"><button class="btn btn-sm text-danger ms-2 p-0" onclick="rmDest(${i})"><i class="bi bi-x-lg"></i></button></div>`).join(''); 
}
function renderExcludes() { 
    document.getElementById('sys-excludes-container').innerHTML = excludes.filter(e=>e.sys).map((e,i)=>`<div class="dest-item py-1"><i class="bi bi-shield-lock text-secondary me-2"></i><div class="dest-path text-white">${e.label}</div><input type="checkbox" class="dest-check" ${e.enabled?'checked':''} onchange="tglEx(${excludes.indexOf(e)})"></div>`).join(''); 
    document.getElementById('custom-excludes-container').innerHTML = excludes.filter(e=>!e.sys).map((e,i)=>`<div class="dest-item py-1"><i class="bi bi-file-earmark-x text-warning me-2"></i><div class="dest-path text-white font-monospace">${e.pattern}</div><input type="checkbox" class="dest-check" ${e.enabled?'checked':''} onchange="tglEx(${excludes.indexOf(e)})"><button class="btn btn-sm text-danger ms-2 p-0" onclick="rmEx(${excludes.indexOf(e)})"><i class="bi bi-x-lg"></i></button></div>`).join(''); 
}

document.getElementById('btn-add-custom-exclude').addEventListener('click', () => { 
    const v = document.getElementById('custom-exclude-input').value.trim(); 
    if(v) { 
        excludes.push({pattern:v, enabled:true, sys:false}); 
        document.getElementById('custom-exclude-input').value=''; 
        renderExcludes(); 
    } 
}); 
renderExcludes();

document.getElementById('btn-add-source-local').addEventListener('click', async () => { const p = await window.bear.invoke('dialog:open'); if(p) { sources.push({type:'folder',path:p,enabled:true}); renderSources(); }});
document.getElementById('btn-add-home').addEventListener('click', async () => { const h = await window.bear.getHome(); if (!sources.find(s=>s.path===h)) { sources.push({type:'home',path:h,enabled:true}); renderSources(); }});
document.getElementById('btn-add-root').addEventListener('click', () => { if (!sources.find(s=>s.path==='/')) { sources.push({type:'system',path:'/',enabled:true}); renderSources(); }});

document.getElementById('btn-add-local').addEventListener('click', async () => { const p = await window.bear.invoke('dialog:open'); if(p) { destinations.push({type:'local',path:p,enabled:true}); renderDestinations(); }});

// CLOUD AUTH BUTTONS
document.getElementById('btn-prompt-cloud').addEventListener('click', async () => { 
    cloudModalTarget = 'backup'; 
    const r = await window.bear.invoke('rclone-list'); 
    const s = document.getElementById('modal-cloud-list'); 
    s.innerHTML = r.map(x=>`<option value="${x}">${x}</option>`).join(''); 
    new bootstrap.Modal(document.getElementById('cloudModal')).show(); 
});
document.getElementById('btn-confirm-cloud').addEventListener('click', () => { 
    const v = document.getElementById('modal-cloud-list').value; 
    if (!v) return; 
    if (cloudModalTarget==='backup') { 
        if (!destinations.find(d=>d.path===v)) { destinations.push({type:'cloud',path:v,enabled:true}); renderDestinations(); } 
    } else { 
        document.getElementById('res-src').value = v+':'; 
        updateResInfo(); 
    } 
    bootstrap.Modal.getInstance(document.getElementById('cloudModal')).hide(); 
});

document.getElementById('btn-g-auth').addEventListener('click', async () => { const n = document.getElementById('g-name').value; if (!n) return alert("Enter Email"); document.getElementById('auth-overlay').style.display='flex'; const r = await window.bear.invoke('rclone-auth-drive', n); document.getElementById('auth-overlay').style.display='none'; if (r==="Success") { alert("Linked!"); document.getElementById('g-name').value=''; loadRemotes(); } else alert(r); });
document.getElementById('btn-n-auth').addEventListener('click', async () => { const u = document.getElementById('n-user').value; if (!u) return alert("Enter User"); const r = await window.bear.invoke('rclone-auth-nextcloud', {name:"Nextcloud_"+u, url:document.getElementById('n-url').value, user:u, pass:document.getElementById('n-pass').value}); if(r==="Success"){alert("Linked!"); document.getElementById('n-pass').value=''; loadRemotes();}else alert(r); });
document.getElementById('btn-b2-auth').addEventListener('click', async () => { const n = document.getElementById('b2-name').value; if (!n) return alert("Enter Name"); const r = await window.bear.invoke('rclone-auth-b2', {name:n, acc:document.getElementById('b2-acc').value, key:document.getElementById('b2-key').value}); if(r==="Success"){alert("Linked!"); document.getElementById('b2-key').value=''; loadRemotes();}else alert(r); });
document.getElementById('btn-dav-auth').addEventListener('click', async () => { const n = document.getElementById('dav-name').value; if (!n) return alert("Enter Name"); const r = await window.bear.invoke('rclone-auth-webdav', {name:n, url:document.getElementById('dav-url').value, user:document.getElementById('dav-user').value, pass:document.getElementById('dav-pass').value}); if(r==="Success"){alert("Linked!"); document.getElementById('dav-pass').value=''; loadRemotes();}else alert(r); });

async function loadRemotes() {
    const r = await window.bear.invoke('rclone-dump'); const remotes = Object.keys(r);
    const tc = document.getElementById('cloud-tabs'); 
    if (remotes.length===0) tc.innerHTML='<span class="text-secondary small py-2">No remotes.</span>'; 
    else tc.innerHTML = remotes.map(x=>`<div class="cloud-tab" onclick="openRemote('${x}',this)">${x}</div>`).join('');
    
    const ac = document.getElementById('connected-remotes-container');
    if (remotes.length===0) {
        ac.innerHTML='<div class="col-12"><div class="p-4 text-center text-secondary border border-secondary rounded">No cloud accounts connected yet. Go to Add Provider to link one.</div></div>';
    } else {
        ac.innerHTML = remotes.map(x => `<div class="col-md-6"><div class="card p-3 border-secondary d-flex flex-row align-items-center bg-black"><i class="bi bi-cloud-check-fill text-success fs-3 me-3"></i><div class="flex-grow-1"><div class="fw-bold fs-6 text-white text-truncate">${x}</div><div class="small text-warning" style="font-size:0.7rem; text-transform:uppercase;">${r[x].type || 'Cloud'}</div></div><button class="btn btn-sm btn-danger p-1 px-2 ms-2 shadow-sm" onclick="delRemote('${x}')" title="Remove Connection"><i class="bi bi-trash"></i></button></div></div>`).join('');
    }
}
window.delRemote = async (n) => { 
    if(confirm(`Remove connection to ${n}?`)) { 
        await window.bear.invoke('rclone-delete', n); 
        loadRemotes(); 
    } 
};
window.openRemote = async (r, t) => { 
    document.querySelectorAll('.cloud-tab').forEach(e=>e.classList.remove('active')); 
    t.classList.add('active'); 
    const g = document.getElementById('file-view'); 
    g.innerHTML='<div class="text-warning p-3">Loading...</div>'; 
    const f = await window.bear.invoke('rclone-ls', r); 
    if(f.length===0) g.innerHTML='<div class="text-secondary p-3">Folder empty.</div>'; 
    else g.innerHTML = f.map(x=>`<div class="file-item ${x.IsDir?'is-dir':''}"><i class="bi ${x.IsDir?'bi-folder-fill':'bi-file-earmark-text'} file-icon"></i><div class="file-name" title="${x.Name}">${x.Name}</div></div>`).join(''); 
};


// === RESTORE TAB LOGIC ===
const resSrc = document.getElementById('res-src'); 
const resDest = document.getElementById('res-dest'); 
const resFmtFolder = document.getElementById('res-fmt-folder'); 
const resFmtArchive = document.getElementById('res-fmt-archive'); 
const resEnc = document.getElementById('res-enc'); 
const resKey = document.getElementById('res-key'); 
const resInfoText = document.getElementById('res-info');

function updateResInfo() {
    let text = "";
    if (resFmtArchive.checked) text += '<span class="text-warning"><b>EXTRACT ARCHIVE:</b> The engine will un-zip the selected .tar.gz file directly into the destination folder.</span> ';
    else text += '<span class="text-success"><b>FOLDER RESTORE:</b> The engine will sync files from your backup directly into your destination.</span> ';
    if (resEnc.checked) text += '<br><span class="text-danger mt-1 d-block"><b>DECRYPTION ACTIVE:</b> The engine will unscramble the backup files on-the-fly using your passphrase.</span>';
    resInfoText.innerHTML = text;
}
resFmtFolder.addEventListener('change', updateResInfo); 
resFmtArchive.addEventListener('change', updateResInfo); 
resEnc.addEventListener('change', updateResInfo); 
resKey.addEventListener('input', () => { resEnc.checked = true; updateResInfo(); });

document.getElementById('res-profile-selector').addEventListener('change', (e) => { 
    const profName = e.target.value;
    if (profName && profiles[profName]) {
        const p = profiles[profName];
        if (p.destinations && p.destinations.length > 0) {
            resSrc.value = p.destinations[0].path + (p.destinations[0].type === 'cloud' && !p.destinations[0].path.includes(':') ? ':' : '');
        }
        if (p.sources && p.sources.length > 0) {
            resDest.value = p.sources[0].path;
        }
        if (p.key) {
            resKey.value = p.key;
            resEnc.checked = true;
        } else {
            resKey.value = '';
            resEnc.checked = false;
        }
        if (p.comp === 'archive') {
            resFmtArchive.checked = true;
        } else {
            resFmtFolder.checked = true;
        }
    }
    updateResInfo(); 
});
updateResInfo();

document.getElementById('btn-browse-restore-src').addEventListener('click', async () => { const p = await window.bear.invoke('dialog:open'); if(p) { resSrc.value=p; updateResInfo(); }});
document.getElementById('btn-browse-restore-dest').addEventListener('click', async () => { const p = await window.bear.invoke('dialog:open'); if(p) resDest.value=p; });
document.getElementById('btn-cloud-restore-src').addEventListener('click', async () => { cloudModalTarget = 'restore'; const r = await window.bear.invoke('rclone-list'); const s = document.getElementById('modal-cloud-list'); s.innerHTML = r.map(x=>`<option value="${x}">${x}</option>`).join(''); new bootstrap.Modal(document.getElementById('cloudModal')).show(); });

document.getElementById('btn-run-restore').addEventListener('click', () => {
    const s = resSrc.value.trim(); const d = resDest.value.trim();
    if (!s || !d) return alert("Select source and destination!");
    document.getElementById('btn-run-restore').style.display='none'; 
    document.getElementById('btn-stop-restore').style.display='block';
    window.bear.send('start-restore-task', { source:s, dest:d, isArchive:resFmtArchive.checked, encrypt:resEnc.checked, key:resKey.value });
});
document.getElementById('btn-stop-restore').addEventListener('click', () => window.bear.send('stop-task'));


// === MULTI-CRON SCHEDULE TAB LOGIC ===
const fE = document.getElementById('cron-freq'); 
const dD = document.getElementById('div-cron-day'); 
const dE = document.getElementById('cron-day');

fE.addEventListener('change', () => { 
    if(fE.value==='daily') dD.style.display='none'; 
    else if(fE.value==='weekly'){ dD.style.display='block'; dE.innerHTML=`<option value="1">Mon</option><option value="2">Tue</option><option value="3">Wed</option><option value="4">Thu</option><option value="5">Fri</option><option value="6">Sat</option><option value="0">Sun</option>`; } 
    else { dD.style.display='block'; let h=''; for(let i=1;i<=28;i++) h+=`<option value="${i}">${i}</option>`; dE.innerHTML=h; } 
});

async function loadSchedule() { 
    schedules = await window.bear.invoke('get-schedule'); 
    const con = document.getElementById('active-crons-container');
    
    if (!schedules || schedules.length === 0) {
        con.innerHTML = '<div class="p-3 text-center text-secondary">No automated jobs scheduled.</div>';
    } else {
        con.innerHTML = schedules.map(s => {
            let desc = s.freq;
            if (s.freq === 'weekly') { const ds = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]; desc += ` on ${ds[parseInt(s.day)]}`; }
            else if (s.freq === 'monthly') desc += ` on the ${s.day}`;
            desc += ` at ${s.time}`;
            
            return `<div class="card p-3 border-secondary mb-2 bg-black d-flex flex-row align-items-center">
                        <div class="flex-grow-1">
                            <div class="fw-bold text-white fs-6">${s.profile}</div>
                            <div class="small text-secondary">${desc}</div>
                        </div>
                        <button class="btn btn-sm btn-danger px-2 shadow-sm" onclick="delSchedule('${s.id}')" title="Delete Cron Job">DELETE</button>
                    </div>`;
        }).join('');
    }
}

document.getElementById('btn-add-cron').addEventListener('click', async () => { 
    const prof = document.getElementById('cron-profile').value;
    if (!prof) return alert("Select a Saved Profile to schedule!");
    
    const conf = await window.bear.invoke('get-config');
    const newId = 'job_' + Date.now();
    const newJob = { id: newId, profile: prof, freq: fE.value, day: fE.value !== 'daily' ? dE.value : null, time: document.getElementById('cron-time').value };
    
    schedules.push(newJob);
    const res = await window.bear.invoke('save-schedule', { schedules: schedules, profiles: profiles, appConf: conf }); 
    
    if(res.success){ loadSchedule(); alert("Cron Job Activated!"); } 
    else { alert("Error saving cron."); }
});

window.delSchedule = async (id) => {
    if(confirm("Remove this automated job?")) {
        const conf = await window.bear.invoke('get-config');
        schedules = schedules.filter(s => s.id !== id);
        const res = await window.bear.invoke('save-schedule', { schedules: schedules, profiles: profiles, appConf: conf });
        if(res.success) { loadSchedule(); } 
        else { alert("Failed to clear cron."); }
    }
};

// === CORE EXECUTION RUNNER ===
function getJobPayload(dryRun=false) { 
    return { 
        sources: sources.filter(x=>x.enabled!==false), 
        destinations: destinations.filter(x=>x.enabled!==false), 
        encrypt: document.getElementById('bak-enc').checked, 
        key: document.getElementById('bak-key').value, 
        mode: document.getElementById('mode-full').checked?'full':'inc', 
        comp: document.getElementById('bak-comp').value, 
        bwVal: document.getElementById('bak-bw-val').value, 
        bwUnit: document.getElementById('bak-bw-unit').value, 
        excludes: excludes.filter(e=>e.enabled).map(e=>e.pattern), 
        dryRun 
    }; 
}

document.getElementById('btn-run-backup').addEventListener('click', () => { 
    const p = getJobPayload(); 
    
    const t = document.getElementById('job-mini-terminal');
    t.textContent = 'Initializing Batch Sequence...\nValidating Payload...\n'; 
    t.textContent += `Validated Sources: ${p.sources.length}\nValidated Destinations: ${p.destinations.length}\n`;
    
    if(p.sources.length===0 || p.destinations.length===0) {
        t.textContent += 'ERROR: Add at least one Source and Destination!\n';
        return alert("Add at least one Source and Destination!"); 
    }
    if(p.encrypt && !p.key) {
        t.textContent += 'ERROR: Encryption checked but no password entered!\n';
        return alert("Encryption checked but no password entered!"); 
    }
    
    document.getElementById('btn-run-backup').style.display='none'; 
    document.getElementById('btn-run-dry').style.display='none'; 
    document.getElementById('btn-stop-backup').style.display='block'; 
    document.getElementById('val-stage').innerText = "Connecting...";
    window.bear.send('start-backup-batch', p); 
});

document.getElementById('btn-run-dry').addEventListener('click', () => { 
    const p = getJobPayload(true); 
    
    const t = document.getElementById('job-mini-terminal');
    t.textContent = 'Initializing Simulation Sequence...\nValidating Payload...\n'; 
    t.textContent += `Validated Sources: ${p.sources.length}\nValidated Destinations: ${p.destinations.length}\n`;
    
    if(p.sources.length===0 || p.destinations.length===0) {
        t.textContent += 'ERROR: Add at least one Source and Destination!\n';
        return alert("Add at least one Source and Destination!"); 
    }
    
    document.getElementById('btn-run-backup').style.display='none'; 
    document.getElementById('btn-run-dry').style.display='none'; 
    document.getElementById('btn-stop-backup').style.display='block'; 
    document.getElementById('val-stage').innerText = "Simulating...";
    window.bear.send('start-backup-batch', p); 
});

document.getElementById('btn-stop-backup').addEventListener('click', () => window.bear.send('stop-task'));

window.bear.on('progress', (d) => { 
    if(d.stage) { document.getElementById('val-stage').innerText = d.stage; document.getElementById('val-stage').className = `metric-val ${d.stageClass}`; } 
    document.getElementById('val-spd').innerText = d.speed||"--"; 
    document.getElementById('val-eta').innerText = d.eta||"--"; 
    const elRaw = document.getElementById('val-raw'); if(elRaw && d.raw) elRaw.innerText = d.raw;
    if(d.fullRaw){ const jt=document.getElementById('job-mini-terminal'); if(jt){jt.textContent+=d.fullRaw+'\n'; jt.scrollTop=jt.scrollHeight;} } 
});

window.bear.on('done', (m) => { 
    document.getElementById('btn-run-backup').style.display='block'; 
    document.getElementById('btn-run-dry').style.display='block'; 
    document.getElementById('btn-stop-backup').style.display='none'; 
    document.getElementById('val-stage').innerText=m; 
    document.getElementById('val-stage').className="metric-val text-success"; 
});

window.bear.on('restore-progress', (d) => { 
    if(d.stage) { document.getElementById('res-val-stage').innerText = d.stage; document.getElementById('res-val-stage').className = `metric-val ${d.stageClass}`; } 
    document.getElementById('res-val-spd').innerText = d.speed||"--"; 
    document.getElementById('res-val-eta').innerText = d.eta||"--"; 
});

window.bear.on('restore-done', (m) => { 
    document.getElementById('btn-run-restore').style.display='block'; 
    document.getElementById('btn-stop-restore').style.display='none'; 
    document.getElementById('res-val-stage').innerText=m; 
    document.getElementById('res-val-stage').className="metric-val text-success"; 
});

window.bear.on('update-available', (release) => {
    document.getElementById('update-ver-text').innerText = `Version ${release.tag_name} is available on GitHub.`;
    new bootstrap.Modal(document.getElementById('updateModal')).show();
    document.getElementById('btn-update-notes').onclick = () => window.bear.send('open-link', release.html_url);
});

document.getElementById('btn-run-update').addEventListener('click', () => {
    document.getElementById('btn-run-update').innerText = "Launching Installer...";
    window.bear.send('run-updater');
});

switchView('backup');
