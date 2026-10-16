'use strict';

(function () {
  // ---------------------------------------------------------------- constants
  var POLL_MS = 1000;
  var MAX_FAILS = 5;
  var TOTAL_STEPS = 8;
  var NAME_MAX = 60;
  var NEW_TAB = 'new';
  var TOKEN_KEY = 'ws.token';
  var TAB_KEY_PREFIX = 'ws.tab.';

  var MSG_NO_TOKEN = 'Bitte die GUI über die Verknüpfung öffnen.';
  var MSG_LOST = 'Verbindung zum WorkspaceShare-Dienst verloren. Fenster schließen und über die Verknüpfung neu starten.';
  var MSG_UNAUTH = 'Die Sitzung ist ungültig (Token abgelehnt). Fenster schließen und über die Verknüpfung neu starten.';

  var MSG_OUTDATED = 'Der WorkspaceShare-Dienst ist veraltet. Bitte unten auf „Beenden“ klicken und WorkspaceShare über die Verknüpfung neu starten.';
  var MSG_UPDATED = 'WorkspaceShare wurde aktualisiert. Bitte das Fenster schließen und über die Verknüpfung neu öffnen.';

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

  // Screen-reader text for the status dot of a tab.
  var PHASE_LABELS = {
    starting: 'wird vorbereitet',
    active: 'aktiv',
    stopping: 'wird beendet',
    ended: 'beendet',
    error: 'Fehler'
  };

  // ---------------------------------------------------------------- helpers
  function $(id) { return document.getElementById(id); }

  var els = {
    live: $('live'),
    foot: $('foot'),
    headCount: $('head-count'),
    tabbar: $('tabbar'), tablist: $('tablist'), panel: $('panel'),
    views: {
      fatal: $('view-fatal'),
      quit: $('view-quit'),
      loading: $('view-loading'),
      form: $('view-form'),
      progress: $('view-progress'),
      active: $('view-active'),
      stopping: $('view-stopping'),
      done: $('view-done')
    },
    fatalText: $('fatal-text'),
    shareHead: $('share-head'), nameView: $('name-view'), shareTitle: $('share-title'),
    btnRename: $('btn-rename'), renameForm: $('rename-form'), renameInput: $('rename-input'),
    renameError: $('rename-error'),
    endedBox: $('ended-box'), endedText: $('ended-text'),
    errorBox: $('error-box'), errorTitle: $('error-title'), errorHint: $('error-hint'),
    errorMessage: $('error-message'), errorDetails: $('error-details'), errorLog: $('error-log'),
    btnDismiss: $('btn-dismiss'),
    form: $('form'), folder: $('folder'), btnPick: $('btn-pick'), nameInput: $('name-input'),
    minutes: $('minutes'), compression: $('compression'), includeGenerated: $('include-generated'),
    advanced: $('advanced'), formError: $('form-error'), limitHint: $('limit-hint'), btnStart: $('btn-start'),
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

  var SHARE_VIEWS = { progress: true, active: true, stopping: true, done: true };
  var BARE_VIEWS = { fatal: true, quit: true, loading: true };

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

  function num(v) { return typeof v === 'number' && isFinite(v) && v >= 0 ? v : 0; }
  function posNum(v) { return typeof v === 'number' && isFinite(v) && v > 0 ? v : 0; }

  function isRunningPhase(p) { return p === 'starting' || p === 'active' || p === 'stopping'; }

  // Last path segment of a typed folder (display only; the backend computes the real default).
  function leafOf(p) {
    var parts = String(p).split(/[\\\/]+/).filter(function (x) { return x; });
    return parts.length ? parts[parts.length - 1] : '';
  }

  function clipName(s) { return s.length > NAME_MAX ? s.slice(0, NAME_MAX) : s; }

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
    var MOCK_LIMITS = { maxDropBytes: 4294967296, maxDropFiles: 10000, maxShares: 3 };
    var PICKS = ['C:\\Projekte\\Beispiel-Workspace', 'C:\\Projekte\\Webseite', 'C:\\Projekte\\Berichte 2026'];
    var shares = [];
    var draft = null;       // { id, path, files, totalBytes, finished, paths, tops }
    var pickIndex = 0;

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

    function runningCount() {
      return shares.filter(function (x) { return isRunningPhase(x.phase); }).length;
    }

    function findShare(id) {
      for (var i = 0; i < shares.length; i++) { if (shares[i].id === id) { return shares[i]; } }
      return null;
    }

    function clearTimers(sh) {
      if (sh.timer) { window.clearInterval(sh.timer); window.clearTimeout(sh.timer); sh.timer = null; }
      if (sh.healthTimer) { window.clearTimeout(sh.healthTimer); sh.healthTimer = null; }
    }

    // Mirrors contract 8.2.
    function defaultName(path) {
      if (draft && draft.finished && draft.path === path && draft.tops.length) {
        return draft.tops.length === 1 ? draft.tops[0] : draft.tops[0] + ' +' + (draft.tops.length - 1);
      }
      return leafOf(path) || 'Freigabe';
    }

    // Name rules of the backend: trimmed, 1-60 chars, no control characters ("fehler" is a mock-only rejection).
    function nameProblem(raw) {
      var n = typeof raw === 'string' ? raw.trim() : '';
      if (!n || n.length > NAME_MAX || /[\u0000-\u001f\u007f]/.test(n)) {
        return 'Der Name muss 1 bis 60 Zeichen lang sein und darf keine Steuerzeichen enthalten.';
      }
      if (/fehler/i.test(n)) { return 'Dieser Name wurde vom Mock abgelehnt.'; }
      return '';
    }

    function shareSnap(sh) {
      var rem = null;
      if (sh.expiresUtc) { rem = Math.max(0, Math.ceil((Date.parse(sh.expiresUtc) - Date.now()) / 60000)); }
      return {
        id: sh.id, name: sh.name, createdUtc: sh.createdUtc, phase: sh.phase,
        step: sh.step, total: TOTAL_STEPS, stepText: sh.step ? STEP_TEXTS[sh.step - 1] : null,
        steps: sh.steps.slice(), url: sh.url, expiresUtc: sh.expiresUtc, sizeBytes: sh.sizeBytes, sha256: sh.sha256,
        remainingMinutes: rem, health: sh.health, exitCode: sh.exitCode, reason: sh.reason, message: sh.message,
        log: sh.log.slice(), request: sh.request, dropFiles: sh.dropFiles
      };
    }

    function snapshot() {
      return {
        v: 2, build: 'mock', platform: 'windows',
        capabilities: { folderPicker: true, clipboard: true, openBrowser: true },
        limits: MOCK_LIMITS,
        running: runningCount(),
        draft: {
          drop: draft ? { id: draft.id, path: draft.path, files: draft.files, totalBytes: draft.totalBytes, finished: draft.finished } : null
        },
        shares: shares.map(shareSnap)
      };
    }

    function beginEnd(sh, reason, message) {
      clearTimers(sh);
      sh.phase = 'stopping';
      sh.timer = window.setTimeout(function () {
        sh.phase = 'ended'; sh.exitCode = 0; sh.reason = reason; sh.message = message;
        sh.url = null; sh.expiresUtc = null; sh.timer = null;
      }, 1500);
    }

    function startRun(req, name, dropFiles) {
      var sh = {
        id: randomHex(8), name: name, createdUtc: new Date().toISOString(), phase: 'starting',
        step: 0, steps: [], url: null, expiresUtc: null, sizeBytes: null, sha256: null, health: null,
        exitCode: null, reason: null, message: null, log: ['[mock] Start: ' + req.path],
        request: req, dropFiles: dropFiles, timer: null, healthTimer: null
      };
      var failAt = /fehler/i.test(req.path) ? 4 : 0;
      shares.push(sh);
      sh.timer = window.setInterval(function () {
        sh.step += 1;
        sh.steps.push({ n: sh.step, text: STEP_TEXTS[sh.step - 1] });
        sh.log.push('[mock] Schritt ' + sh.step + '/' + TOTAL_STEPS);
        if (failAt && sh.step === failAt) {
          clearTimers(sh);
          sh.phase = 'error'; sh.exitCode = 22; sh.reason = 'SecretScan';
          sh.message = 'Verbotene Datei gefunden: .env (Mock)';
          sh.log.push('[mock] FEHLER: Verbotene Datei gefunden');
          return;
        }
        if (sh.step >= TOTAL_STEPS) {
          clearTimers(sh);
          sh.phase = 'active';
          sh.url = 'https://mock-' + sh.id + '.trycloudflare.com/workspace-' + sh.id + '.zip';
          sh.expiresUtc = new Date(Date.now() + req.minutes * 60000).toISOString();
          sh.sizeBytes = 48234496;
          sh.sha256 = '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';
          sh.health = 'ok';
          sh.healthTimer = window.setTimeout(function () {
            sh.health = 'degraded';
            sh.healthTimer = window.setTimeout(function () { sh.health = 'recovered'; sh.healthTimer = null; }, 6000);
          }, 12000);
        }
      }, 700);
      return sh;
    }

    // Mock of the /api/drop/* endpoints (body of /api/drop/file is the File). Allowed while shares run.
    function mockDrop(p, query, body) {
      if (p === '/api/drop/begin') {
        var id = randomHex(32);
        draft = { id: id, path: newDropPath(id), files: 0, totalBytes: 0, finished: false, paths: {}, tops: [] };
        return { status: 200, data: { dropId: id } };
      }
      var q = parseQuery(query);
      var b = body || {};
      if (p === '/api/drop/file') {
        if (!draft || draft.finished || q.drop !== draft.id) { return { status: 400, data: { error: 'Unbekannte Ablage.' } }; }
        var rel = q.path || '';
        if (/fehler/i.test(rel)) { return { status: 400, data: { error: 'Ungültiger Dateiname: ' + rel + ' (Mock)' } }; }
        if (/voll/i.test(rel)) { return { status: 507, data: {} }; }
        var key = rel.toLowerCase();
        if (draft.paths[key]) { return { status: 409, data: { error: 'Datei doppelt: ' + rel } }; }
        draft.paths[key] = true;
        var top = rel.split('/')[0];
        if (draft.tops.indexOf(top) < 0) { draft.tops.push(top); }
        var size = typeof b.size === 'number' ? b.size : 0;
        draft.files += 1;
        draft.totalBytes += size;
        return { status: 200, data: { ok: true, bytes: size } };
      }
      if (p === '/api/drop/finish' || p === '/api/drop/discard') {
        if (!draft || b.dropId !== draft.id) {
          return { status: p === '/api/drop/discard' ? 200 : 400, data: p === '/api/drop/discard' ? { ok: true } : { error: 'Unbekannte Ablage.' } };
        }
        if (p === '/api/drop/discard') { draft = null; return { status: 200, data: { ok: true } }; }
        if (draft.files < 1) { return { status: 400, data: { error: 'Es wurde keine Datei empfangen.' } }; }
        draft.finished = true;
        return { status: 200, data: { path: draft.path, files: draft.files, totalBytes: draft.totalBytes } };
      }
      return { status: 404, data: { error: 'Unbekannt' } };
    }

    function mockShareAction(id, act, body) {
      var sh = findShare(id);
      if (!sh) { return { status: 404, data: { error: 'Unbekannte Freigabe.' } }; }
      var b = body || {};
      if (act === 'stop') {
        if (sh.phase === 'starting' || sh.phase === 'active') { beginEnd(sh, 'ManualStop', 'Freigabe wurde beendet.'); }
        else if (sh.phase !== 'stopping') { return { status: 409, data: { error: 'Die Freigabe ist bereits beendet.' } }; }
        return { status: 200, data: { ok: true } };
      }
      if (act === 'copy') {
        return sh.url ? { status: 200, data: { ok: true } } : { status: 409, data: { error: 'Kein Link vorhanden.' } };
      }
      if (act === 'rename') {
        var prob = nameProblem(b.name);
        if (prob) { return { status: 400, data: { error: prob } }; }
        sh.name = b.name.trim();
        return { status: 200, data: { ok: true, name: sh.name } };
      }
      if (act === 'dismiss') {
        if (sh.phase !== 'ended' && sh.phase !== 'error') { return { status: 409, data: { error: 'Die Freigabe läuft noch.' } }; }
        clearTimers(sh);
        shares.splice(shares.indexOf(sh), 1);
        return { status: 200, data: { ok: true } };
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
          var m = /^\/api\/shares\/([0-9a-f]{8})\/(stop|copy|rename|dismiss)$/.exec(path);
          if (path.indexOf('/api/drop/') === 0) {
            r = mockDrop(path, query, body);
          } else if (m) {
            r = mockShareAction(m[1], m[2], body);
          } else if (path === '/api/state') {
            r.data = snapshot();
          } else if (path === '/api/pick-folder') {
            r.data = { path: PICKS[pickIndex++ % PICKS.length] };
          } else if (path === '/api/start') {
            if (runningCount() >= MOCK_LIMITS.maxShares) {
              r = { status: 409, data: { error: 'Maximal ' + MOCK_LIMITS.maxShares + ' Freigaben gleichzeitig.' } };
            } else if (!body || !body.path) {
              r = { status: 400, data: { error: 'Der Ordner existiert nicht.' } };
            } else if (typeof body.name === 'string' && body.name.trim() && nameProblem(body.name)) {
              r = { status: 400, data: { error: nameProblem(body.name) } };
            } else {
              var nm = typeof body.name === 'string' && body.name.trim() ? body.name.trim() : defaultName(body.path);
              var dropFiles = null;
              if (draft && draft.finished && draft.path === body.path) { dropFiles = draft.files; draft = null; }
              var sh = startRun({ path: body.path, minutes: body.minutes, compression: body.compression, includeGenerated: !!body.includeGenerated }, nm, dropFiles);
              r.data = { ok: true, shareId: sh.id };
            }
          } else if (path === '/api/quit') {
            shares.forEach(clearTimers);
            draft = null;
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

  function shareApi(id, act) { return '/api/shares/' + encodeURIComponent(id) + '/' + act; }

  // ---------------------------------------------------------------- session storage (per browser tab, never the URL)
  function storageGet(key) {
    try { return window.sessionStorage.getItem(key); } catch (e) { return null; }
  }

  function storageSet(key, value) {
    try { window.sessionStorage.setItem(key, value); } catch (e) { /* ignore */ }
  }

  function storageRemove(key) {
    try { window.sessionStorage.removeItem(key); } catch (e) { /* ignore */ }
  }

  // ---------------------------------------------------------------- view switching
  var currentView = '';

  function showView(name) {
    if (currentView === name) { return; }
    currentView = name;
    Object.keys(els.views).forEach(function (k) { setHidden(els.views[k], k !== name); });
    var bare = !!BARE_VIEWS[name];
    setHidden(els.tabbar, bare);
    setHidden(els.panel, bare);
    setHidden(els.headCount, bare);
    setHidden(els.shareHead, !SHARE_VIEWS[name]);
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
  var lastRenderable = false;   // lastState is a usable state v2
  var outdatedShown = false;
  var knownBuild = null;        // build id of the backend seen on the first poll

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
        // The backend was restarted (new token): the stored one is useless now.
        storageRemove(TOKEN_KEY);
        stopPolling();
        showFatal(MSG_UNAUTH, false);
        return;
      }
      if (r.status !== 200 || !r.data || typeof r.data !== 'object') {
        throw new Error('bad state');
      }
      // Backend replaced while this page is open: reloading cannot help, the page must be opened again.
      if (typeof r.data.build === 'string') {
        if (knownBuild === null) { knownBuild = r.data.build; }
        else if (knownBuild !== r.data.build) {
          stopPolling();
          showFatal(MSG_UPDATED, false);
          return;
        }
      }
      fails = 0;
      lastState = r.data;
      // An older backend answers a state without the v2 share list.
      if (r.data.v !== 2 || !Array.isArray(r.data.shares)) {
        lastRenderable = false;
        if (!outdatedShown) {
          outdatedShown = true;
          showFatal(MSG_OUTDATED, true);
        }
        return;
      }
      lastRenderable = true;
      if (!r.data.limits || typeof r.data.limits !== 'object') { markOutdated(); }
      try {
        render(r.data, epoch !== dropEpoch);
      } catch (e) {
        if (window.console && console.error) { console.error(e); }
      }
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

  // ---------------------------------------------------------------- selection / tabs
  var selected = null;            // shareId, NEW_TAB, or null before the first state
  var tabStop = null;             // tab key holding tabindex 0 (roving)
  var selectionInit = false;
  var storageKey = null;
  var pendingSelect = null;       // freshly started share that the state does not list yet
  var pendingUntil = 0;
  var lastIds = [];
  var seenPhases = null;          // shareId -> last seen phase (null before the first state)
  var tabEls = {};                // key -> { btn, dot, label, sr }
  var renameOverrides = {};       // shareId -> { name, until }; hides a stale poll right after a rename
  var editingId = null;
  var renameBusy = false;
  var shareUiKey = '';
  var lastTabScroll = null;
  var stepsSig = '';
  var announceKey = '';

  function findShare(id) {
    var list = lastState && Array.isArray(lastState.shares) ? lastState.shares : [];
    for (var i = 0; i < list.length; i++) { if (list[i] && list[i].id === id) { return list[i]; } }
    return null;
  }

  function shareName(sh) {
    var o = renameOverrides[sh.id];
    if (o) {
      if (o.name === sh.name || Date.now() > o.until) { delete renameOverrides[sh.id]; }
      else { return o.name; }
    }
    return typeof sh.name === 'string' && sh.name ? sh.name : 'Freigabe';
  }

  function runningOf(st) {
    if (!st) { return 0; }
    if (Array.isArray(st.shares)) {
      if (typeof st.running === 'number' && isFinite(st.running)) { return st.running; }
      return st.shares.filter(function (s) { return s && isRunningPhase(s.phase); }).length;
    }
    return isRunningPhase(st.phase) ? 1 : 0;
  }

  function storeSelection() {
    if (storageKey && selected) { storageSet(storageKey, selected); }
  }

  function chooseInitialSelection(shares) {
    var stored = storageKey ? storageGet(storageKey) : null;
    if (stored === NEW_TAB) { return NEW_TAB; }
    if (stored) {
      for (var i = 0; i < shares.length; i++) { if (shares[i].id === stored) { return stored; } }
    }
    for (var j = shares.length - 1; j >= 0; j--) {
      if (isRunningPhase(shares[j].phase)) { return shares[j].id; }
    }
    return NEW_TAB;
  }

  function makeTab(key) {
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.id = 'tab-' + key;
    btn.className = 'tab' + (key === NEW_TAB ? ' tab-new' : '');
    btn.setAttribute('role', 'tab');
    btn.setAttribute('aria-controls', 'panel');
    btn.setAttribute('data-key', key);
    var dot = null;
    if (key !== NEW_TAB) {
      dot = document.createElement('span');
      dot.setAttribute('aria-hidden', 'true');
      dot.className = 'tdot';
      btn.appendChild(dot);
    }
    var label = document.createElement('span');
    label.className = 'tab-label';
    btn.appendChild(label);
    var sr = null;
    if (key !== NEW_TAB) {
      sr = document.createElement('span');
      sr.className = 'sr-only';
      btn.appendChild(sr);
    }
    return { btn: btn, dot: dot, label: label, sr: sr };
  }

  function tabKeys() {
    return Array.prototype.map.call(els.tablist.children, function (c) { return c.getAttribute('data-key'); });
  }

  function updateTabIndexes() {
    var stop = tabEls[tabStop] ? tabStop : (tabEls[selected] ? selected : NEW_TAB);
    Object.keys(tabEls).forEach(function (k) {
      var t = tabEls[k];
      t.btn.setAttribute('tabindex', k === stop ? '0' : '-1');
    });
  }

  function scrollTabIntoView(key) {
    var t = tabEls[key];
    if (!t) { return; }
    var bar = els.tabbar;
    var left = t.btn.offsetLeft;
    var right = left + t.btn.offsetWidth;
    if (left < bar.scrollLeft) { bar.scrollLeft = Math.max(0, left - 8); }
    else if (right > bar.scrollLeft + bar.clientWidth) { bar.scrollLeft = right - bar.clientWidth + 8; }
  }

  function renderTabs(shares) {
    var focusedKey = null;
    var ae = document.activeElement;
    if (ae && ae.getAttribute && els.tablist.contains(ae)) { focusedKey = ae.getAttribute('data-key'); }

    var wanted = shares.map(function (s) { return s.id; });
    wanted.push(NEW_TAB);
    Object.keys(tabEls).forEach(function (k) {
      if (wanted.indexOf(k) < 0) {
        if (tabEls[k].btn.parentNode) { tabEls[k].btn.parentNode.removeChild(tabEls[k].btn); }
        delete tabEls[k];
        if (tabStop === k) { tabStop = null; }
      }
    });
    wanted.forEach(function (k, i) {
      var t = tabEls[k];
      if (!t) { t = makeTab(k); tabEls[k] = t; }
      if (els.tablist.children[i] !== t.btn) { els.tablist.insertBefore(t.btn, els.tablist.children[i] || null); }
      t.btn.setAttribute('aria-selected', k === selected ? 'true' : 'false');
      if (k === NEW_TAB) {
        setText(t.label, '+ Neue Freigabe');
      } else {
        var sh = null;
        for (var n = 0; n < shares.length; n++) { if (shares[n].id === k) { sh = shares[n]; break; } }
        var name = shareName(sh);
        setText(t.label, name);
        if (t.btn.title !== name) { t.btn.title = name; }
        var cls = 'tdot tdot-' + (PHASE_LABELS[sh.phase] ? sh.phase : 'ended');
        if (t.dot.className !== cls) { t.dot.className = cls; }
        setText(t.sr, ' (' + (PHASE_LABELS[sh.phase] || sh.phase) + ')');
      }
    });
    updateTabIndexes();
    if (focusedKey && tabEls[focusedKey] && document.activeElement !== tabEls[focusedKey].btn) { tabEls[focusedKey].btn.focus(); }
    if (lastTabScroll !== selected) {
      lastTabScroll = selected;
      scrollTabIntoView(selected);
    }
  }

  function selectTab(key) {
    if (key === selected) { return; }
    if (editingId) { endEdit(false); }
    selected = key;
    tabStop = key;
    storeSelection();
    renderCurrent();
  }

  function renderCurrent() {
    if (lastState && lastRenderable) {
      try { render(lastState, true); } catch (e) { if (window.console && console.error) { console.error(e); } }
    }
  }

  els.tablist.addEventListener('click', function (e) {
    var tab = e.target instanceof Element ? e.target.closest('[role="tab"]') : null;
    if (!tab) { return; }
    selectTab(tab.getAttribute('data-key'));
  });

  els.tablist.addEventListener('dblclick', function (e) {
    var tab = e.target instanceof Element ? e.target.closest('[role="tab"]') : null;
    if (!tab) { return; }
    var key = tab.getAttribute('data-key');
    if (key === NEW_TAB) { return; }
    selectTab(key);
    startEdit(key);
  });

  els.tablist.addEventListener('keydown', function (e) {
    var tab = e.target instanceof Element ? e.target.closest('[role="tab"]') : null;
    if (!tab) { return; }
    var keys = tabKeys();
    var i = keys.indexOf(tab.getAttribute('data-key'));
    var next = -1;
    if (e.key === 'ArrowRight') { next = (i + 1) % keys.length; }
    else if (e.key === 'ArrowLeft') { next = (i - 1 + keys.length) % keys.length; }
    else if (e.key === 'Home') { next = 0; }
    else if (e.key === 'End') { next = keys.length - 1; }
    if (next < 0) { return; }
    e.preventDefault();
    tabStop = keys[next];
    updateTabIndexes();
    tabEls[tabStop].btn.focus();
  });

  // ---------------------------------------------------------------- rename
  function showRenameError(text) {
    setText(els.renameError, text);
    setHidden(els.renameError, !text);
  }

  function startEdit(id) {
    var sh = findShare(id);
    if (!sh || selected !== id || !SHARE_VIEWS[currentView]) { return; }
    editingId = id;
    renameBusy = false;
    els.renameInput.value = shareName(sh);
    els.renameInput.readOnly = false;
    showRenameError('');
    setHidden(els.nameView, true);
    setHidden(els.renameForm, false);
    els.renameInput.focus();
    els.renameInput.select();
  }

  function endEdit(refocus) {
    var had = editingId;
    editingId = null;
    renameBusy = false;
    els.renameInput.readOnly = false;
    setHidden(els.renameForm, true);
    setHidden(els.nameView, false);
    showRenameError('');
    if (refocus && had && !els.shareHead.hidden) { els.btnRename.focus(); }
  }

  function commitRename(fromBlur) {
    if (!editingId || renameBusy) { return; }
    var id = editingId;
    var sh = findShare(id);
    if (!sh) { endEdit(false); return; }
    var val = els.renameInput.value.trim();
    if (val === shareName(sh)) { endEdit(!fromBlur); return; }
    if (!val) {
      if (fromBlur) { endEdit(false); } else { showRenameError('Der Name darf nicht leer sein.'); }
      return;
    }
    renameBusy = true;
    els.renameInput.readOnly = true;
    showRenameError('');
    action(shareApi(id, 'rename'), { name: val }).then(function (r) {
      renameBusy = false;
      els.renameInput.readOnly = false;
      if (r.status === 200 && r.data && r.data.ok) {
        var nm = typeof r.data.name === 'string' && r.data.name ? r.data.name : val;
        renameOverrides[id] = { name: nm, until: Date.now() + 3000 };
        if (selected === id) { setText(els.shareTitle, nm); }
        if (editingId === id) { endEdit(!fromBlur); }
        renderCurrent();
        refreshSoon();
      } else if (editingId === id) {
        showRenameError(errorFromResponse(r, 'Der Name konnte nicht geändert werden.'));
        if (!fromBlur) { els.renameInput.focus(); }
      }
    }).catch(function () { renameBusy = false; });
  }

  els.btnRename.addEventListener('click', function () { if (selected && selected !== NEW_TAB) { startEdit(selected); } });

  els.renameForm.addEventListener('submit', function (e) {
    e.preventDefault();
    commitRename(false);
  });

  els.renameInput.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      endEdit(true);
    }
  });

  els.renameInput.addEventListener('blur', function () { commitRename(true); });

  // ---------------------------------------------------------------- rendering
  var DROP_PATH_RE = /[\\\/]drops[\\\/][0-9a-f]{32}(?:[\\\/]|$)/i;

  function updateStartButton() {
    var lim = lastState && lastState.limits ? lastState.limits : null;
    var max = lim ? posNum(lim.maxShares) : 0;
    var full = !!max && runningOf(lastState) >= max;
    els.btnStart.disabled = uploading || startPending || full;
    if (full) {
      setText(els.limitHint, 'Maximal ' + max + (max === 1 ? ' Freigabe' : ' Freigaben') + ' gleichzeitig. Bitte erst eine beenden.');
    }
    setHidden(els.limitHint, !full);
  }

  function renderNewTab(st) {
    setHidden(els.btnPick, !(st.capabilities && st.capabilities.folderPicker));
    updateStartButton();
    updateNamePreview();
  }

  function renderShareHead(sh) {
    if (editingId && editingId !== sh.id) { endEdit(false); }
    if (editingId !== sh.id) { setText(els.shareTitle, shareName(sh)); }
  }

  function resetShareUi(sh) {
    var key = sh.id + '|' + sh.phase;
    if (key === shareUiKey) { return; }
    shareUiKey = key;
    els.btnCancel.disabled = false;
    els.btnStop.disabled = false;
    els.btnDismiss.disabled = false;
    els.btnCopy.disabled = false;
    showCopyError('');
    if (copyTimer) { window.clearTimeout(copyTimer); copyTimer = null; }
    setText(els.btnCopy, 'Link kopieren');
  }

  function renderDone(sh) {
    var ended = sh.phase === 'ended';
    var failed = sh.phase === 'error';

    setHidden(els.endedBox, !ended);
    if (ended) {
      setText(els.endedText, REASON_TEXTS[sh.reason] || sh.message || sh.reason || '');
    }

    setHidden(els.errorBox, !failed);
    if (failed) {
      var code = sh.exitCode;
      setText(els.errorTitle, 'Freigabe fehlgeschlagen' + (code != null ? ' (Exit-Code ' + code + ')' : ''));
      setText(els.errorHint, EXIT_TEXTS[code] || '');
      setText(els.errorMessage, sh.message || '');
      var log = Array.isArray(sh.log) ? sh.log : [];
      setHidden(els.errorDetails, log.length === 0);
      setText(els.errorLog, log.join('\n'));
    }
    return failed ? 'Freigabe fehlgeschlagen. ' + (EXIT_TEXTS[sh.exitCode] || '') : 'Freigabe beendet.';
  }

  function renderProgress(sh) {
    var total = typeof sh.total === 'number' && sh.total > 0 ? sh.total : TOTAL_STEPS;
    var cur = typeof sh.step === 'number' ? sh.step : 0;
    var texts = {};
    (Array.isArray(sh.steps) ? sh.steps : []).forEach(function (s) { if (s && typeof s.n === 'number') { texts[s.n] = s.text; } });

    var sig = sh.id + '|' + total + '|' + cur + '|' + JSON.stringify(texts);
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
    var current = sh.stepText || (cur && texts[cur]) || '';
    setText(els.stepCurrent, current ? 'Schritt ' + cur + ' von ' + total + ': ' + current : 'Wird gestartet …');
    return 'Freigabe wird vorbereitet. ' + current;
  }

  function renderActive(sh) {
    // Show a short text instead of the long temp path when dropped files are shared.
    var reqPath = sh.request && typeof sh.request.path === 'string' ? sh.request.path : '';
    var fromDrop = typeof sh.dropFiles === 'number' || (!!reqPath && DROP_PATH_RE.test(reqPath));
    var from = '';
    if (fromDrop) {
      var n = typeof sh.dropFiles === 'number' ? sh.dropFiles : null;
      from = 'Freigegeben: ' + (n == null ? 'abgelegte Dateien'
        : n.toLocaleString('de-DE') + (n === 1 ? ' abgelegte Datei' : ' abgelegte Dateien'));
    } else if (reqPath) {
      from = 'Ordner: ' + reqPath;
    }
    setText(els.sharedFrom, from);
    setHidden(els.sharedFrom, !from);

    if (els.shareUrl.value !== (sh.url || '')) { els.shareUrl.value = sh.url || ''; }
    setText(els.factUntil, sh.expiresUtc ? formatUntil(sh.expiresUtc) : '–');

    var rem = sh.remainingMinutes;
    if (typeof rem !== 'number' && sh.expiresUtc) {
      rem = Math.max(0, Math.ceil((Date.parse(sh.expiresUtc) - Date.now()) / 60000));
    }
    setText(els.factRemaining, formatRemaining(rem));
    setText(els.factSize, formatSize(sh.sizeBytes));
    setText(els.factSha, sh.sha256 || '–');

    // No health event yet means every check so far has passed.
    var h = HEALTH_TEXTS[sh.health || 'ok'];
    els.healthDot.className = 'dot dot-' + (h ? h[0] : 'none');
    setText(els.healthText, h ? h[1] : 'Keine Meldung');
    return 'Freigabe aktiv.';
  }

  function headCountText(n) {
    return n + (n === 1 ? ' aktive Freigabe' : ' aktive Freigaben');
  }

  function announcePhaseChanges(shares, first) {
    var nextSeen = {};
    shares.forEach(function (sh) {
      nextSeen[sh.id] = sh.phase;
      if (first || !seenPhases || sh.id === selected) { return; }
      var prev = seenPhases[sh.id];
      if (!prev || prev === sh.phase) { return; }
      var what = sh.phase === 'active' ? 'ist jetzt aktiv.' : (sh.phase === 'ended' ? 'wurde beendet.' : (sh.phase === 'error' ? 'ist fehlgeschlagen.' : ''));
      if (what) { announce('Freigabe „' + shareName(sh) + '“ ' + what); }
    });
    seenPhases = nextSeen;
  }

  function render(st, dropStale) {
    var shares = st.shares.filter(function (s) { return s && typeof s.id === 'string'; });
    var ids = shares.map(function (s) { return s.id; });

    if (!selectionInit) {
      selectionInit = true;
      storageKey = TAB_KEY_PREFIX + (typeof st.build === 'string' ? st.build : '');
      selected = chooseInitialSelection(shares);
      tabStop = selected;
      storeSelection();
    }

    // A share that was just started may not be listed yet; keep the UI as it is until it shows up.
    if (pendingSelect) {
      if (ids.indexOf(pendingSelect) >= 0 || Date.now() > pendingUntil) { pendingSelect = null; }
      else { return; }
    }

    // The selected share disappeared (dismissed elsewhere): fall back to its left neighbour or the form.
    if (selected !== NEW_TAB && ids.indexOf(selected) < 0) {
      var idx = lastIds.indexOf(selected);
      var fallback = idx > 0 && ids.indexOf(lastIds[idx - 1]) >= 0 ? lastIds[idx - 1] : NEW_TAB;
      if (editingId) { endEdit(false); }
      selected = fallback;
      tabStop = fallback;
      storeSelection();
    }
    lastIds = ids;

    announcePhaseChanges(shares, seenPhases === null);

    setText(els.headCount, headCountText(runningOf(st)));
    renderTabs(shares);
    var tabId = 'tab-' + selected;
    if (els.panel.getAttribute('aria-labelledby') !== tabId) { els.panel.setAttribute('aria-labelledby', tabId); }

    var label;
    var sh = selected === NEW_TAB ? null : findShareIn(shares, selected);
    if (!sh) {
      showView('form');
      renderNewTab(st);
      label = 'Neue Freigabe.';
      // While uploading, the form is left alone; the drop state is re-rendered after the upload.
      if (!uploading && !dropStale) { applyDrop(dropFromState(st)); }
    } else {
      renderShareHead(sh);
      resetShareUi(sh);
      switch (sh.phase) {
        case 'starting':
          showView('progress');
          label = renderProgress(sh);
          break;
        case 'active':
          showView('active');
          label = renderActive(sh);
          break;
        case 'stopping':
          showView('stopping');
          label = 'Freigabe wird beendet …';
          break;
        default: // ended, error
          showView('done');
          label = renderDone(sh);
          break;
      }
      if (!uploading && !dropStale) { applyDrop(dropFromState(st)); }
    }
    setHidden(els.foot, false);

    var key = selected + '|' + (sh ? sh.phase + '|' + sh.exitCode : '');
    if (key !== announceKey) {
      announceKey = key;
      announce(sh ? '„' + shareName(sh) + '“: ' + label : label);
    }
  }

  function findShareIn(list, id) {
    for (var i = 0; i < list.length; i++) { if (list[i].id === id) { return list[i]; } }
    return null;
  }

  // ---------------------------------------------------------------- user actions
  var startPending = false;
  var picking = false;

  function showFormError(text) {
    setText(els.formError, text);
    setHidden(els.formError, !text);
  }

  function errorFromResponse(r, fallback) {
    if (r && r.data && typeof r.data.error === 'string' && r.data.error) { return r.data.error; }
    if (r && r.status === 409) { return 'Das ist im aktuellen Zustand nicht möglich.'; }
    return fallback;
  }

  function onFormInput() { showFormError(''); }
  ['input', 'change'].forEach(function (ev) { els.form.addEventListener(ev, onFormInput); });
  els.folder.addEventListener('input', updateNamePreview);

  // Placeholder of the name field: what the backend will most likely use (display only, contract 8.2).
  function updateNamePreview() {
    var d = '';
    if (dropInfo) {
      if (dropTops && dropTops.length) {
        d = dropTops.length === 1 ? dropTops[0] : dropTops[0] + ' +' + (dropTops.length - 1);
      }
    } else {
      d = leafOf(els.folder.value.trim());
    }
    var ph = d ? clipName(d) : 'Wird automatisch vergeben';
    if (els.nameInput.placeholder !== ph) { els.nameInput.placeholder = ph; }
  }

  function afterStart(shareId) {
    els.folder.value = '';
    els.nameInput.value = '';
    dropEpoch++;
    applyDrop(null);
    showDropStatus('');
    showFormError('');
    updateNamePreview();
    if (typeof shareId === 'string' && shareId) {
      selected = shareId;
      tabStop = shareId;
      pendingSelect = shareId;
      pendingUntil = Date.now() + 5000;
      storeSelection();
    }
    refreshSoon();
  }

  els.form.addEventListener('submit', function (e) {
    e.preventDefault();
    if (uploading || startPending) { return; }
    var path = els.folder.value.trim();
    if (!path) {
      showFormError('Bitte einen Ordner angeben.');
      els.folder.focus();
      return;
    }
    showFormError('');
    startPending = true;
    updateStartButton();
    var name = els.nameInput.value.trim();
    action('/api/start', {
      path: path,
      minutes: parseInt(els.minutes.value, 10),
      compression: els.compression.value,
      includeGenerated: els.includeGenerated.checked,
      name: name || null
    }).then(function (r) {
      startPending = false;
      if (r.status === 200 && r.data && r.data.ok) {
        afterStart(r.data.shareId);
      } else {
        var max = lastState && lastState.limits ? posNum(lastState.limits.maxShares) : 0;
        var fb = r.status === 409 && max
          ? 'Maximal ' + max + (max === 1 ? ' Freigabe' : ' Freigaben') + ' gleichzeitig. Bitte erst eine beenden.'
          : 'Die Freigabe konnte nicht gestartet werden.';
        showFormError(errorFromResponse(r, fb));
      }
      updateStartButton();
    }).catch(function () { startPending = false; /* fatal already shown */ });
  });

  els.btnPick.addEventListener('click', function () {
    picking = true;
    updateBusy();
    showFormError('');
    action('/api/pick-folder', {}).then(function (r) {
      picking = false;
      updateBusy();
      if (r.status === 200 && r.data && typeof r.data.path === 'string' && r.data.path) {
        var picked = r.data.path;
        // A picked folder replaces an active drop (discarded first).
        return releaseDrop().then(function (ok) {
          if (!ok) { return; }
          els.folder.value = picked;
          updateNamePreview();
        });
      } else if (r.status === 200) {
        /* cancelled: nothing */
      } else if (r.status === 501) {
        showFormError('Die Ordnerauswahl wird auf diesem System nicht unterstützt. Bitte den Pfad eintragen.');
      } else {
        showFormError(errorFromResponse(r, 'Die Ordnerauswahl ist fehlgeschlagen.'));
      }
    }).catch(function () { picking = false; updateBusy(); });
  });

  els.btnCancel.addEventListener('click', function () {
    var id = selected;
    els.btnCancel.disabled = true;
    action(shareApi(id, 'stop'), {}).then(function (r) {
      if (r.status !== 200 && selected === id) { els.btnCancel.disabled = false; }
      refreshSoon();
    }).catch(function () {});
  });

  els.btnStop.addEventListener('click', function () {
    var id = selected;
    var sh = findShare(id);
    var nm = sh ? shareName(sh) : '';
    var msg = nm
      ? 'Freigabe „' + nm + '“ wirklich beenden? Der Link funktioniert danach nicht mehr.'
      : 'Freigabe wirklich beenden? Der Link funktioniert danach nicht mehr.';
    if (!window.confirm(msg)) { return; }
    els.btnStop.disabled = true;
    action(shareApi(id, 'stop'), {}).then(function (r) {
      if (r.status !== 200 && selected === id) { els.btnStop.disabled = false; }
      refreshSoon();
    }).catch(function () {});
  });

  els.btnDismiss.addEventListener('click', function () {
    var id = selected;
    if (!id || id === NEW_TAB) { return; }
    var idx = lastIds.indexOf(id);
    var target = idx > 0 ? lastIds[idx - 1] : NEW_TAB;
    els.btnDismiss.disabled = true;
    action(shareApi(id, 'dismiss'), {}).then(function (r) {
      if (r.status === 200 || r.status === 404) {
        if (selected === id) {
          selected = target;
          tabStop = target;
          storeSelection();
        }
        // Show the neighbour right away; the next poll drops the dismissed tab.
        if (lastState && Array.isArray(lastState.shares)) {
          lastState = Object.assign({}, lastState, {
            shares: lastState.shares.filter(function (s) { return s.id !== id; })
          });
          renderCurrent();
        }
        refreshSoon();
      } else {
        els.btnDismiss.disabled = false;
      }
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

  function browserCopy(url) {
    function legacy() {
      try {
        if (els.shareUrl.value !== url) { return false; }
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
    var id = selected;
    var url = els.shareUrl.value;
    showCopyError('');
    els.btnCopy.disabled = true;
    action(shareApi(id, 'copy'), {}).then(function (r) {
      if (r.status === 200) { return true; }
      if (r.status === 409 || r.status === 501) { return browserCopy(url); }
      return false;
    }).then(function (ok) {
      els.btnCopy.disabled = false;
      if (ok) { showCopied(); } else { showCopyError('Kopieren nicht möglich. Bitte den Link markieren und mit Strg+C kopieren.'); }
    }).catch(function () { els.btnCopy.disabled = false; });
  });

  els.btnQuit.addEventListener('click', function () {
    var n = runningOf(lastState);
    var msg = 'WorkspaceShare beenden?';
    if (n === 1) { msg += ' 1 laufende Freigabe wird beendet.'; }
    else if (n > 1) { msg += ' ' + n + ' laufende Freigaben werden beendet.'; }
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

  // ---------------------------------------------------------------- drag & drop (contract sections 7 and 8)
  var uploading = false;        // upload sequence (begin / files / finish) is running
  var collecting = false;       // dropped entries are being read
  var cancelRequested = false;
  var removing = false;         // discard of the active drop is running
  var dropInfo = null;          // finished draft drop: { id, path, files, totalBytes } or null
  var dropTops = null;          // top-level names of that drop (known only for uploads made in this page)
  var dropEpoch = 0;            // bumped on every local drop change; makes in-flight polls stale
  var serviceOutdated = false;  // backend without /api/drop/* (404) or without state.limits

  function dropSummaryText(info) {
    return info.files.toLocaleString('de-DE') + (info.files === 1 ? ' Datei' : ' Dateien') + ', ' + formatSize(info.totalBytes);
  }

  function dropFromState(st) {
    var d = st && st.draft && st.draft.drop;
    if (!d || typeof d.path !== 'string' || !d.path || d.finished !== true) { return null; }
    return { id: typeof d.id === 'string' ? d.id : '', path: d.path, files: num(d.files), totalBytes: num(d.totalBytes) };
  }

  // Shows (or clears) the finished drop in the folder field.
  function applyDrop(info) {
    var prev = dropInfo;
    dropInfo = info;
    if (!info || !prev || prev.id !== info.id) { dropTops = null; }
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
    updateNamePreview();
  }

  function updateBusy() {
    var busy = uploading || collecting;
    els.btnFiles.disabled = busy || serviceOutdated;
    els.btnPick.disabled = busy || picking;
    els.folder.disabled = uploading;
    els.btnDropRemove.disabled = uploading || removing;
    els.dropzone.classList.toggle('dz-disabled', busy || serviceOutdated);
    if (serviceOutdated) { els.dropzone.setAttribute('aria-disabled', 'true'); }
    if (busy || serviceOutdated) { els.dropzone.classList.remove('dz-over'); }
  }

  // The running backend is older than this page (no drop endpoints): drag & drop cannot work.
  function markOutdated() {
    if (serviceOutdated) { return; }
    serviceOutdated = true;
    updateBusy();
    showDropError(MSG_OUTDATED);
    announce(MSG_OUTDATED);
  }

  function setUploading(on) {
    uploading = on;
    setHidden(els.dropzone, on);
    setHidden(els.upload, !on);
    updateStartButton();
    updateBusy();
  }

  function showDropError(text) {
    if (!text && serviceOutdated) { text = MSG_OUTDATED; }
    setText(els.dropError, text);
    setHidden(els.dropError, !text);
  }

  function showDropStatus(text) { setText(els.dropStatus, text); }

  function canAccept() { return !uploading && !collecting && !serviceOutdated && currentView === 'form'; }

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

  // Unique top-level entry names in order of appearance.
  function topLevelNames(items) {
    var seen = Object.create(null);
    var out = [];
    items.forEach(function (it) {
      var top = String(it.path).split('/')[0];
      var k = top.toLowerCase();
      if (!seen[k]) { seen[k] = true; out.push(top); }
    });
    return out;
  }

  // ---- upload
  function httpErrorText(r) {
    // /api/drop/* answers 404 only on a backend that predates the drop endpoints.
    if (r && r.status === 404) { markOutdated(); return MSG_OUTDATED; }
    if (r && r.data && typeof r.data.error === 'string' && r.data.error) { return r.data.error; }
    switch (r && r.status) {
      case 400: return 'Ungültiger Dateiname oder ungültige Anfrage.';
      case 409: return 'Konflikt: Die Datei ist doppelt oder es läuft gerade ein anderes Hochladen.';
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
    var tops = topLevelNames(items);
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
        if (r.status === 404) { throw fail(httpErrorText(r)); }
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
      dropTops = tops;
      updateNamePreview();
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
  // The token comes from the URL hash (shortcut) and is kept in sessionStorage so that a reload
  // (F5) still works. A hash token always replaces a stored one. Never localStorage, cookie or query.
  function init() {
    if (mockMode) {
      token = 'mock';
    } else {
      var hash = location.hash || '';
      var fromHash = hash.charAt(0) === '#' ? hash.slice(1) : hash;
      if (fromHash) {
        token = fromHash;
        storageSet(TOKEN_KEY, token);
      } else {
        token = storageGet(TOKEN_KEY) || '';
      }
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
