Set-StrictMode -Version Latest

function Get-RegistryKey {
    param([Parameter(Mandatory)] $Session)

    if ($Session.sessionId) {
        return "$($Session.tool)|$($Session.sessionId)".ToLowerInvariant()
    }
    return "$($Session.tool)|pid:$($Session.pid)|start:$($Session.processStart)".ToLowerInvariant()
}

function Add-RecentAction {
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] [string] $Text,
        [Parameter(Mandatory)] [string] $At
    )

    $actions = @($Entry.recentActions)
    if ($actions.Count -eq 0 -or [string] $actions[0].text -ne $Text) {
        $actions = @([pscustomobject]@{ at = $At; text = $Text }) + $actions
    }
    $Entry.recentActions = @($actions | Select-Object -First 4)
    $Entry.lastAction = $Text
}

function Read-SessionRegistry {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    try {
        $saved = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
        return @($saved.sessions)
    }
    catch {
        return @()
    }
}

function Write-SessionRegistry {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object[]] $Sessions
    )

    $payload = [ordered]@{
        schemaVersion = 1
        updatedAt = (Get-Date).ToString('o')
        sessions = @($Sessions | Sort-Object {
            $value = if ($_.PSObject.Properties['lastActivity'] -and $_.lastActivity) { $_.lastActivity } else { $_.lastSeen }
            [datetimeoffset] $value
        } -Descending)
    }
    $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Update-SessionRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Sessions,
        [object[]] $CatalogSessions = @(),
        [Parameter(Mandatory)] [string] $Path
    )

    $now = (Get-Date).ToString('o')
    $entries = [ordered]@{}
    foreach ($saved in @(Read-SessionRegistry -Path $Path)) {
        $key = [string] $saved.key
        if (-not $key) { $key = Get-RegistryKey -Session $saved }
        $entries[$key] = [pscustomobject][ordered]@{
            key = $key
            tool = [string] $saved.tool
            sessionId = [string] $saved.sessionId
            name = [string] $saved.name
            cwd = [string] $saved.cwd
            active = [bool] $saved.active
            confidence = [string] $saved.confidence
            matchMethod = [string] $saved.matchMethod
            firstSeen = [string] $saved.firstSeen
            lastSeen = [string] $saved.lastSeen
            lastActivity = $(if ($saved.PSObject.Properties['lastActivity']) { [string] $saved.lastActivity } else { [string] $saved.lastSeen })
            lastAction = [string] $saved.lastAction
            recentActions = @($saved.recentActions)
        }
    }

    $previouslyActive = @{}
    foreach ($pair in @($entries.GetEnumerator())) {
        $previouslyActive[$pair.Key] = [bool] $pair.Value.active
        $pair.Value.active = $false
    }

    foreach ($session in $CatalogSessions) {
        $key = Get-RegistryKey -Session $session
        $isNew = -not $entries.Contains($key)
        if ($isNew) {
            $firstSeen = if ($session.PSObject.Properties['firstSeen'] -and $session.firstSeen) {
                [string] $session.firstSeen
            }
            else { $now }
            $activity = if ($session.PSObject.Properties['lastActivity'] -and $session.lastActivity) {
                [string] $session.lastActivity
            }
            else { $firstSeen }
            $entries[$key] = [pscustomobject][ordered]@{
                key = $key
                tool = [string] $session.tool
                sessionId = [string] $session.sessionId
                name = [string] $session.name
                cwd = [string] $session.cwd
                active = $false
                confidence = [string] $session.confidence
                matchMethod = [string] $session.matchMethod
                firstSeen = $firstSeen
                lastSeen = $now
                lastActivity = $activity
                lastAction = ''
                recentActions = @()
            }
            Add-RecentAction -Entry $entries[$key] -Text 'Found in local session catalog' -At $now
        }
        else {
            $entry = $entries[$key]
            if ($session.name) { $entry.name = [string] $session.name }
            if ($session.cwd) { $entry.cwd = [string] $session.cwd }
            if ($session.PSObject.Properties['lastActivity'] -and $session.lastActivity) {
                $entry.lastActivity = [string] $session.lastActivity
            }
            $entry.confidence = [string] $session.confidence
            $entry.matchMethod = [string] $session.matchMethod
        }
    }

    foreach ($session in $Sessions) {
        $key = Get-RegistryKey -Session $session
        $isNew = -not $entries.Contains($key)
        if ($isNew) {
            $entries[$key] = [pscustomobject][ordered]@{
                key = $key
                tool = [string] $session.tool
                sessionId = [string] $session.sessionId
                name = [string] $session.name
                cwd = [string] $session.cwd
                active = $true
                confidence = [string] $session.confidence
                matchMethod = [string] $session.matchMethod
                firstSeen = $now
                lastSeen = $now
                lastActivity = $(if ($session.PSObject.Properties['lastActivity']) { [string] $session.lastActivity } else { $now })
                lastAction = ''
                recentActions = @()
            }
        }

        $entry = $entries[$key]
        $entry.tool = [string] $session.tool
        $entry.sessionId = [string] $session.sessionId
        if ($session.name) { $entry.name = [string] $session.name }
        if ($session.cwd) { $entry.cwd = [string] $session.cwd }
        $entry.active = $true
        $entry.confidence = [string] $session.confidence
        $entry.matchMethod = [string] $session.matchMethod
        $entry.lastSeen = $now
        if ($session.PSObject.Properties['lastActivity'] -and $session.lastActivity) {
            $entry.lastActivity = [string] $session.lastActivity
        }

        $evidence = if ($session.confidence) {
            "$($session.confidence) via $($session.matchMethod)"
        }
        else { 'identity pending' }
        if ($isNew) {
            Add-RecentAction -Entry $entry -Text "Discovered running ($evidence)" -At $now
        }
        elseif (-not $previouslyActive[$key]) {
            Add-RecentAction -Entry $entry -Text "Became active ($evidence)" -At $now
        }
        else {
            $entry.lastAction = "Active ($evidence)"
        }
    }

    foreach ($pair in @($entries.GetEnumerator())) {
        if ($previouslyActive[$pair.Key] -and -not $pair.Value.active) {
            Add-RecentAction -Entry $pair.Value -Text 'Inactive at most recent scan' -At $now
        }
    }

    $currentEphemeralKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($session in $Sessions | Where-Object { -not $_.sessionId }) {
        $null = $currentEphemeralKeys.Add((Get-RegistryKey -Session $session))
    }
    foreach ($key in @($entries.Keys | Where-Object { $_ -match '\|pid:' })) {
        if (-not $currentEphemeralKeys.Contains([string] $key)) {
            $entries.Remove($key)
        }
    }

    Write-SessionRegistry -Path $Path -Sessions @($entries.Values)
}

