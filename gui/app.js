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
    btnStop: $('btn-stop'), btnQuit: $('btn-quit')
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
      health: null, exitCode: null, reason: null, message: null, log: [], request: null
    };
    var timer = null;
    var failAt = 0;

    function clear() { if (timer) { window.clearInterval(timer); window.clearTimeout(timer); timer = null; } }

    function snapshot() {
      var rem = null;
      if (s.expiresUtc) { rem = Math.max(0, Math.ceil((Date.parse(s.expiresUtc) - Date.now()) / 60000)); }
      return {
        v: 1, phase: s.phase, platform: 'windows',
        capabilities: { folderPicker: true, clipboard: true, openBrowser: true },
        step: s.step, total: TOTAL_STEPS, stepText: s.step ? STEP_TEXTS[s.step - 1] : null,
        steps: s.steps.slice(), url: s.url, expiresUtc: s.expiresUtc, sizeBytes: s.sizeBytes, sha256: s.sha256,
        remainingMinutes: rem, health: s.health, exitCode: s.exitCode, reason: s.reason, message: s.message,
        log: s.log.slice(), request: s.request
      };
    }

    function beginEnd(reason, message) {
      clear();
      s.phase = 'stopping';
      timer = window.setTimeout(function () {
        s.phase = 'ended'; s.exitCode = 0; s.reason = reason; s.message = message;
        s.url = null; s.expiresUtc = null; timer = null;
      }, 1500);
    }

    function startRun(req) {
      clear();
      s.request = req;
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

    return function mockApi(method, path, body) {
      return new Promise(function (resolve) {
        window.setTimeout(function () {
          var r = { status: 200, data: {} };
          if (path === '/api/state') {
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
            r.data = { ok: true };
          } else {
            r = { status: 404, data: { error: 'Unbekannt' } };
          }
          resolve(r);
        }, 60);
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
    return fetch(path, opts).then(function (resp) {
      return resp.text().then(function (txt) {
        var data = null;
        if (txt) { try { data = JSON.parse(txt); } catch (e) { data = null; } }
        return { status: resp.status, data: data || {} };
      });
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
      render(r.data);
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

  function prefillForm(req) {
    if (formDirty || formPrefilled || !req) { return; }
    formPrefilled = true;
    if (typeof req.path === 'string') { els.folder.value = req.path; }
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

  function render(st) {
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
        els.btnStart.disabled = false;
        break;
    }
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
      els.btnPick.disabled = false;
      if (r.status === 200 && r.data && typeof r.data.path === 'string' && r.data.path) {
        els.folder.value = r.data.path;
        formDirty = true;
      } else if (r.status === 200) {
        /* cancelled: nothing */
      } else if (r.status === 501) {
        showFormError('Die Ordnerauswahl wird auf diesem System nicht unterstützt. Bitte den Pfad eintragen.');
      } else {
        showFormError(errorFromResponse(r, 'Die Ordnerauswahl ist fehlgeschlagen.'));
      }
    }).catch(function () { els.btnPick.disabled = false; });
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
