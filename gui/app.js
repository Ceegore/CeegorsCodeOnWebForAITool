'use strict';

(function () {
  // ---------------------------------------------------------------- constants
  var POLL_MS = 1000;
  var MAX_FAILS = 5;
  var TOTAL_STEPS = 8;

  var MSG_NO_TOKEN = 'Bitte die GUI über die Verknüpfung öffnen.';
  var MSG_LOST = 'Verbindung zum WorkspaceShare-Dienst verloren. Fenster schließen und über die Verknüpfung neu starten.';
  var MSG_UNAUTH = 'Die Sitzung ist ungültig (Token abgelehnt). Fenster schließen und über die Verknüpfung neu starten.';

  // Mirrors the exit-code table in README.md.
  var EXIT_TEXTS = {
    10: 'Umgebung oder Parameter ungültig.',
    11: 'Abhängigkeiten oder Lockfile fehlerhaft (Dependency-Lock/Hash).',
    20: 'Der Workspace ist nicht lesbar oder enthält Symlinks/Junctions.',
    21: 'Zu wenig Speicherplatz.',
    22: 'Secret-Prüfung: verbotene Dateien oder Geheimnisse im Ordner gefunden.',
    23: 'ZIP-Erstellung oder Integritätsprüfung fehlgeschlagen.',
    30: 'Der lokale Server konnte nicht gestartet werden.',
    31: 'Die lokale Sicherheitsprüfung ist fehlgeschlagen.',
    41: 'Der Cloudflare-Prozess konnte nicht gestartet werden oder wurde beendet.',
    42: 'Die Tunnel-URL konnte nicht ermittelt werden.',
    43: 'Die öffentliche Prüfung des Links ist fehlgeschlagen.',
    50: 'Laufzeitfehler: unerwarteter Prozessabbruch.'
  };

  var HEALTH_TEXTS = {
    ok: ['ok', 'In Ordnung'],
    degraded: ['degraded', 'Gestört'],
    recovered: ['recovered', 'Wiederhergestellt']
  };

  var REASON_TEXTS = {
    ManualStop: 'Die Freigabe wurde manuell beendet.',
    Expired: 'Die Freigabezeit ist abgelaufen.',
    ParentExited: 'Die Freigabe wurde beendet, weil der WorkspaceShare-Dienst beendet wurde.',
    TestSnapshotOnly: 'Testlauf: nur Snapshot erstellt.'
  };

  // ---------------------------------------------------------------- helpers
  function $(id) { return document.getElementById(id); }

  var els = {
    live: $('live'),
    foot: $('foot'),
    views: {
      fatal: $('view-fatal'),
      quit: $('view-quit'),
      loading: $('view-loading'),
      form: $('view-form'),
      progress: $('view-progress'),
      active: $('view-active'),
      stopping: $('view-stopping')
    },
    fatalText: $('fatal-text'),
    endedBox: $('ended-box'), endedText: $('ended-text'),
    errorBox: $('error-box'), errorTitle: $('error-title'), errorHint: $('error-hint'),
    errorMessage: $('error-message'), errorDetails: $('error-details'), errorLog: $('error-log'),
    form: $('form'), folder: $('folder'), btnPick: $('btn-pick'), minutes: $('minutes'),
    compression: $('compression'), includeGenerated: $('include-generated'),
    advanced: $('advanced'), formError: $('form-error'), btnStart: $('btn-start'),
    steps: $('steps'), stepCurrent: $('step-current'), btnCancel: $('btn-cancel'),
    shareUrl: $('share-url'), btnCopy: $('btn-copy'), copyError: $('copy-error'),
    factUntil: $('fact-until'), factRemaining: $('fact-remaining'), factSize: $('fact-size'),
    healthDot: $('health-dot'), healthText: $('health-text'), factSha: $('fact-sha'),
    btnStop: $('btn-stop'), btnQuit: $('btn-quit'),
    sharedFrom: $('shared-from'),
    dropzone: $('dropzone'), btnFiles: $('btn-files'), fileInput: $('file-input'),
    upload: $('upload'), uploadTitle: $('upload-title'), uploadProgress: $('upload-progress'),
    uploadFile: $('upload-file'), uploadBytes: $('upload-bytes'), btnUploadCancel: $('btn-upload-cancel'),
    dropStatus: $('drop-status'), dropError: $('drop-error'),
    dropInfo: $('drop-info'), dropSummary: $('drop-summary'), btnDropRemove: $('btn-drop-remove')
  };

  function setText(el, text) {
    var t = text == null ? '' : String(text);
    if (el.textContent !== t) { el.textContent = t; }
  }

  function setHidden(el, hidden) {
    if (el.hidden !== hidden) { el.hidden = hidden; }
  }

  function announce(text) {
    els.live.textContent = '';
    window.setTimeout(function () { els.live.textContent = text; }, 50);
  }

  function formatSize(bytes) {
    if (typeof bytes !== 'number' || !isFinite(bytes) || bytes < 0) { return '–'; }
    var units = ['Bytes', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes;
    var i = 0;
    while (value >= 1024 && i < units.length - 1) { value /= 1024; i++; }
    if (i === 0) { return value.toLocaleString('de-DE') + ' Bytes'; }
    return value.toLocaleString('de-DE', { minimumFractionDigits: 1, maximumFractionDigits: 1 }) + ' ' + units[i];
  }

  function formatRemaining(min) {
    if (typeof min !== 'number' || !isFinite(min)) { return '–'; }
    min = Math.max(0, Math.round(min));
    var h = Math.floor(min / 60);
    var m = min % 60;
    if (h === 0) { return m + ' Min.'; }
    return h + ' Std. ' + m + ' Min.';
  }

  function formatUntil(iso) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) { return '–'; }
    var time = d.toLocaleTimeString('de-DE', { hour: '2-digit', minute: '2-digit' });
    var now = new Date();
    var sameDay = d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate();
    if (sameDay) { return time + ' Uhr'; }
    return d.toLocaleDateString('de-DE', { day: '2-digit', month: '2-digit' }) + ', ' + time + ' Uhr';
  }

  // ---------------------------------------------------------------- mock API (file: + ?mock=1 only)
  function createMockApi() {
    var STEP_TEXTS = [
      'Umgebung wird geprüft ...',
      'Abhängigkeiten werden verifiziert ...',
      'Workspace wird gelesen ...',
      'Archiv wird erstellt ...',
      'Finaler Archivscan wird vorbereitet ...',
      'Lokaler Server wird gestartet ...',
      'Tunnel wird aufgebaut ...',
      'Öffentlicher Link wird geprüft ...'
    ];
    var s = {
      phase: 'idle', step: 0, steps: [], url: null, expiresUtc: null, sizeBytes: null, sha256: null,
      health: null, exitCode: null, reason: null, message: null, log: [], request: null,
      drop: null, dropPaths: {}, dropInUse: false
    };
    var MOCK_LIMITS = { maxDropBytes: 4294967296, maxDropFiles: 10000 };
    var timer = null;
    var failAt = 0;

    function clear() { if (timer) { window.clearInterval(timer); window.clearTimeout(timer); timer = null; } }

    function randomHex(n) {
      var out = '';
      while (out.length < n) { out += Math.floor(Math.random() * 16).toString(16); }
      return out;
    }

    function pad2(n) { return (n < 10 ? '0' : '') + n; }

    function newDropPath(id) {
      var d = new Date();
      var stamp = d.getFullYear() + pad2(d.getMonth() + 1) + pad2(d.getDate()) + '-' +
        pad2(d.getHours()) + pad2(d.getMinutes()) + pad2(d.getSeconds());
      return 'C:\\Users\\Beispiel\\AppData\\Local\\WorkspaceShare\\drops\\' + id + '\\Dateien-' + stamp;
    }

    // The backend deletes the drop folder once its share has ended.
    function releaseDropAfterShare() {
      if (s.dropInUse) { s.drop = null; s.dropPaths = {}; s.dropInUse = false; }
    }

    function parseQuery(q) {
      var out = {};
      (q || '').split('&').forEach(function (kv) {
        if (!kv) { return; }
        var i = kv.indexOf('=');
        var k = i < 0 ? kv : kv.slice(0, i);
        var v = i < 0 ? '' : kv.slice(i + 1);
        try { out[decodeURIComponent(k)] = decodeURIComponent(v); } catch (e) { out[k] = v; }
      });
      return out;
    }

    function snapshot() {
      var rem = null;
      if (s.expiresUtc) { rem = Math.max(0, Math.ceil((Date.parse(s.expiresUtc) - Date.now()) / 60000)); }
      return {
        v: 1, phase: s.phase, platform: 'windows',
        capabilities: { folderPicker: true, clipboard: true, openBrowser: true },
        step: s.step, total: TOTAL_STEPS, stepText: s.step ? STEP_TEXTS[s.step - 1] : null,
        steps: s.steps.slice(), url: s.url, expiresUtc: s.expiresUtc, sizeBytes: s.sizeBytes, sha256: s.sha256,
        remainingMinutes: rem, health: s.health, exitCode: s.exitCode, reason: s.reason, message: s.message,
        log: s.log.slice(), request: s.request,
        drop: s.drop ? {
          id: s.drop.id, path: s.drop.path, files: s.drop.files,
          totalBytes: s.drop.totalBytes, finished: s.drop.finished
        } : null,
        limits: MOCK_LIMITS
      };
    }

    function beginEnd(reason, message) {
      clear();
      s.phase = 'stopping';
      timer = window.setTimeout(function () {
        s.phase = 'ended'; s.exitCode = 0; s.reason = reason; s.message = message;
        s.url = null; s.expiresUtc = null; timer = null;
        releaseDropAfterShare();
      }, 1500);
    }

    function startRun(req) {
      clear();
      s.request = req;
      s.dropInUse = !!(s.drop && s.drop.finished && s.drop.path === req.path);
      s.phase = 'starting'; s.step = 0; s.steps = []; s.url = null; s.health = null;
      s.exitCode = null; s.reason = null; s.message = null;
      s.log = ['[mock] Start: ' + req.path];
      failAt = /fehler/i.test(req.path) ? 4 : 0;
      timer = window.setInterval(function () {
        s.step += 1;
        s.steps.push({ n: s.step, text: STEP_TEXTS[s.step - 1] });
        s.log.push('[mock] Schritt ' + s.step + '/' + TOTAL_STEPS);
        if (failAt && s.step === failAt) {
          clear();
          s.phase = 'error'; s.exitCode = 22; s.reason = 'SecretScan';
          s.message = 'Verbotene Datei gefunden: .env (Mock)';
          s.log.push('[mock] FEHLER: Verbotene Datei gefunden');
          releaseDropAfterShare();
          return;
        }
        if (s.step >= TOTAL_STEPS) {
          clear();
          s.phase = 'active';
          s.url = 'https://mock-demo-share-abc123.trycloudflare.com/workspace-8f3c2a91.zip';
          s.expiresUtc = new Date(Date.now() + req.minutes * 60000).toISOString();
          s.sizeBytes = 48234496;
          s.sha256 = '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';
          s.health = 'ok';
          timer = window.setTimeout(function () { s.health = 'degraded'; timer = window.setTimeout(function () { s.health = 'recovered'; timer = null; }, 6000); }, 12000);
        }
      }, 700);
    }

    function dropPhaseOk() { return s.phase === 'idle' || s.phase === 'ended' || s.phase === 'error'; }

    // Mock of the /api/drop/* endpoints (body of /api/drop/file is the File).
    function mockDrop(p, query, body) {
      if (!dropPhaseOk()) { return { status: 409, data: { error: 'Im aktuellen Zustand nicht möglich.' } }; }
      if (p === '/api/drop/begin') {
        var id = randomHex(32);
        s.drop = { id: id, path: newDropPath(id), files: 0, totalBytes: 0, finished: false };
        s.dropPaths = {};
        s.dropInUse = false;
        return { status: 200, data: { dropId: id } };
      }
      var q = parseQuery(query);
      var b = body || {};
      if (p === '/api/drop/file') {
        if (!s.drop || s.drop.finished || q.drop !== s.drop.id) { return { status: 400, data: { error: 'Unbekannte Ablage.' } }; }
        var rel = q.path || '';
        if (/fehler/i.test(rel)) { return { status: 400, data: { error: 'Ungültiger Dateiname: ' + rel + ' (Mock)' } }; }
        if (/voll/i.test(rel)) { return { status: 507, data: {} }; }
        var key = rel.toLowerCase();
        if (s.dropPaths[key]) { return { status: 409, data: { error: 'Datei doppelt: ' + rel } }; }
        s.dropPaths[key] = true;
        var size = typeof b.size === 'number' ? b.size : 0;
        s.drop.files += 1;
        s.drop.totalBytes += size;
        return { status: 200, data: { ok: true, bytes: size } };
      }
      if (p === '/api/drop/finish' || p === '/api/drop/discard') {
        if (!s.drop || b.dropId !== s.drop.id) {
          return { status: p === '/api/drop/discard' ? 200 : 400, data: p === '/api/drop/discard' ? { ok: true } : { error: 'Unbekannte Ablage.' } };
        }
        if (p === '/api/drop/discard') { s.drop = null; s.dropPaths = {}; return { status: 200, data: { ok: true } }; }
        if (s.drop.files < 1) { return { status: 400, data: { error: 'Es wurde keine Datei empfangen.' } }; }
        s.drop.finished = true;
        return { status: 200, data: { path: s.drop.path, files: s.drop.files, totalBytes: s.drop.totalBytes } };
      }
      return { status: 404, data: { error: 'Unbekannt' } };
    }

    return function mockApi(method, fullPath, body) {
      var qi = fullPath.indexOf('?');
      var path = qi < 0 ? fullPath : fullPath.slice(0, qi);
      var query = qi < 0 ? '' : fullPath.slice(qi + 1);
      return new Promise(function (resolve) {
        // ~300 ms per uploaded file
        window.setTimeout(function () {
          var r = { status: 200, data: {} };
          if (path.indexOf('/api/drop/') === 0) {
            r = mockDrop(path, query, body);
          } else if (path === '/api/state') {
            r.data = snapshot();
          } else if (path === '/api/pick-folder') {
            r.data = { path: 'C:\\Projekte\\Beispiel-Workspace' };
          } else if (path === '/api/start') {
            if (s.phase === 'starting' || s.phase === 'active' || s.phase === 'stopping') {
              r = { status: 409, data: { error: 'Es läuft bereits eine Freigabe.' } };
            } else if (!body || !body.path) {
              r = { status: 400, data: { error: 'Der Ordner existiert nicht.' } };
            } else {
              startRun({ path: body.path, minutes: body.minutes, compression: body.compression, includeGenerated: !!body.includeGenerated });
              r.data = { ok: true };
            }
          } else if (path === '/api/stop') {
            if (s.phase === 'starting' || s.phase === 'active') { beginEnd('UserStop', 'Freigabe wurde beendet.'); }
            r.data = { ok: true };
          } else if (path === '/api/copy') {
            r = s.url ? { status: 200, data: { ok: true } } : { status: 409, data: { error: 'Kein Link vorhanden.' } };
          } else if (path === '/api/quit') {
            clear();
            s.drop = null;
            r.data = { ok: true };
          } else {
            r = { status: 404, data: { error: 'Unbekannt' } };
          }
          resolve(r);
        }, path === '/api/drop/file' ? 300 : 60);
      });
    };
  }

  // ---------------------------------------------------------------- real API
  var token = '';
  var mockMode = location.protocol === 'file:' && /(^|[?&])mock=1(&|$)/.test(location.search);
  var mockApi = mockMode ? createMockApi() : null;

  // Resolves {status, data}; rejects on network failure.
  function api(method, path, body) {
    if (mockApi) { return mockApi(method, path, body); }
    var opts = {
      method: method,
      headers: { 'X-WS-Token': token, 'Content-Type': 'application/json' },
      cache: 'no-store'
    };
    if (method !== 'GET') { opts.body = JSON.stringify(body || {}); }
    return fetch(path, opts).then(readResponse);
  }

  function readResponse(resp) {
    return resp.text().then(function (txt) {
      var data = null;
      if (txt) { try { data = JSON.parse(txt); } catch (e) { data = null; } }
      return { status: resp.status, data: data || {} };
    });
  }

  // ---------------------------------------------------------------- view switching
  var currentView = '';

  function showView(name) {
    if (currentView === name) { return; }
    currentView = name;
    Object.keys(els.views).forEach(function (k) { setHidden(els.views[k], k !== name); });
  }

  function showFatal(text, keepFooter) {
    setText(els.fatalText, text);
    showView('fatal');
    setHidden(els.foot, !keepFooter);
    announce(text);
  }

  // ---------------------------------------------------------------- polling
  var pollTimer = null;
  var polling = false;
  var stopped = false;
  var fails = 0;
  var lastState = null;
  var lastAnnounce = '';

  function stopPolling() {
    stopped = true;
    if (pollTimer) { window.clearTimeout(pollTimer); pollTimer = null; }
  }

  function schedule(ms) {
    if (stopped) { return; }
    if (pollTimer) { window.clearTimeout(pollTimer); }
    pollTimer = window.setTimeout(poll, ms);
  }

  function poll() {
    pollTimer = null;
    if (stopped || polling) { return; }
    polling = true;
    var epoch = dropEpoch; // drop changes made while this request is in flight make its drop data stale
    api('GET', '/api/state').then(function (r) {
      if (stopped) { return; }
      if (r.status === 401 || r.status === 403) {
        stopPolling();
        showFatal(MSG_UNAUTH, false);
        return;
      }
      if (r.status !== 200 || !r.data || typeof r.data.phase !== 'string') {
        throw new Error('bad state');
      }
      fails = 0;
      lastState = r.data;
      render(r.data, epoch !== dropEpoch);
    }).catch(function () {
      if (stopped) { return; }
      fails++;
      if (fails >= MAX_FAILS) {
        stopPolling();
        showFatal(MSG_LOST, false);
      }
    }).then(function () {
      polling = false;
      schedule(POLL_MS);
    });
  }

  function refreshSoon() {
    if (stopped) { return; }
    if (polling) { return; }
    schedule(50);
  }

  // Run an action; network failure counts as lost connection.
  function action(path, body) {
    return api('POST', path, body).catch(function (e) {
      if (!stopped) {
        stopPolling();
        showFatal(MSG_LOST, false);
      }
      throw e;
    });
  }

  // ---------------------------------------------------------------- rendering
  var formDirty = false;
  var formPrefilled = false;
  var stepsSig = '';
  var DROP_PATH_RE = /[\\\/]drops[\\\/][0-9a-f]{32}(?:[\\\/]|$)/i;

  function prefillForm(req) {
    if (formDirty || formPrefilled || !req) { return; }
    formPrefilled = true;
    // A path inside the drop area belongs to a drop that is gone by now.
    if (typeof req.path === 'string' && !DROP_PATH_RE.test(req.path)) { els.folder.value = req.path; }
    if (req.minutes != null && els.minutes.querySelector('option[value="' + String(req.minutes).replace(/[^0-9]/g, '') + '"]')) {
      els.minutes.value = String(req.minutes);
    }
    if (req.compression === 'Fast' || req.compression === 'Store') { els.compression.value = req.compression; }
    els.includeGenerated.checked = !!req.includeGenerated;
    if (req.compression === 'Store' || req.includeGenerated) { els.advanced.open = true; }
  }

  function renderForm(st) {
    setHidden(els.btnPick, !(st.capabilities && st.capabilities.folderPicker));
    prefillForm(st.request);

    var ended = st.phase === 'ended';
    var failed = st.phase === 'error';

    setHidden(els.endedBox, !ended);
    if (ended) {
      setText(els.endedText, REASON_TEXTS[st.reason] || st.message || st.reason || '');
    }

    setHidden(els.errorBox, !failed);
    if (failed) {
      var code = st.exitCode;
      setText(els.errorTitle, 'Freigabe fehlgeschlagen' + (code != null ? ' (Exit-Code ' + code + ')' : ''));
      setText(els.errorHint, EXIT_TEXTS[code] || '');
      setText(els.errorMessage, st.message || '');
      var log = Array.isArray(st.log) ? st.log : [];
      setHidden(els.errorDetails, log.length === 0);
      setText(els.errorLog, log.join('\n'));
    }
    return failed ? 'Freigabe fehlgeschlagen. ' + (EXIT_TEXTS[st.exitCode] || '') : (ended ? 'Freigabe beendet.' : 'Bereit.');
  }

  function renderProgress(st) {
    var total = typeof st.total === 'number' && st.total > 0 ? st.total : TOTAL_STEPS;
    var cur = typeof st.step === 'number' ? st.step : 0;
    var texts = {};
    (Array.isArray(st.steps) ? st.steps : []).forEach(function (s) { if (s && typeof s.n === 'number') { texts[s.n] = s.text; } });

    var sig = total + '|' + cur + '|' + JSON.stringify(texts);
    if (sig !== stepsSig) {
      stepsSig = sig;
      while (els.steps.firstChild) { els.steps.removeChild(els.steps.firstChild); }
      for (var n = 1; n <= total; n++) {
        var li = document.createElement('li');
        var mark = document.createElement('span');
        mark.className = 'mark';
        mark.setAttribute('aria-hidden', 'true');
        var label = document.createElement('span');
        label.className = 'label';
        label.textContent = texts[n] || ('Schritt ' + n);
        var state = n < cur ? 'done' : (n === cur ? 'current' : 'pending');
        li.className = state;
        if (state === 'done') {
          mark.textContent = '✓';
          var sr = document.createElement('span');
          sr.className = 'sr-only';
          sr.textContent = ' (erledigt)';
          label.appendChild(sr);
        } else if (state === 'current') {
          li.setAttribute('aria-current', 'step');
        }
        li.appendChild(mark);
        li.appendChild(label);
        els.steps.appendChild(li);
      }
    }
    var current = st.stepText || (cur && texts[cur]) || '';
    setText(els.stepCurrent, current ? 'Schritt ' + cur + ' von ' + total + ': ' + current : 'Wird gestartet …');
    return 'Freigabe wird vorbereitet. ' + current;
  }

  function renderActive(st) {
    // Show a short text instead of the long temp path when a dropped set of files is shared.
    var reqPath = st.request && typeof st.request.path === 'string' ? st.request.path : '';
    var fromDrop = !!reqPath && ((st.drop && st.drop.path === reqPath) || DROP_PATH_RE.test(reqPath));
    if (fromDrop) {
      var n = st.drop && st.drop.path === reqPath && typeof st.drop.files === 'number' ? st.drop.files
        : (dropInfo && dropInfo.path === reqPath ? dropInfo.files : null);
      setText(els.sharedFrom, 'Freigegeben: ' + (n == null ? 'abgelegte Dateien'
        : n.toLocaleString('de-DE') + (n === 1 ? ' abgelegte Datei' : ' abgelegte Dateien')));
    }
    setHidden(els.sharedFrom, !fromDrop);

    if (els.shareUrl.value !== (st.url || '')) { els.shareUrl.value = st.url || ''; }
    setText(els.factUntil, st.expiresUtc ? formatUntil(st.expiresUtc) : '–');

    var rem = st.remainingMinutes;
    if (typeof rem !== 'number' && st.expiresUtc) {
      rem = Math.max(0, Math.ceil((Date.parse(st.expiresUtc) - Date.now()) / 60000));
    }
    setText(els.factRemaining, formatRemaining(rem));
    setText(els.factSize, formatSize(st.sizeBytes));
    setText(els.factSha, st.sha256 || '–');

    // No health event yet means every check so far has passed.
    var h = HEALTH_TEXTS[st.health || 'ok'];
    els.healthDot.className = 'dot dot-' + (h ? h[0] : 'none');
    setText(els.healthText, h ? h[1] : 'Keine Meldung');
    return 'Freigabe aktiv.';
  }

  function render(st, dropStale) {
    var label;
    switch (st.phase) {
      case 'starting':
        showView('progress');
        label = renderProgress(st);
        els.btnCancel.disabled = false;
        break;
      case 'active':
        showView('active');
        label = renderActive(st);
        break;
      case 'stopping':
        showView('stopping');
        label = 'Freigabe wird beendet …';
        break;
      default: // idle, ended, error
        label = renderForm(st);
        showView('form');
        els.btnStart.disabled = uploading;
        break;
    }
    // While uploading, the form is left alone; the drop state is re-rendered after the upload.
    if (!uploading && !dropStale) { applyDrop(dropFromState(st)); }
    if (st.phase !== 'idle' && st.phase !== 'starting') { /* keep prefilled form for next run */ }
    if (st.phase === 'starting' || st.phase === 'active' || st.phase === 'stopping') {
      formPrefilled = true; // do not overwrite the user's form once a run exists
    }
    setHidden(els.foot, false);

    var key = st.phase + '|' + st.exitCode;
    if (key !== lastAnnounce) {
      lastAnnounce = key;
      announce(label);
    }
  }

  // ---------------------------------------------------------------- user actions
  function showFormError(text) {
    setText(els.formError, text);
    setHidden(els.formError, !text);
  }

  function errorFromResponse(r, fallback) {
    if (r && r.data && typeof r.data.error === 'string' && r.data.error) { return r.data.error; }
    if (r && r.status === 409) { return 'Das ist im aktuellen Zustand nicht möglich.'; }
    return fallback;
  }

  function onFormInput() { formDirty = true; showFormError(''); }
  ['input', 'change'].forEach(function (ev) { els.form.addEventListener(ev, onFormInput); });

  els.form.addEventListener('submit', function (e) {
    e.preventDefault();
    if (uploading) { return; }
    var path = els.folder.value.trim();
    if (!path) {
      showFormError('Bitte einen Ordner angeben.');
      els.folder.focus();
      return;
    }
    showFormError('');
    els.btnStart.disabled = true;
    action('/api/start', {
      path: path,
      minutes: parseInt(els.minutes.value, 10),
      compression: els.compression.value,
      includeGenerated: els.includeGenerated.checked
    }).then(function (r) {
      if (r.status === 200 && r.data && r.data.ok) {
        formPrefilled = true;
        refreshSoon();
      } else {
        els.btnStart.disabled = false;
        showFormError(errorFromResponse(r, 'Die Freigabe konnte nicht gestartet werden.'));
      }
    }).catch(function () { /* fatal already shown */ });
  });

  els.btnPick.addEventListener('click', function () {
    els.btnPick.disabled = true;
    showFormError('');
    action('/api/pick-folder', {}).then(function (r) {
      els.btnPick.disabled = uploading;
      if (r.status === 200 && r.data && typeof r.data.path === 'string' && r.data.path) {
        var picked = r.data.path;
        // A picked folder replaces an active drop (discarded first).
        return releaseDrop().then(function (ok) {
          if (!ok) { return; }
          els.folder.value = picked;
          formDirty = true;
        });
      } else if (r.status === 200) {
        /* cancelled: nothing */
      } else if (r.status === 501) {
        showFormError('Die Ordnerauswahl wird auf diesem System nicht unterstützt. Bitte den Pfad eintragen.');
      } else {
        showFormError(errorFromResponse(r, 'Die Ordnerauswahl ist fehlgeschlagen.'));
      }
    }).catch(function () { els.btnPick.disabled = uploading; });
  });

  els.btnCancel.addEventListener('click', function () {
    els.btnCancel.disabled = true;
    action('/api/stop', {}).then(function () { refreshSoon(); }).catch(function () {});
  });

  els.btnStop.addEventListener('click', function () {
    if (!window.confirm('Freigabe wirklich beenden? Der Link funktioniert danach nicht mehr.')) { return; }
    els.btnStop.disabled = true;
    action('/api/stop', {}).then(function () {
      els.btnStop.disabled = false;
      refreshSoon();
    }).catch(function () {});
  });

  els.shareUrl.addEventListener('focus', function () { els.shareUrl.select(); });
  els.shareUrl.addEventListener('click', function () { els.shareUrl.select(); });

  var copyTimer = null;
  function showCopied() {
    els.btnCopy.textContent = 'Kopiert ✓';
    announce('Link kopiert.');
    if (copyTimer) { window.clearTimeout(copyTimer); }
    copyTimer = window.setTimeout(function () { els.btnCopy.textContent = 'Link kopieren'; copyTimer = null; }, 2000);
  }

  function showCopyError(text) {
    setText(els.copyError, text);
    setHidden(els.copyError, !text);
  }

  function browserCopy() {
    var url = els.shareUrl.value;
    function legacy() {
      try {
        els.shareUrl.focus();
        els.shareUrl.select();
        return document.execCommand('copy');
      } catch (e) { return false; }
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(url).then(function () { return true; }, function () { return legacy(); });
    }
    return Promise.resolve(legacy());
  }

  els.btnCopy.addEventListener('click', function () {
    showCopyError('');
    els.btnCopy.disabled = true;
    action('/api/copy', {}).then(function (r) {
      if (r.status === 200) { return true; }
      if (r.status === 409 || r.status === 501) { return browserCopy(); }
      return false;
    }).then(function (ok) {
      els.btnCopy.disabled = false;
      if (ok) { showCopied(); } else { showCopyError('Kopieren nicht möglich. Bitte den Link markieren und mit Strg+C kopieren.'); }
    }).catch(function () { els.btnCopy.disabled = false; });
  });

  els.btnQuit.addEventListener('click', function () {
    var running = lastState && (lastState.phase === 'starting' || lastState.phase === 'active' || lastState.phase === 'stopping');
    var msg = running
      ? 'WorkspaceShare beenden? Die laufende Freigabe wird dabei beendet.'
      : 'WorkspaceShare beenden?';
    if (!window.confirm(msg)) { return; }
    els.btnQuit.disabled = true;
    // The backend may exit right after answering; any outcome counts as quit.
    var done = function () {
      stopPolling();
      showView('quit');
      setHidden(els.foot, true);
      announce('WorkspaceShare wurde beendet. Dieses Fenster kann geschlossen werden.');
    };
    api('POST', '/api/quit', {}).then(function (r) {
      if (r.status === 200) { done(); } else { els.btnQuit.disabled = false; }
    }).catch(done);
  });

  // ---------------------------------------------------------------- drag & drop (contract section 7)
  var uploading = false;        // upload sequence (begin / files / finish) is running
  var collecting = false;       // dropped entries are being read
  var cancelRequested = false;
  var removing = false;         // discard of the active drop is running
  var dropInfo = null;          // finished drop: { id, path, files, totalBytes } or null
  var dropEpoch = 0;            // bumped on every local drop change; makes in-flight polls stale

  function num(v) { return typeof v === 'number' && isFinite(v) && v >= 0 ? v : 0; }
  function posNum(v) { return typeof v === 'number' && isFinite(v) && v > 0 ? v : 0; }

  function dropSummaryText(info) {
    return info.files.toLocaleString('de-DE') + (info.files === 1 ? ' Datei' : ' Dateien') + ', ' + formatSize(info.totalBytes);
  }

  function dropFromState(st) {
    var d = st && st.drop;
    if (!d || typeof d.path !== 'string' || !d.path || d.finished !== true) { return null; }
    return { id: typeof d.id === 'string' ? d.id : '', path: d.path, files: num(d.files), totalBytes: num(d.totalBytes) };
  }

  // Shows (or clears) the finished drop in the folder field.
  function applyDrop(info) {
    var prev = dropInfo;
    dropInfo = info;
    if (info) {
      if (els.folder.value !== info.path) { els.folder.value = info.path; }
      els.folder.readOnly = true;
      els.folder.classList.add('locked');
      setText(els.dropSummary, dropSummaryText(info));
      setHidden(els.dropInfo, false);
    } else {
      if (prev && els.folder.value === prev.path) { els.folder.value = ''; }
      els.folder.readOnly = false;
      els.folder.classList.remove('locked');
      setHidden(els.dropInfo, true);
    }
  }

  function updateBusy() {
    var busy = uploading || collecting;
    els.btnFiles.disabled = busy;
    els.btnPick.disabled = busy;
    els.folder.disabled = uploading;
    els.btnDropRemove.disabled = uploading || removing;
    els.dropzone.classList.toggle('dz-disabled', busy);
    if (busy) { els.dropzone.classList.remove('dz-over'); }
  }

  function setUploading(on) {
    uploading = on;
    setHidden(els.dropzone, on);
    setHidden(els.upload, !on);
    els.btnStart.disabled = on;
    updateBusy();
  }

  function showDropError(text) {
    setText(els.dropError, text);
    setHidden(els.dropError, !text);
  }

  function showDropStatus(text) { setText(els.dropStatus, text); }

  function canAccept() { return !uploading && !collecting && currentView === 'form'; }

  function fail(msg) { return { userMessage: msg }; }

  // ---- collecting entries
  function readAllEntries(reader) {
    return new Promise(function (resolve, reject) {
      var all = [];
      (function again() {
        // readEntries returns batches; an empty batch ends the directory.
        reader.readEntries(function (batch) {
          if (!batch || !batch.length) { resolve(all); return; }
          for (var i = 0; i < batch.length; i++) { all.push(batch[i]); }
          again();
        }, reject);
      })();
    });
  }

  function limitFiles() {
    return posNum(lastState && lastState.limits && lastState.limits.maxDropFiles);
  }

  function tooManyFiles(max) {
    return fail('Zu viele Dateien (erlaubt sind höchstens ' + max.toLocaleString('de-DE') + ').');
  }

  function walkEntry(entry, prefix, out, maxFiles) {
    if (entry.isFile) {
      return new Promise(function (resolve, reject) {
        entry.file(function (file) {
          out.push({ file: file, path: prefix + entry.name });
          if (maxFiles && out.length > maxFiles) { reject(tooManyFiles(maxFiles)); return; }
          resolve();
        }, reject);
      });
    }
    if (entry.isDirectory) {
      return readAllEntries(entry.createReader()).then(function (children) {
        var base = prefix + entry.name + '/';
        return children.reduce(function (chain, child) {
          return chain.then(function () { return walkEntry(child, base, out, maxFiles); });
        }, Promise.resolve());
      });
    }
    return Promise.resolve();
  }

  // Must run synchronously inside the drop event: the DataTransfer is invalid afterwards.
  function sourcesFromDataTransfer(dt) {
    var sources = [];
    var items = dt.items;
    var i;
    if (items && items.length) {
      for (i = 0; i < items.length; i++) {
        var it = items[i];
        if (it.kind !== 'file') { continue; }
        var entry = typeof it.webkitGetAsEntry === 'function' ? it.webkitGetAsEntry() : null;
        if (entry) {
          sources.push({ entry: entry });
        } else {
          var f = typeof it.getAsFile === 'function' ? it.getAsFile() : null;
          if (f) { sources.push({ file: f }); }
        }
      }
    }
    if (!sources.length && dt.files && dt.files.length) {
      for (i = 0; i < dt.files.length; i++) { sources.push({ file: dt.files[i] }); }
    }
    return sources;
  }

  function readErrorText(e) {
    if (e && typeof e.userMessage === 'string') { return e.userMessage; }
    return 'Die abgelegten Dateien konnten nicht gelesen werden.';
  }

  function handleDrop(dt) {
    var sources = sourcesFromDataTransfer(dt);
    collecting = true;
    updateBusy();
    showDropError('');
    showDropStatus('Dateien werden gelesen …');
    var out = [];
    var maxFiles = limitFiles();
    sources.reduce(function (chain, src) {
      return chain.then(function () {
        if (src.file) {
          out.push({ file: src.file, path: src.file.name });
          if (maxFiles && out.length > maxFiles) { throw tooManyFiles(maxFiles); }
          return null;
        }
        return walkEntry(src.entry, '', out, maxFiles);
      });
    }, Promise.resolve()).then(function () {
      collecting = false;
      updateBusy();
      showDropStatus('');
      handleSelection(out);
    }, function (e) {
      collecting = false;
      updateBusy();
      showDropStatus('');
      var msg = readErrorText(e);
      showDropError(msg);
      announce(msg);
    });
  }

  // ---- validation
  function validateItems(items) {
    if (!items.length) { return 'Es wurden keine Dateien gefunden. Leere Ordner können nicht freigegeben werden.'; }
    var lim = (lastState && lastState.limits) || {};
    var maxBytes = posNum(lim.maxDropBytes);
    var maxFiles = posNum(lim.maxDropFiles);
    if (maxFiles && items.length > maxFiles) { return tooManyFiles(maxFiles).userMessage; }
    var seen = Object.create(null);
    var total = 0;
    for (var i = 0; i < items.length; i++) {
      var it = items[i];
      total += it.file.size;
      if (maxBytes && it.file.size > maxBytes) {
        return 'Die Datei „' + it.path + '“ ist zu groß (' + formatSize(it.file.size) + ', erlaubt sind höchstens ' + formatSize(maxBytes) + ').';
      }
      var key = it.path.toLowerCase();
      if (seen[key]) {
        return 'Der Dateiname „' + it.path + '“ kommt mehrfach vor. Bitte Dateien mit gleichem Namen einzeln hinzufügen oder umbenennen.';
      }
      seen[key] = true;
    }
    if (maxBytes && total > maxBytes) {
      return 'Die Dateien sind zusammen zu groß (' + formatSize(total) + ', erlaubt sind höchstens ' + formatSize(maxBytes) + ').';
    }
    return '';
  }

  function handleSelection(items) {
    if (uploading) { return; }
    showDropError('');
    var err = validateItems(items);
    if (err) {
      showDropError(err);
      announce(err);
      return;
    }
    runUpload(items);
  }

  // ---- upload
  function httpErrorText(r) {
    if (r && r.data && typeof r.data.error === 'string' && r.data.error) { return r.data.error; }
    switch (r && r.status) {
      case 400: return 'Ungültiger Dateiname oder ungültige Anfrage.';
      case 409: return 'Konflikt: Die Datei ist doppelt oder der Zustand erlaubt das Ablegen gerade nicht.';
      case 411:
      case 413: return 'Die Datei oder die Gesamtgröße ist zu groß.';
      case 507: return 'Zu wenig Speicherplatz auf dem Datenlaufwerk.';
      default: return 'Das Hochladen ist fehlgeschlagen (HTTP ' + (r ? r.status : '?') + ').';
    }
  }

  function uploadFile(dropId, item) {
    var url = '/api/drop/file?drop=' + encodeURIComponent(dropId) + '&path=' + encodeURIComponent(item.path);
    if (mockApi) { return mockApi('POST', url, item.file); }
    return fetch(url, {
      method: 'POST',
      headers: { 'X-WS-Token': token, 'Content-Type': 'application/octet-stream' },
      body: item.file,
      cache: 'no-store'
    }).then(readResponse);
  }

  function showProgress(index, count, path, done, total) {
    setText(els.uploadFile, count > 1 ? 'Datei ' + (index + 1) + ' von ' + count + ': ' + path : path);
    setText(els.uploadBytes, formatSize(done) + ' von ' + formatSize(total));
    if (count === 1) {
      els.uploadProgress.removeAttribute('value'); // a single file: no per-file progress available
    } else if (total > 0) {
      els.uploadProgress.value = Math.round(done / total * 1000);
    } else {
      els.uploadProgress.value = Math.round(index / count * 1000);
    }
  }

  function runUpload(items) {
    var count = items.length;
    var total = 0;
    var done = 0;
    var dropId = null;
    items.forEach(function (it) { total += it.file.size; });

    cancelRequested = false;
    dropEpoch++;
    setUploading(true);
    setText(els.uploadTitle, 'Dateien werden hochgeladen …');
    setText(els.uploadFile, 'Wird vorbereitet …');
    setText(els.uploadBytes, '0 Bytes von ' + formatSize(total));
    els.uploadProgress.value = 0;
    els.btnUploadCancel.disabled = false;
    showDropStatus('');
    announce('Hochladen von ' + count + (count === 1 ? ' Datei' : ' Dateien') + ' gestartet.');
    els.btnUploadCancel.focus();

    function end(msg, note) {
      var discard = dropId
        ? api('POST', '/api/drop/discard', { dropId: dropId }).catch(function () { /* polling reports a lost backend */ })
        : Promise.resolve();
      return discard.then(function () {
        dropEpoch++;
        applyDrop(null);
        setUploading(false);
        showDropStatus(note || '');
        showDropError(msg || '');
        announce(msg || note || '');
        refreshSoon();
        els.btnFiles.focus();
      });
    }

    function next(i) {
      if (cancelRequested) { return Promise.reject({ cancelled: true }); }
      if (i >= count) { return Promise.resolve(); }
      var it = items[i];
      showProgress(i, count, it.path, done, total);
      return uploadFile(dropId, it).then(function (r) {
        if (r.status === 401 || r.status === 403) { throw { unauthorized: true }; }
        if (r.status !== 200) { throw fail(httpErrorText(r) + ' (Datei: ' + it.path + ')'); }
        done += it.file.size;
        return next(i + 1);
      }, function () {
        throw fail('Das Hochladen von „' + it.path + '“ ist fehlgeschlagen: Verbindung unterbrochen oder Datei nicht mehr lesbar.');
      });
    }

    api('POST', '/api/drop/begin', {}).then(function (r) {
      if (r.status !== 200 || !r.data || typeof r.data.dropId !== 'string' || !r.data.dropId) {
        if (r.status === 401 || r.status === 403) { throw { unauthorized: true }; }
        throw fail(httpErrorText(r));
      }
      dropId = r.data.dropId;
      dropEpoch++;
      applyDrop(null); // a new drop replaces the previous one on the backend
      return next(0);
    }).then(function () {
      els.btnUploadCancel.disabled = true;
      setText(els.uploadTitle, 'Wird abgeschlossen …');
      setText(els.uploadFile, '');
      els.uploadProgress.value = 1000;
      return api('POST', '/api/drop/finish', { dropId: dropId });
    }).then(function (r) {
      if (r.status === 401 || r.status === 403) { throw { unauthorized: true }; }
      if (r.status !== 200 || !r.data || typeof r.data.path !== 'string' || !r.data.path) { throw fail(httpErrorText(r)); }
      var info = { id: dropId, path: r.data.path, files: num(r.data.files), totalBytes: num(r.data.totalBytes) };
      dropEpoch++;
      setUploading(false);
      applyDrop(info);
      showDropStatus('');
      announce('Hochgeladen: ' + dropSummaryText(info) + '.');
      refreshSoon();
      els.folder.focus();
    }).catch(function (e) {
      if (stopped) { return; }
      if (e && e.unauthorized) {
        stopPolling();
        showFatal(MSG_UNAUTH, false);
        return;
      }
      if (e && e.cancelled) { return end('', 'Das Hochladen wurde abgebrochen.'); }
      if (e && typeof e.userMessage === 'string') { return end(e.userMessage, ''); }
      return end('Die Verbindung zum WorkspaceShare-Dienst wurde beim Hochladen unterbrochen.', '');
    });
  }

  els.btnUploadCancel.addEventListener('click', function () {
    cancelRequested = true;
    els.btnUploadCancel.disabled = true;
    setText(els.uploadTitle, 'Wird nach der aktuellen Datei abgebrochen …');
  });

  // ---- remove / replace an active drop
  // Resolves true when no drop is active (any more).
  function releaseDrop() {
    if (!dropInfo) { return Promise.resolve(true); }
    var info = dropInfo;
    removing = true;
    updateBusy();
    return api('POST', '/api/drop/discard', { dropId: info.id }).then(function (r) {
      removing = false;
      updateBusy();
      if (r.status === 200 || r.status === 400 || r.status === 404) {
        dropEpoch++;
        applyDrop(null);
        refreshSoon();
        return true;
      }
      showFormError(errorFromResponse(r, 'Die abgelegten Dateien konnten nicht entfernt werden.'));
      return false;
    }, function () {
      removing = false;
      updateBusy();
      showFormError('Die abgelegten Dateien konnten nicht entfernt werden.');
      return false;
    });
  }

  els.btnDropRemove.addEventListener('click', function () {
    showFormError('');
    releaseDrop().then(function (ok) {
      if (!ok) { return; }
      announce('Abgelegte Dateien entfernt.');
      els.btnFiles.focus();
    });
  });

  // ---- events
  function hasFiles(e) {
    var types = e.dataTransfer && e.dataTransfer.types;
    if (!types) { return false; }
    for (var i = 0; i < types.length; i++) { if (types[i] === 'Files') { return true; } }
    return false;
  }

  function setDropEffect(e, effect) {
    try { e.dataTransfer.dropEffect = effect; } catch (err) { /* ignore */ }
  }

  function inZone(e) {
    return e.target instanceof Node && els.dropzone.contains(e.target);
  }

  ['dragenter', 'dragover'].forEach(function (ev) {
    els.dropzone.addEventListener(ev, function (e) {
      if (!hasFiles(e)) { return; }
      e.preventDefault();
      if (!canAccept()) { setDropEffect(e, 'none'); return; }
      setDropEffect(e, 'copy');
      els.dropzone.classList.add('dz-over');
    });
  });

  els.dropzone.addEventListener('dragleave', function (e) {
    if (!(e.relatedTarget instanceof Node && els.dropzone.contains(e.relatedTarget))) {
      els.dropzone.classList.remove('dz-over');
    }
  });

  els.dropzone.addEventListener('drop', function (e) {
    if (!hasFiles(e)) { return; }
    e.preventDefault();
    els.dropzone.classList.remove('dz-over');
    if (!canAccept()) { return; }
    handleDrop(e.dataTransfer);
  });

  // Files dropped anywhere else never navigate the page; outside the zone the drop is ignored.
  ['dragenter', 'dragover'].forEach(function (ev) {
    window.addEventListener(ev, function (e) {
      if (!hasFiles(e)) { return; }
      e.preventDefault();
      if (!inZone(e)) {
        setDropEffect(e, 'none');
        els.dropzone.classList.remove('dz-over');
      }
    });
  });

  window.addEventListener('drop', function (e) {
    if (!hasFiles(e)) { return; }
    e.preventDefault();
    els.dropzone.classList.remove('dz-over');
  });

  window.addEventListener('dragend', function () { els.dropzone.classList.remove('dz-over'); });

  els.btnFiles.addEventListener('click', function () {
    if (canAccept()) { els.fileInput.click(); }
  });

  els.fileInput.addEventListener('change', function () {
    var list = Array.prototype.slice.call(els.fileInput.files || []);
    els.fileInput.value = ''; // allows picking the same files again
    if (!list.length || !canAccept()) { return; }
    handleSelection(list.map(function (f) {
      return { file: f, path: f.webkitRelativePath || f.name };
    }));
  });

  // ---------------------------------------------------------------- start
  function init() {
    if (mockMode) {
      token = 'mock';
    } else {
      var hash = location.hash || '';
      token = hash.charAt(0) === '#' ? hash.slice(1) : hash;
      try { history.replaceState(null, '', location.pathname); } catch (e) { /* ignore */ }
    }
    if (!token) {
      stopped = true;
      showFatal(MSG_NO_TOKEN, false);
      return;
    }
    poll();
  }

  init();
})();