function Add-SessionRegistryAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Sessions,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Text,
        [Nullable[bool]] $Active
    )

    $now = (Get-Date).ToString('o')
    $entries = [ordered]@{}
    foreach ($saved in @(Read-SessionRegistry -Path $Path)) {
        $entries[[string] $saved.key] = $saved
    }
    foreach ($session in $Sessions) {
        $key = Get-RegistryKey -Session $session
        if (-not $entries.Contains($key)) { continue }
        $entry = $entries[$key]
        if ($null -ne $Active) { $entry.active = $Active.Value }
        $entry.lastSeen = $now
        Add-RecentAction -Entry $entry -Text $Text -At $now
    }
    Write-SessionRegistry -Path $Path -Sessions @($entries.Values)
}

function New-SessionDashboard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RegistryPath,
        [Parameter(Mandatory)] [string] $OutputPath
    )

    $registry = @{
        generatedAt = (Get-Date).ToString('o')
        sessions = @(Read-SessionRegistry -Path $RegistryPath)
    }
    $json = $registry | ConvertTo-Json -Depth 10 -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $document = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<title>Agent Session Continuity</title>
<style>
:root{color-scheme:light dark;--bg:#f5f7fb;--surface:#ffffff;--surface-2:#eef2f8;--text:#18212f;--muted:#657187;--line:#dce2ec;--accent:#5b5bd6;--accent-soft:#e9e9ff;--active:#138a62;--active-soft:#dcf8ed;--inactive:#778296;--inactive-soft:#e9edf3;--shadow:0 20px 60px rgba(30,42,65,.12)}
@media(prefers-color-scheme:dark){:root{--bg:#0d111a;--surface:#151b27;--surface-2:#1c2433;--text:#edf1f8;--muted:#a0abbd;--line:#2b3546;--accent:#9d9bff;--accent-soft:#292849;--active:#58d7a8;--active-soft:#173d34;--inactive:#9da9bb;--inactive-soft:#242d3b;--shadow:0 22px 70px rgba(0,0,0,.38)}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;line-height:1.45}.shell{max-width:1280px;margin:0 auto;padding:28px}.panel{background:var(--surface);border:1px solid var(--line);border-radius:20px;box-shadow:var(--shadow);overflow:hidden}.masthead{display:flex;justify-content:space-between;gap:24px;align-items:flex-start;padding:26px 28px 22px;border-bottom:1px solid var(--line)}.eyebrow{margin:0 0 5px;color:var(--accent);font-size:12px;font-weight:700;letter-spacing:.12em;text-transform:uppercase}.masthead h1{font-size:26px;line-height:1.15;margin:0 0 8px;font-weight:700}.subtitle,.timestamp{margin:0;color:var(--muted);font-size:13px}.pulse{display:flex;align-items:center;gap:9px;white-space:nowrap;padding-top:3px}.pulse-dot{width:9px;height:9px;border-radius:50%;background:var(--active);box-shadow:0 0 0 5px var(--active-soft)}.overview{display:flex;flex-wrap:wrap;align-items:center;gap:10px 22px;padding:15px 28px;background:var(--surface-2);border-bottom:1px solid var(--line)}.stat{display:flex;align-items:baseline;gap:7px}.stat strong{font-size:18px}.stat span{color:var(--muted);font-size:12px}.spacer{flex:1}.filters{display:flex;gap:6px}.filter{font:inherit;font-size:12px;color:var(--text);background:transparent;border:1px solid var(--line);border-radius:999px;padding:6px 11px;cursor:pointer}.filter[aria-pressed="true"]{background:var(--accent);border-color:var(--accent);color:#fff}.table-wrap{overflow-x:auto}table{width:100%;border-collapse:collapse;table-layout:fixed}th{padding:12px 16px;text-align:left;color:var(--muted);font-size:11px;letter-spacing:.08em;text-transform:uppercase;font-weight:700;border-bottom:1px solid var(--line)}td{padding:16px;border-bottom:1px solid var(--line);vertical-align:top;font-size:13px}tbody tr:last-child td{border-bottom:0}tbody tr:hover{background:var(--surface-2)}.agent-col{width:14%}.session-col{width:25%}.state-col{width:12%}.path-col{width:24%}.activity-col{width:25%}.agent{display:flex;gap:10px;align-items:center;font-weight:650}.agent-mark{display:grid;place-items:center;width:30px;height:30px;border-radius:9px;background:var(--accent-soft);color:var(--accent);font-size:12px;font-weight:800;text-transform:uppercase}.session-name{font-weight:650;margin-bottom:3px;overflow-wrap:anywhere}.session-id,.path,.action-time{color:var(--muted);font-size:11px}.session-id,.path{font-family:"Cascadia Code","SFMono-Regular",Consolas,monospace}.path{overflow-wrap:anywhere}.status{display:inline-flex;align-items:center;gap:7px;padding:5px 9px;border-radius:999px;font-size:11px;font-weight:700}.status::before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}.status.active{color:var(--active);background:var(--active-soft)}.status.inactive{color:var(--inactive);background:var(--inactive-soft)}.actions{margin:0;padding:0;list-style:none}.actions li+li{margin-top:8px}.action-text{display:block}.empty{padding:56px 28px;text-align:center;color:var(--muted)}.foot{padding:12px 28px;color:var(--muted);font-size:11px;border-top:1px solid var(--line)}
.toggle-row td{padding:0 16px 14px;border-bottom:1px solid var(--line)}
.expander{display:flex;align-items:center;gap:8px;width:100%;margin:0;padding:2px 0 8px 40px;border:0;background:transparent;color:var(--accent);font:inherit;font-size:12px;font-weight:700;text-align:left;cursor:pointer}
.expander .chevron{width:0;height:0;border-top:4px solid transparent;border-bottom:4px solid transparent;border-left:6px solid currentColor;transition:transform .15s ease}
.expander[aria-expanded="true"] .chevron{transform:rotate(90deg)}
.session-list{max-height:420px;margin:0 0 8px 40px;padding-left:12px;overflow:auto;border-left:2px solid var(--line)}
.nested{display:grid;grid-template-columns:minmax(0,1.5fr) 92px minmax(0,1fr) minmax(0,1.1fr);gap:12px;padding:12px 8px 12px 0;border-top:1px solid var(--line)}
.nested:first-child{border-top:0}
@media(max-width:780px){.shell{padding:12px}.panel{border-radius:14px}.masthead{padding:20px;flex-direction:column}.overview{padding:13px 20px}.spacer{display:none}.filters{width:100%;margin-top:4px}.filter{flex:1}.table-wrap{overflow:visible}table,tbody,tr,td{display:block;width:100%}thead{display:none}tbody tr{padding:14px 20px;border-bottom:1px solid var(--line)}tbody tr:last-child{border-bottom:0}td{display:grid;grid-template-columns:110px 1fr;gap:12px;padding:7px 0;border:0}td::before{content:attr(data-label);color:var(--muted);font-size:10px;letter-spacing:.08em;text-transform:uppercase}.agent-col,.session-col,.state-col,.path-col,.activity-col{width:auto}.agent{margin-top:-4px}.foot{padding:12px 20px}.toggle-row td{display:block;padding:0 0 12px}.toggle-row td::before{content:none}.expander,.session-list{margin-left:0;padding-left:0}.nested{grid-template-columns:1fr}}
@media(max-width:460px){td{grid-template-columns:1fr;gap:3px}.masthead h1{font-size:22px}.overview{gap:8px 16px}}
</style>
</head>
<body>
<main class="shell">
  <section class="panel" aria-labelledby="dashboard-title">
    <header class="masthead">
      <div><p class="eyebrow">Agent Session Continuity</p><h1 id="dashboard-title">Session lineup</h1><p class="subtitle">Each agent shows its latest active session. Click to open that agent's other sessions.</p></div>
      <div class="pulse"><span class="pulse-dot" aria-hidden="true"></span><p class="timestamp" id="generated"></p></div>
    </header>
    <div class="overview" aria-label="Session summary">
      <div class="stat"><strong id="total-count">0</strong><span>sessions</span></div>
      <div class="stat"><strong id="active-count">0</strong><span>active</span></div>
      <div class="stat"><strong id="agent-count">0</strong><span>agents</span></div>
      <div class="spacer"></div>
      <div class="filters" aria-label="Filter by state">
        <button class="filter" type="button" data-filter="all" aria-pressed="true">All</button>
        <button class="filter" type="button" data-filter="active" aria-pressed="false">Active</button>
        <button class="filter" type="button" data-filter="inactive" aria-pressed="false">Inactive</button>
      </div>
    </div>
    <div class="table-wrap">
      <table aria-label="AI coding agent sessions">
        <thead><tr><th class="agent-col">Agent</th><th class="session-col">Session</th><th class="state-col">State</th><th class="path-col">Home / initiation folder</th><th class="activity-col">Recent actions</th></tr></thead>
        <tbody id="session-rows"></tbody>
      </table>
      <div class="empty" id="empty" hidden>No sessions match this view.</div>
    </div>
    <footer class="foot">Local snapshot only · Conversation messages are never copied into this dashboard</footer>
  </section>
</main>
<script>
const payload = '__PAYLOAD__';
const raw = Uint8Array.from(atob(payload), c => c.charCodeAt(0));
const data = JSON.parse(new TextDecoder().decode(raw));
const sessions = (data.sessions || []).slice().sort((a,b) => new Date(b.lastActivity || b.lastSeen) - new Date(a.lastActivity || a.lastSeen));
const rows = document.getElementById('session-rows');
const empty = document.getElementById('empty');
const toolNames = {codex:'Codex',claude:'Claude Code',grok:'Grok',kimi:'Kimi Code',deepcode:'DeepCode'};
const fmtTime = value => { const date = new Date(value); return Number.isNaN(date.valueOf()) ? 'Unknown time' : new Intl.DateTimeFormat(undefined,{dateStyle:'medium',timeStyle:'short'}).format(date); };
const shortId = value => value ? (value.length > 18 ? value.slice(0,8) + '…' + value.slice(-4) : value) : 'No durable ID';
const cell = (label, className='') => { const td=document.createElement('td'); td.dataset.label=label; if(className) td.className=className; return td; };
const byRecent = (a,b) => new Date(b.lastActivity || b.lastSeen) - new Date(a.lastActivity || a.lastSeen);
const agentLabel = tool => toolNames[tool] || tool || 'Unknown';
function fillSession(s, includeAgent){
  const tr=document.createElement('tr');
  const agentCell=cell('Agent','agent-col');
  if(includeAgent){
    const agent=document.createElement('div'); agent.className='agent';
    const mark=document.createElement('span'); mark.className='agent-mark'; mark.textContent=(s.tool||'?').slice(0,2); mark.setAttribute('aria-hidden','true');
    const agentName=document.createElement('span'); agentName.textContent=agentLabel(s.tool); agent.append(mark,agentName); agentCell.append(agent);
  }
  const sessionCell=cell('Session','session-col'); const name=document.createElement('div'); name.className='session-name'; name.textContent=s.name||'Untitled session';
  const id=document.createElement('div'); id.className='session-id'; id.textContent=shortId(s.sessionId); sessionCell.append(name,id);
  const stateCell=cell('State','state-col'); const status=document.createElement('span'); status.className='status '+(s.active?'active':'inactive'); status.textContent=s.active?'Active':'Inactive'; stateCell.append(status);
  const pathCell=cell('Home / initiation folder','path-col'); const path=document.createElement('div'); path.className='path'; path.textContent=s.cwd||'Not recorded'; pathCell.append(path);
  const activityCell=cell('Recent actions','activity-col'); const list=document.createElement('ul'); list.className='actions';
  const actions=(s.recentActions||[]).slice(0,3); if(!actions.length) actions.push({text:s.lastAction||'No recorded coordinator action',at:s.lastSeen});
  for(const item of actions){ const li=document.createElement('li'); const txt=document.createElement('span'); txt.className='action-text'; txt.textContent=item.text; const when=document.createElement('span'); when.className='action-time'; when.textContent=fmtTime(item.at); li.append(txt,when); list.append(li); }
  activityCell.append(list); tr.append(agentCell,sessionCell,stateCell,pathCell,activityCell); return tr;
}
function nestedItem(s){
  const row=document.createElement('div'); row.className='nested';
  const titleWrap=document.createElement('div'); const title=document.createElement('div'); title.className='session-name'; title.textContent=s.name||'Untitled session';
  const id=document.createElement('div'); id.className='session-id'; id.textContent=shortId(s.sessionId); titleWrap.append(title,id);
  const state=document.createElement('div'); const status=document.createElement('span'); status.className='status '+(s.active?'active':'inactive'); status.textContent=s.active?'Active':'Inactive'; state.append(status);
  const path=document.createElement('div'); path.className='path'; path.textContent=s.cwd||'Not recorded';
  const activity=document.createElement('ul'); activity.className='actions';
  const actions=(s.recentActions||[]).slice(0,2); if(!actions.length) actions.push({text:s.lastAction||'No recorded coordinator action',at:s.lastSeen});
  for(const item of actions){ const li=document.createElement('li'); const txt=document.createElement('span'); txt.className='action-text'; txt.textContent=item.text; const when=document.createElement('span'); when.className='action-time'; when.textContent=fmtTime(item.at); li.append(txt,when); activity.append(li); }
  row.append(titleWrap,state,path,activity); return row;
}
function render(filter='all'){
  rows.replaceChildren();
  const visible = sessions.filter(s => filter==='all' || (filter==='active')===Boolean(s.active));
  const grouped = new Map();
  for(const session of visible){
    const key = session.tool || 'unknown';
    if(!grouped.has(key)) grouped.set(key, []);
    grouped.get(key).push(session);
  }
  const categories = [...grouped.entries()].map(([tool, list]) => {
    const sorted = list.slice().sort(byRecent);
    const active = sorted.filter(session => session.active);
    const featured = active[0] || sorted[0];
    return { tool, featured, rest: sorted.filter(session => session !== featured) };
  }).sort((a,b) => byRecent(a.featured, b.featured));
  for(const category of categories){
    const lead = fillSession(category.featured, true);
    lead.className = 'lead-row';
    rows.append(lead);
    if(!category.rest.length) continue;
    const toggle = document.createElement('tr'); toggle.className = 'toggle-row';
    const holder = document.createElement('td'); holder.colSpan = 5;
    const button = document.createElement('button'); button.type = 'button'; button.className = 'expander';
    const listId = 'sessions-' + category.tool + '-' + filter;
    button.setAttribute('aria-expanded','false'); button.setAttribute('aria-controls', listId);
    const chevron = document.createElement('span'); chevron.className = 'chevron'; chevron.setAttribute('aria-hidden','true');
    const label = document.createElement('span');
    label.textContent = category.rest.length + (category.rest.length === 1 ? ' other session' : ' other sessions');
    button.append(chevron, label);
    const panel = document.createElement('div'); panel.className = 'session-list'; panel.id = listId; panel.hidden = true;
    for(const session of category.rest) panel.append(nestedItem(session));
    button.addEventListener('click', () => {
      const open = button.getAttribute('aria-expanded') === 'true';
      button.setAttribute('aria-expanded', String(!open));
      panel.hidden = open;
    });
    holder.append(button, panel); toggle.append(holder); rows.append(toggle);
  }
  empty.hidden = categories.length > 0;
}
document.getElementById('generated').textContent='Snapshot '+fmtTime(data.generatedAt);
document.getElementById('total-count').textContent=sessions.length;
document.getElementById('active-count').textContent=sessions.filter(s=>s.active).length;
document.getElementById('agent-count').textContent=new Set(sessions.map(s=>s.tool)).size;
document.querySelectorAll('.filter').forEach(button=>button.addEventListener('click',()=>{
  document.querySelectorAll('.filter').forEach(peer=>peer.setAttribute('aria-pressed',String(peer===button)));
  render(button.dataset.filter);
}));
render();
</script>
</body>
</html>
'@
    $document = $document.Replace('__PAYLOAD__', $payload)
    Set-Content -LiteralPath $OutputPath -Value $document -Encoding utf8
    return $OutputPath
}

Export-ModuleMember -Function Update-SessionRegistry, Add-SessionRegistryAction, New-SessionDashboard, Read-SessionRegistry
