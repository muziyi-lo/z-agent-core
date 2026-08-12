const A = '/api';
let currentId = null;
let currentName = null;
let currentModel = null;
let evtSrc = null;
let isStreaming = false;

function groupSessions(list, pinnedIds, now) {
  now = now || new Date();
  var todayStart = Math.floor(new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime() / 1000);
  var yesterdayStart = Math.floor(new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1).getTime() / 1000);
  var weekStart = Math.floor(new Date(now.getFullYear(), now.getMonth(), now.getDate() - 7).getTime() / 1000);
  var pinned = [], today = [], yesterday = [], week = [], older = [];
  (list || []).forEach(function(s) {
    var isPinned = pinnedIds && pinnedIds.indexOf(s.id) !== -1;
    if (isPinned) { pinned.push(s); return; }
    if (s.timestamp >= todayStart) today.push(s);
    else if (s.timestamp >= yesterdayStart) yesterday.push(s);
    else if (s.timestamp >= weekStart) week.push(s);
    else older.push(s);
  });
  return { pinned: pinned, today: today, yesterday: yesterday, week: week, older: older };
}

function getPinnedIds() {
  try {
    var raw = localStorage.getItem('zagent-pinned');
    var arr = raw ? JSON.parse(raw) : [];
    return Array.isArray(arr) ? arr : [];
  } catch(e) { return []; }
}
function savePinnedIds(ids) {
  localStorage.setItem('zagent-pinned', JSON.stringify(ids));
}
function togglePin(id) {
  var ids = getPinnedIds();
  var i = ids.indexOf(id);
  if (i === -1) ids.push(id); else ids.splice(i, 1);
  savePinnedIds(ids);
  return i === -1; // true if now pinned
}
function closeAllMoreMenus() {
  document.querySelectorAll('.more-menu.open').forEach(function(m) { m.classList.remove('open'); });
}
document.addEventListener('click', function(e) {
  if (!e.target.closest('.more-menu, .more-btn')) closeAllMoreMenus();
});
document.addEventListener('click', function(e) {
  var copyBtn = e.target.closest('.code-copy');
  if (!copyBtn) return;
  var block = copyBtn.closest('.code-block');
  if (!block) return;
  var code = block.querySelector('pre code');
  if (!code) return;
  copyText(code.textContent, copyBtn, 'Copied!');
});

function renderModelMenu(models, currentId) {
  return (models || []).map(function(m) {
    return { id: m.id, name: m.name, active: m.id === currentId };
  });
}

function moreMenuAction(action, sessionId) {
  return { action: action, sessionId: sessionId };
}

function decorateCodeBlocks(html) {
  if (!html) return html;
  var re = /<pre><code class="language-([^"]+)">/g;
  return html.replace(re, function(m, lang) {
    return '<div class="code-block"><div class="code-banner"><span class="code-lang">' + lang + '</span><button class="code-copy" title="Copy">'
      + '<svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" fill="currentColor" viewBox="0 0 16 16"><path fill-rule="evenodd" d="M4 2a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2zm2-1a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1V2a1 1 0 0 0-1-1zM2 5a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1v-1h1v1a2 2 0 0 1-2 2H2a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h1v1z"/></svg>'
      + '</button></div><pre><code class="language-' + lang + '">';
  }).replace(/<\/code><\/pre>/g, '</code></pre></div>');
}

function setStreaming(streaming) {
  var btn = document.getElementById('send-btn');
  var inp = document.getElementById('prompt-input');
  var msgs = document.getElementById('messages');
  if (btn) btn.classList.toggle('stop', streaming);
  if (inp) inp.disabled = streaming;
  // Disable message action buttons visually while streaming (clicks are also
  // guarded by `isStreaming` in each handler).
  if (msgs) msgs.classList.toggle('streaming', streaming);
  return btn;
}

function setTopbarTitle(name) {
  var el = document.getElementById('topbar-title');
  if (el) el.textContent = name;
}

function biIcon(name, size) {
  var paths = {
    'revert': '<path fill-rule="evenodd" d="M8 3a5 5 0 1 1-4.546 2.914.5.5 0 0 0-.908-.417A6 6 0 1 0 8 2z"/><path d="M8 4.466V.534a.25.25 0 0 0-.41-.192L5.23 2.308a.25.25 0 0 0 0 .384l2.36 1.966A.25.25 0 0 0 8 4.466"/>',
    'copy': '<path fill-rule="evenodd" d="M4 2a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2zm2-1a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1V2a1 1 0 0 0-1-1zM2 5a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1v-1h1v1a2 2 0 0 1-2 2H2a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h1v1z"/>',
    'trash': '<path d="M5.5 5.5A.5.5 0 0 1 6 6v6a.5.5 0 0 1-1 0V6a.5.5 0 0 1 .5-.5m2.5 0a.5.5 0 0 1 .5.5v6a.5.5 0 0 1-1 0V6a.5.5 0 0 1 .5-.5m3 .5a.5.5 0 0 0-1 0v6a.5.5 0 0 0 1 0z"/><path d="M14.5 3a1 1 0 0 1-1 1H13v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V4h-.5a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1H6a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1h3.5a1 1 0 0 1 1 1zM4.118 4 4 4.059V13a1 1 0 0 0 1 1h6a1 1 0 0 0 1-1V4.059L11.882 4zM2.5 3h11V2h-11z"/>',
    'branch': '<path d="M9.585 2.568a2.5 2.5 0 1 1 2.83 2.83 3.5 3.5 0 0 1-2.83 2.83v3.25a3.5 3.5 0 1 1-2 0V8.228a3.5 3.5 0 0 1-2.83-2.83 2.5 2.5 0 1 1 2.83 2.83v.042a2.5 2.5 0 0 0 2 0V8.228a3.5 3.5 0 0 1 2.83-2.83v-.003a2.5 2.5 0 0 0-2.83-2.827zM6 1.5a1 1 0 1 0 0 2 1 1 0 0 0 0-2zm6 3a1 1 0 1 0 0 2 1 1 0 0 0 0-2zm-6 8a1 1 0 1 0 0 2 1 1 0 0 0 0-2z"/>'
  };
  var p = paths[name] || '';
  var s = size || 14;
  return '<svg xmlns="http://www.w3.org/2000/svg" width="' + s + '" height="' + s + '" fill="currentColor" viewBox="0 0 16 16">' + p + '</svg>';
}

// --- sidebar toggle ---
document.getElementById('sidebar-toggle').onclick = function() {
  if (window.matchMedia('(max-width: 768px)').matches) {
    document.body.classList.remove('sidebar-collapsed');
    document.getElementById('sidebar').classList.toggle('open');
  } else {
    var collapsed = document.body.classList.toggle('sidebar-collapsed');
    localStorage.setItem('zagent-sidebar-collapsed', collapsed ? '1' : '0');
    this.setAttribute('aria-pressed', collapsed ? 'true' : 'false');
  }
};
if (localStorage.getItem('zagent-sidebar-collapsed') === '1') {
  document.body.classList.add('sidebar-collapsed');
  document.getElementById('sidebar-toggle').setAttribute('aria-pressed', 'true');
}

// --- theme toggle ---
var themeBtn = document.getElementById('theme-btn');
themeBtn.onclick = function() {
  var cur = document.documentElement.getAttribute('data-theme');
  var next = cur === 'light' ? 'dark' : 'light';
  document.documentElement.setAttribute('data-theme', next);
  themeBtn.innerHTML = next === 'light' ? '&#9790;' : '&#9728;';
  localStorage.setItem('zagent-theme', next);
};
(function() {
  var saved = localStorage.getItem('zagent-theme') || 'dark';
  document.documentElement.setAttribute('data-theme', saved);
  themeBtn.innerHTML = saved === 'light' ? '&#9790;' : '&#9728;';
})();

// --- undo last session operation (delete/truncate/branch) ---
document.getElementById('undo-btn').onclick = async function() {
  if (!currentId || isStreaming) return;
  try {
    await api('/session/' + currentId + '/undo', { method: 'POST' });
    await loadSession(currentId);
    showStatus('undone', false);
  } catch(err) { showStatus('undo failed', true); }
};

// --- auto-scroll helper (opencode-style follow state machine) ---
var autoScrollPaused = false;
var autoScrollMark = { top: -1, time: 0 };
var autoScrollMarkTimer = null;
var SCROLL_THRESHOLD = 10;
var SCROLL_MARK_MS = 1500;

function isNearBottom(el) {
  return el.scrollHeight - el.scrollTop - el.clientHeight < SCROLL_THRESHOLD;
}
function scrollToBottom(el, force) {
  if (autoScrollPaused && !force) return;
  var top = Math.max(0, el.scrollHeight - el.clientHeight);
  autoScrollMark = { top: top, time: Date.now() };
  if (autoScrollMarkTimer) clearTimeout(autoScrollMarkTimer);
  autoScrollMarkTimer = setTimeout(function() { autoScrollMark.time = 0; }, SCROLL_MARK_MS);
  el.scrollTop = el.scrollHeight;
}
// User-driven scroll listener: leaving the bottom pauses following, returning
// resumes. Programmatic scrolls are masked by the mark window; nested scrollable
// regions (tool output / code blocks) are exempt.
document.getElementById('messages').addEventListener('scroll', function(e) {
  var el = document.getElementById('messages');
  var t = e.target;
  if (t && t !== el && t.closest && t.closest('[data-scrollable]')) return;
  if (Date.now() - autoScrollMark.time < SCROLL_MARK_MS && Math.abs(el.scrollTop - autoScrollMark.top) < 2) return;
  if (isNearBottom(el)) {
    autoScrollPaused = false;
  } else {
    autoScrollPaused = true;
  }
  if (el.scrollTop < 60 && currentHasMore && !historyLoading && !isStreaming) loadOlder();
}, true);
function confirmModal(msg) {
  return new Promise(function(resolve) {
    document.getElementById('confirm-msg').textContent = msg;
    var overlay = document.getElementById('confirm-modal');
    overlay.classList.add('open');
    var done = false;
    function close(r) { if (done) return; done = true; overlay.classList.remove('open'); resolve(r); }
    document.getElementById('confirm-ok').onclick = function() { close(true); };
    overlay.querySelector('.modal-cancel').onclick = function() { close(false); };
    overlay.onclick = function(e) { if (e.target === overlay) close(false); };
    function escHandler(e) { if (e.key === 'Escape') { close(false); document.removeEventListener('keydown', escHandler); } }
    document.addEventListener('keydown', escHandler, {once:true});
  });
}

// --- api helper ---
async function api(path, opts) {
  var r = await fetch(A + path, opts);
  if (!r.ok) {
    var text = await r.text();
    console.error('API error', path, r.status, text.substring(0, 200));
    throw new Error(text);
  }
  var text = await r.text();
  try { return JSON.parse(text); } catch(e) {
    console.error('JSON parse error', path, text.substring(0, 200));
    throw e;
  }
}

// --- sidebar resize ---
(function(){
  var sidebar = document.getElementById('sidebar');
  var handle = document.getElementById('resize-handle');
  if (!handle) return;
  var resizing = false;
  handle.onmousedown = function(e) { resizing = true; handle.classList.add('active'); e.preventDefault(); };
  document.addEventListener('mousemove', function(e) {
    if (!resizing) return;
    var w = e.clientX;
    if (w < 180) w = 180;
    if (w > 480) w = 480;
    sidebar.style.width = w + 'px';
  });
  document.addEventListener('mouseup', function() { resizing = false; handle.classList.remove('active'); });
})();

// --- model selector ---
function selectModel(id) {
  currentModel = id || '';
  if (currentModel) localStorage.setItem('zagent-model', currentModel);
  var hasMsgs = document.querySelectorAll('#messages .msg:not(#system-prompt), #messages .tool-card').length > 0;
  if (hasMsgs) {
    var tip = document.createElement('div');
    tip.className = 'status-msg';
    tip.textContent = 'Model switch applies to new sessions only';
    document.getElementById('messages').insertBefore(tip, document.getElementById('messages').firstChild);
    setTimeout(function() { if (tip.parentNode) tip.parentNode.removeChild(tip); }, 3000);
  }
}
function renderModelMenuHtml(items) {
  return items.map(function(it) {
    return '<div class="model-item' + (it.active ? ' active' : '') + '" data-id="' + esc(it.id) + '" title="' + esc(it.id) + '">' + esc(it.name) + (it.active ? ' &#10003;' : '') + '</div>';
  }).join('');
}
async function loadModels() {
  var nameEl = document.getElementById('model-btn-name');
  try {
    var models = await api('/model');
    if (!models || models.length === 0) throw new Error('empty');
    var saved = localStorage.getItem('zagent-model');
    var cur = (saved && models.some(function(m) { return m.id === saved; })) ? saved : models[0].id;
    currentModel = cur;
    var curName = models.filter(function(m) { return m.id === cur; })[0].name;
    if (nameEl) nameEl.textContent = curName;
    return renderModelMenu(models, cur);
  } catch(e) {
    var saved = localStorage.getItem('zagent-model');
    if (saved) { currentModel = saved; if (nameEl) nameEl.textContent = saved; }
    else { currentModel = ''; if (nameEl) nameEl.textContent = 'Default'; }
    return [];
  }
}
document.getElementById('model-btn').onclick = function(e) {
  e.stopPropagation();
  closeAllMoreMenus();
  var menu = document.getElementById('model-menu');
  var btn = this;
  var expanded = btn.getAttribute('aria-expanded') === 'true';
  if (menu && expanded) { menu.remove(); btn.setAttribute('aria-expanded','false'); return; }
  if (menu) menu.remove();
  var models;
  loadModels().then(function(items) {
    menu = document.createElement('div');
    menu.className = 'model-menu';
    menu.id = 'model-menu';
    menu.innerHTML = renderModelMenuHtml(items);
    menu.querySelectorAll('.model-item').forEach(function(item) {
      item.onclick = function(e2) {
        e2.stopPropagation();
        selectModel(item.getAttribute('data-id'));
        document.getElementById('model-btn-name').textContent = item.querySelector ? item.textContent.replace(/[ \u2713]/g,'').trim() : item.getAttribute('data-id');
        menu.remove();
        btn.setAttribute('aria-expanded','false');
      };
    });
    document.body.appendChild(menu);
    var r = btn.getBoundingClientRect();
    menu.style.top = (r.bottom + 4) + 'px';
    menu.style.right = (window.innerWidth - r.right) + 'px';
    btn.setAttribute('aria-expanded','true');
  });
};
document.addEventListener('click', function(e) {
  if (!e.target.closest('#model-btn, #model-menu')) {
    var menu = document.getElementById('model-menu');
    if (menu) { menu.remove(); var b = document.getElementById('model-btn'); if (b) b.setAttribute('aria-expanded','false'); }
  }
});

// --- session list (branch tree: top-level grouped by time, children under parent) ---
async function loadSessions() {
  var list; try { list = await api('/session'); } catch(e) { console.error('loadSessions error', e); return; }
  var el = document.getElementById('session-list');
  el.innerHTML = '';
  if (list.length === 0) {
    el.innerHTML = '<div class="empty-hint">No sessions yet</div>';
    return;
  }

  var pinnedIds = getPinnedIds();
  // Branch tree: sessions with parent_id render under their parent (depth-based
  // indent); orphans whose parent no longer exists are promoted to top-level so
  // they never become unreachable.
  var knownIds = {};
  list.forEach(function(s) { knownIds[s.id] = true; });
  var childrenMap = {};
  var topLevel = [];
  list.forEach(function(s) {
    if (s.parent_id && knownIds[s.parent_id]) {
      (childrenMap[s.parent_id] = childrenMap[s.parent_id] || []).push(s);
    } else {
      topLevel.push(s);
    }
  });
  Object.keys(childrenMap).forEach(function(k) {
    childrenMap[k].sort(function(a, b) { return b.timestamp - a.timestamp; });
  });
  var groups = groupSessions(topLevel, pinnedIds);

  function renderItem(s, depth) {
    var isChild = depth > 0;
    var isPinned = pinnedIds && pinnedIds.indexOf(s.id) !== -1;
    var div = document.createElement('div');
    div.className = 'session' + (isChild ? ' child' : '') + (s.id === currentId ? ' active' : '');
    // Depth-based indent so multi-generation branches stay visually distinct.
    if (isChild) div.style.paddingLeft = (28 + (depth - 1) * 14) + 'px';
    div.innerHTML = (isChild ? '<span class="branch-icon" title="Branch">' + biIcon('branch', 11) + '</span>' : '')
      + '<div class="name">' + esc(s.name) + '</div><div class="meta">' + esc(s.model) + ' &middot; ' + s.msg_count + ' msgs</div>'
      + '<button class="pin-btn' + (isPinned ? ' pinned' : '') + '" title="' + (isPinned ? 'Unpin' : 'Pin') + '">&#128204;</button>'
      + '<button class="more-btn" title="More actions">&#8942;</button>'
      + '<span class="delete-btn">&times;</span>'
      + '<div class="more-menu"><div class="more-item" data-act="rename">Rename</div><div class="more-item" data-act="pin">' + (isPinned ? 'Unpin' : 'Pin') + '</div><div class="more-item danger" data-act="delete">Delete</div></div>';

    div.querySelector('.pin-btn').onclick = function(e) {
      e.stopPropagation();
      togglePin(s.id);
      loadSessions();
    };
    div.querySelector('.delete-btn').onclick = function(e) { e.stopPropagation(); deleteSession(s.id); };

    var moreBtn = div.querySelector('.more-btn');
    var moreMenu = div.querySelector('.more-menu');
    moreBtn.onclick = function(e) {
      e.stopPropagation();
      closeAllMoreMenus();
      moreMenu.classList.toggle('open');
    };
    moreMenu.querySelectorAll('.more-item').forEach(function(item) {
      item.onclick = function(e) {
        e.stopPropagation();
        moreMenu.classList.remove('open');
        var act = item.getAttribute('data-act');
        if (act === 'rename') { nameSpan.dispatchEvent(new MouseEvent('dblclick')); }
        else if (act === 'pin') { togglePin(s.id); loadSessions(); }
        else if (act === 'delete') { deleteSession(s.id); }
      };
    });

    var nameSpan = div.querySelector('.name');
    nameSpan.ondblclick = function() {
      var input = document.createElement('input');
      input.value = nameSpan.textContent;
      input.className = 'rename-input';
      var finish = async function() {
        var newName = input.value.trim();
        nameSpan.style.display = '';
        input.remove();
        if (newName && newName !== nameSpan.textContent) {
          try {
            await fetch(A + '/session/' + s.id, { method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: newName }) });
            if (currentId === s.id) { currentName = newName; setTopbarTitle(newName); }
            await loadSessions();
          } catch(err) { console.error(err); }
        }
      };
      input.onblur = finish;
      input.onkeydown = function(e) { if (e.key === 'Enter') finish(); };
      nameSpan.style.display = 'none';
      nameSpan.parentNode.insertBefore(input, nameSpan.nextSibling);
      input.focus();
      input.select();
    };

    div.onclick = function() { loadSession(s.id); };
    return div;
  }

  function renderChildren(parentId, depth) {
    var kids = childrenMap[parentId];
    if (!kids) return;
    kids.forEach(function(k) {
      el.appendChild(renderItem(k, depth));
      if (depth < 6) renderChildren(k.id, depth + 1);
    });
  }

  function renderGroup(label, items) {
    if (items.length === 0) return;
    var hdr = document.createElement('div');
    hdr.className = 'section-header';
    hdr.textContent = label;
    el.appendChild(hdr);
    items.forEach(function(s) {
      el.appendChild(renderItem(s, 0));
      renderChildren(s.id, 1);
    });
  }

  renderGroup('Pinned', groups.pinned);
  var labels = { today: 'Today', yesterday: 'Yesterday', week: 'This Week', older: 'Older' };
  for (var i = 0; i < ['today','yesterday','week','older'].length; i++) {
    var key = ['today','yesterday','week','older'][i];
    renderGroup(labels[key], groups[key]);
  }
}

async function loadSession(id) {
  var sess;
  try { sess = await api('/session/' + id + '?limit=50'); }
  catch(e) { console.error('loadSession error', e); return; }
  currentId = id;
  currentName = sess.name;
  setTopbarTitle(sess.name);
  setStreaming(false);
  var msgs = document.getElementById('messages');
  // Preserve scroll position across reloads when the user is reading history
  // (autoScrollPaused); otherwise the reload lands at the bottom.
  var keepScroll = autoScrollPaused;
  var prevScrollTop = msgs.scrollTop;
  var prevScrollHeight = msgs.scrollHeight;
  msgs.innerHTML = '';
  renderSystemPrompt(sess.system || null);
  renderMessages(sess.messages || [], null);
  currentHasMore = !!sess.has_more;
  currentOldestId = (sess.messages && sess.messages.length > 0) ? sess.messages[0].id : null;
  if (keepScroll && prevScrollHeight > 0) {
    msgs.scrollTop = Math.round(prevScrollTop / prevScrollHeight * msgs.scrollHeight);
  } else {
    autoScrollPaused = false;
    scrollToBottom(msgs, true);
  }
  await loadSessions();
}

// --- message-list pagination (load newest first, scroll up for older pages) ---
var currentHasMore = false;
var currentOldestId = null;
var historyLoading = false;

// Render a message list. `insertBeforeNode` non-null prepends (older page);
// otherwise messages are appended in order (initial load). Tool results are
// matched into the preceding assistant's tool segments (never split across a
// page boundary by the server).
function renderMessages(msgs, insertBeforeNode) {
  var container = document.getElementById('messages');
  var lastAsst = null;
  msgs.forEach(function(m) {
    if (m.role === 'tool') {
      if (lastAsst && lastAsst._toolSegments) {
        var outHtml = renderMd(m.content || '');
        for (var k = 0; k < lastAsst._toolSegments.length; k++) {
          var ts = lastAsst._toolSegments[k];
          if (ts.callId === m.tool_call_id) {
            ts.output = m.content || '';
            var out = ts.el.querySelector('.output');
            if (out) out.innerHTML = outHtml;
            break;
          }
        }
      }
      return;
    }
    var div = addMessage(m, 0, null, true);
    if (insertBeforeNode) container.insertBefore(div, insertBeforeNode);
    if (m.role === 'assistant') wrapContextToolGroups(div);
    lastAsst = div;
  });
}

// The first rendered message element (skips the #system-prompt banner).
function firstMessageEl() {
  var msgs = document.getElementById('messages');
  for (var i = 0; i < msgs.children.length; i++) {
    var c = msgs.children[i];
    if (c.id !== 'system-prompt' && c.className.indexOf('msg') === 0) return c;
  }
  return null;
}

async function loadOlder() {
  var msgs = document.getElementById('messages');
  if (!currentId || historyLoading || !currentHasMore || isStreaming) return;
  historyLoading = true;
  try {
    var d = await api('/session/' + currentId + '/message?before=' + currentOldestId + '&limit=50');
    if (!d || !d.messages || d.messages.length === 0) { currentHasMore = false; return; }
    // Anchor preservation: prepending shifts content down, restore the viewport.
    var prevH = msgs.scrollHeight;
    var prevT = msgs.scrollTop;
    renderMessages(d.messages, firstMessageEl());
    msgs.scrollTop = prevT + (msgs.scrollHeight - prevH);
    currentOldestId = d.messages[0].id;
    currentHasMore = !!d.has_more;
  } catch(e) { console.error('loadOlder error', e); }
  finally { historyLoading = false; }
}

function renderSystemPrompt(content) {
  var el = document.getElementById('system-prompt');
  if (!el) {
    el = document.createElement('div');
    el.id = 'system-prompt';
    var msgs = document.getElementById('messages');
    msgs.insertBefore(el, msgs.firstChild);
  }
  if (!content) { el.style.display = 'none'; return; }
  el.className = 'msg system';
  el.innerHTML = renderSystemBlocks(content);
  el.style.display = '';
}

// Render the system prompt block-wise. The prompt is not pure markdown:
// <env>, <project_context> and <available_skills> are structured blocks that
// marked would strip or mangle (unknown HTML tags, newline collapsing). Each
// block is rendered as a <pre class="sys-block"> to preserve the original
// whitespace and keep the module boundaries visually distinct. Text outside
// the blocks (the identity line) is rendered as markdown.
// Blocks are split by their semantic tags; text before each tag is rendered
// as markdown separately so tag lines and their content stay together.
function renderSystemBlocks(content) {
  var out = [];
  var i = 0;
  var n = content.length;
  while (i < n) {
    var lt = content.indexOf('<', i);
    if (lt < 0) {
      var tail = content.slice(i).trim();
      if (tail) out.push(renderMd(tail));
      break;
    }
    // text before the tag, if any
    var before = content.slice(i, lt).trim();
    if (before) out.push(renderMd(before));
    var gt = content.indexOf('>', lt);
    if (gt < 0) { break; }
    var tag = content.slice(lt, gt + 1);
    if (tag === '<env>') {
      var end = content.indexOf('</env>', gt);
      if (end < 0) { out.push(renderMd(content.slice(lt))); break; }
      var block = content.slice(lt, end + '</env>'.length);
      out.push('<pre class="sys-block">' + esc(block) + '</pre>');
      i = end + '</env>'.length;
    } else if (tag === '<available_skills>') {
      var end2 = content.indexOf('</available_skills>', gt);
      if (end2 < 0) { out.push(renderMd(content.slice(lt))); break; }
      var block2 = content.slice(lt, end2 + '</available_skills>'.length);
      out.push('<pre class="sys-block">' + esc(block2) + '</pre>');
      i = end2 + '</available_skills>'.length;
    } else if (tag === '<project_context>') {
      var end3 = content.indexOf('</project_context>', gt);
      if (end3 < 0) { out.push(renderMd(content.slice(lt))); break; }
      var block3 = content.slice(lt, end3 + '</project_context>'.length);
      out.push('<pre class="sys-block">' + esc(block3) + '</pre>');
      i = end3 + '</project_context>'.length;
    } else {
      // not a recognized wrapper tag — emit up to the next '<' as markdown
      var nextLt = content.indexOf('<', gt + 1);
      var seg = (nextLt < 0 ? content.slice(lt) : content.slice(lt, nextLt)).trim();
      if (seg) out.push(renderMd(seg));
      i = (nextLt < 0 ? n : nextLt);
    }
  }
  return out.join('\n');
}

function renderMd(content) {
  try {
    // LRU cache lookup
    for (var i = 0; i < renderMd._cache.length; i++) {
      if (renderMd._cache[i].key === content) {
        var entry = renderMd._cache.splice(i, 1)[0];
        renderMd._cache.unshift(entry);
        return entry.value;
      }
    }
    var raw = marked.parse(content || '');
    var clean = DOMPurify.sanitize(raw);
    clean = decorateCodeBlocks(clean);
    renderMd._cache.unshift({key: content, value: clean});
    if (renderMd._cache.length > 200) renderMd._cache.pop();
    return clean;
  } catch(e) { return esc(content || '').replace(/\n/g, '<br>'); }
}
renderMd._cache = [];

// --- block-level markdown (data-markdown-key + hash) ---
function hashStr(s) {
  var h = 0;
  for (var i = 0; i < s.length; i++) { h = ((h << 5) - h + s.charCodeAt(i)) | 0; }
  return (h >>> 0).toString(16);
}

function renderMdBlocks(content) {
  try {
    var raw = marked.parse(content || '');
    var clean = DOMPurify.sanitize(raw, { RETURN_DOM_FRAGMENT: true });
    var parts = [];
    var idx = 0;
    for (var i = 0; i < clean.children.length; i++) {
      var child = clean.children[i];
      var html = child.outerHTML || child.textContent;
      var h = hashStr(html);
      parts.push('<div data-markdown-key="b' + idx + '" data-markdown-hash="' + h + '">' + html + '</div>');
      idx++;
    }
    return parts.join('');
  } catch(e) { return renderMd(content); }
}

function updateMarkdownBlocks(container, content) {
  var newHtml = renderMdBlocks(content);
  var existing = container.querySelectorAll('[data-markdown-key]');
  if (existing.length === 0) {
    container.innerHTML = newHtml;
    return;
  }
  var tmp = document.createElement('div');
  tmp.innerHTML = newHtml;
  var newBlocks = tmp.querySelectorAll('[data-markdown-key]');
  newBlocks.forEach(function(nb) {
    var key = nb.dataset.markdownKey;
    var el = container.querySelector('[data-markdown-key="' + key + '"]');
    if (el && el.dataset.markdownHash === nb.dataset.markdownHash) return;
    if (el) { el.outerHTML = nb.outerHTML; }
    else { container.appendChild(nb.cloneNode(true)); }
  });
  // remove stale blocks (keys not in new set)
  var newKeys = {};
  newBlocks.forEach(function(nb) { newKeys[nb.dataset.markdownKey] = true; });
  existing.forEach(function(el) {
    if (!newKeys[el.dataset.markdownKey]) el.remove();
  });
}

function buildSegment(seg) {
  var el;
  if (seg.type === 'reasoning') {
    el = document.createElement('div');
    el.className = 'thinking-block' + (seg.open ? ' open' : '');
    el.innerHTML = '<div class="header">&#9654; Thinking</div>';
    var content = document.createElement('div');
    content.className = 'content';
    content.innerHTML = renderMd(seg.text || '');
    el.appendChild(content);
    el.onclick = function() { el.classList.toggle('open'); };
    return el;
  }
  if (seg.type === 'text') {
    el = document.createElement('div');
    el.className = 'content-block';
    var content = document.createElement('div');
    content.className = 'content';
    content.innerHTML = renderMd(seg.text || '');
    el.appendChild(content);
    return el;
  }
  if (seg.type === 'tool') {
    el = document.createElement('div');
    el.className = 'tool-card open';
    el._toolName = seg.name;
    el.innerHTML = '<div class="name-row"><span class="toggle-icon">&#9660;</span> <span class="tool-label">&#9881;</span> <span class="name">' + esc(seg.name || 'tool') + '</span></div>';
    var output = document.createElement('div');
    output.className = 'output';
    output.innerHTML = renderMd(seg.output || '');
    el.appendChild(output);
    el.onclick = function(e) {
      if (e.target.closest('.output')) return;
      el.classList.toggle('open');
    };
    return el;
  }
  return document.createElement('div');
}

function renderAssistantMessage(container, msg) {
  container.innerHTML = '';
  (msg.segments || []).forEach(function(seg) {
    seg.el = buildSegment(seg);
    container.appendChild(seg.el);
  });
}

function addMessage(m, index, toolName, noScroll) {
  var msgs = document.getElementById('messages');
  var role = m.role;
  var content = m.content || '';
  var div = document.createElement('div');
  div._msgId = m.id || 0;

  div.className = 'msg ' + role;

  if (role === 'assistant') {
    var segs = [];
    if (m.reasoning_content) segs.push({ type: 'reasoning', text: m.reasoning_content, complete: true, open: true });
    if (m.content) segs.push({ type: 'text', text: m.content });
    if (m.tool_calls) {
      m.tool_calls.forEach(function(tc) {
        segs.push({ type: 'tool', name: tc.name, args: tc.arguments || '', status: 'done', output: '', callId: tc.id });
      });
    }
    renderAssistantMessage(div, { segments: segs });
    div._toolSegments = segs.filter(function(s) { return s.type === 'tool'; });
    // message meta
    if (m.timestamp || m.model) {
      var metaParts = [];
      if (m.model) metaParts.push(esc(m.model));
      if (m.timestamp) {
        var d = new Date(m.timestamp * 1000);
        metaParts.push(d.toLocaleString());
      }
      var meta = document.createElement('div');
      meta.className = 'msg-meta';
      meta.innerHTML = metaParts.join(' &middot; ');
      div.appendChild(meta);
    }
    // add click handler for thinking blocks
    setTimeout(function() {
      var tbs = div.querySelectorAll('.thinking-block');
      for (var i = 0; i < tbs.length; i++) tbs[i].onclick = function() { tbs[i].classList.toggle('open'); };
    }, 0);
    // code block copy buttons + syntax highlight
    setTimeout(function() {
      var pres = div.querySelectorAll('pre');
      for (var i = 0; i < pres.length; i++) addCopyButton(pres[i]);
      if (typeof hljs !== 'undefined') hljs.highlightAll();
    }, 0);
  } else {
    div.style.whiteSpace = 'pre-wrap';
    div.textContent = content || '';
  }

  // delete button (not for system message, not for user — user has actions bar)
  if (div._msgId && role !== 'user') {
    var delBtn = document.createElement('span');
    delBtn.className = 'msg-delete';
    delBtn.textContent = '\u00d7';
    delBtn.title = 'Delete this message';
    delBtn.onclick = async function(e) {
      e.stopPropagation();
      if (isStreaming) return;
      if (!(await confirmModal('Delete this message?'))) return;
      try {
        await api('/session/' + currentId + '/message/' + div._msgId, { method: 'DELETE' });
        div.remove();
        await loadSession(currentId);
      } catch(err) { showStatus('delete failed', true); }
    };
    div.appendChild(delBtn);
  }

  // action buttons for user messages
  if (role === 'user') {
    var actions = document.createElement('div');
    actions.className = 'msg-actions';
    var revertBtn = document.createElement('button');
    revertBtn.className = 'msg-action';
    revertBtn.title = 'Revert & regenerate';
    revertBtn.innerHTML = biIcon('revert');
    revertBtn.onclick = async function(e) {
      e.stopPropagation();
      if (isStreaming || !div._msgId) return;
      try {
        await api('/session/' + currentId + '/truncate', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ message_id: div._msgId }) });
        document.getElementById('prompt-input').value = content;
        document.getElementById('prompt-input').focus();
        await loadSession(currentId);
      } catch(err) { showStatus('revert failed', true); }
    };
    actions.appendChild(revertBtn);
    var copyBtn = document.createElement('button');
    copyBtn.className = 'msg-action';
    copyBtn.title = 'Copy';
    copyBtn.innerHTML = biIcon('copy');
    copyBtn.onclick = function(e) {
      e.stopPropagation();
      copyText(content, copyBtn, 'copied!');
    };
    actions.appendChild(copyBtn);
    var branchBtn = document.createElement('button');
    branchBtn.className = 'msg-action';
    branchBtn.title = 'Branch from here';
    branchBtn.innerHTML = biIcon('branch');
    branchBtn.onclick = async function(e) {
      e.stopPropagation();
      if (isStreaming || !div._msgId) return;
      try {
        var r = await api('/session/' + currentId + '/branch', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ message_id: div._msgId }) });
        if (!(r.data && r.data.session_id)) { showStatus('branch failed', true); return; }
        if (evtSrc) { evtSrc.close(); evtSrc = null; }
        currentId = r.data.session_id;
        currentName = r.data.name;
        setTopbarTitle(r.data.name || 'z-agent-core');
        await loadSession(r.data.session_id);
        // 方案 B: fork 不含边界消息，重发它作为新 prompt → 立即生成新答案
        if (r.data.boundary_content) sendPrompt(r.data.boundary_content);
      } catch(err) { showStatus('branch failed', true); }
    };
    actions.appendChild(branchBtn);
    var delActionBtn = document.createElement('button');
    delActionBtn.className = 'msg-action danger';
    delActionBtn.title = 'Delete message';
    delActionBtn.innerHTML = biIcon('trash');
    delActionBtn.onclick = async function(e) {
      e.stopPropagation();
      if (isStreaming || !div._msgId) return;
      if (!(await confirmModal('Delete this message?'))) return;
      try {
        await api('/session/' + currentId + '/message/' + div._msgId, { method: 'DELETE' });
        div.remove();
        await loadSession(currentId);
      } catch(err) { showStatus('delete failed', true); }
    };
    actions.appendChild(delActionBtn);
    div.appendChild(actions);
  }

  msgs.appendChild(div);
  if (!noScroll) scrollToBottom(msgs);
  return div;
}

// --- SSE streaming ---
function sendPrompt(prompt) {
  if (!currentId) {
    currentId = genUuidV4();
  }
  setStreaming(true);
  isStreaming = true;

  var msgs = document.getElementById('messages');
  var userMsg = addMessage({role:'user', content:prompt}, 0);

  var asst = document.createElement('div');
  asst.className = 'msg assistant';
  asst.innerHTML = '<span class="spinner"></span>';
  msgs.appendChild(asst);
  scrollToBottom(msgs, true);

  var curSegments = [];
  var currentThinking = null;
  var currentTool = null;
  var usageData = null;
  var modelName = '';

  function ensureTextSegment() {
    var last = curSegments[curSegments.length - 1];
    if (last && last.type === 'text') return last;
    var seg = { type: 'text', text: '', el: null };
    curSegments.push(seg);
    seg.el = buildSegment(seg);
    asst.appendChild(seg.el);
    return seg;
  }

  if (evtSrc) evtSrc.close();
  var url = A + '/session/' + currentId + '/prompt?prompt=' + encodeURIComponent(prompt) + (currentModel ? '&model=' + encodeURIComponent(currentModel) : '');
  evtSrc = new EventSource(url);

  evtSrc.addEventListener('thinking_start', function() {
    var seg = { type: 'reasoning', text: '', complete: false, el: null };
    curSegments.push(seg);
    seg.el = buildSegment(seg);
    seg.el.querySelector('.header').innerHTML = '&#9654; Thinking <span class="spinner"></span>';
    asst.appendChild(seg.el);
    currentThinking = seg;
    scrollToBottom(msgs);
  });

  evtSrc.addEventListener('thinking_delta', function(e) {
    if (!currentThinking) return;
    var d = JSON.parse(e.data);
    currentThinking.text += d.text || '';
    currentThinking.el.querySelector('.content').textContent = currentThinking.text;
    scrollToBottom(msgs);
  });

  evtSrc.addEventListener('thinking_end', function(e) {
    if (currentThinking) {
      var d = JSON.parse(e.data);
      var dur = d.duration_ms ? (d.duration_ms / 1000).toFixed(0) + 's' : '';
      currentThinking.el.querySelector('.header').innerHTML = '&#9654; Thinking (' + dur + ')';
      currentThinking.el.querySelector('.content').innerHTML = renderMd(currentThinking.text);
      currentThinking.complete = true;
      currentThinking = null;
    }
  });

  evtSrc.addEventListener('session_ready', function(e) {
    var d;
    try { d = JSON.parse(e.data); } catch(ex) { return; }
    if (d.id) {
      currentId = d.id;
      if (d.name) { currentName = d.name; setTopbarTitle(d.name); }
    }
    if (d.message_id && userMsg) {
      userMsg._msgId = d.message_id;
    }
  });

  evtSrc.addEventListener('content_start', function() {
    ensureTextSegment();
  });

  evtSrc.addEventListener('content_delta', function(e) {
    var d = JSON.parse(e.data);
    var seg = ensureTextSegment();
    seg.text += d.text || '';
    seg.el.querySelector('.content').textContent = seg.text;
    scrollToBottom(msgs);
  });

  evtSrc.addEventListener('tool_start', function(e) {
    var d = JSON.parse(e.data);
    var seg = { type: 'tool', name: d.name, args: '', status: 'running', output: '', el: null };
    curSegments.push(seg);
    seg.el = buildSegment(seg);
    seg.el._toolData = d;
    seg.el.querySelector('.name-row').innerHTML = '<span class="toggle-icon">&#9660;</span> <span class="tool-label">&#9881;</span> <span class="name">' + esc(d.name) + '</span><span class="spinner"></span>';
    asst.appendChild(seg.el);
    currentTool = seg;
    scrollToBottom(msgs);
  });

  evtSrc.addEventListener('tool_delta', function(e) {
    if (!currentTool) return;
    var d = JSON.parse(e.data);
    currentTool.output += d.text || '';
    var out = currentTool.el.querySelector('.output');
    if (!out) { out = document.createElement('div'); out.className = 'output'; currentTool.el.appendChild(out); }
    out.textContent = currentTool.output;
    scrollToBottom(msgs);
  });

  evtSrc.addEventListener('tool_error', function(e) {
    if (!currentTool) return;
    try {
      var d = JSON.parse(e.data);
      currentTool.el.classList.add('error');
      var nameRow = currentTool.el.querySelector('.name-row');
      if (nameRow) nameRow.innerHTML = '<span class="toggle-icon">&#9660;</span> <span class="tool-label">&#9881;</span> <span class="name">' + esc(d.name || 'tool') + '</span>';
      var errOut = document.createElement('div');
      errOut.className = 'output';
      errOut.textContent = d.error || 'unknown error';
      currentTool.el.appendChild(errOut);
    } catch(ex) { console.error('tool_error handler:', ex); }
    scrollToBottom(msgs);
  });

  evtSrc.addEventListener('tool_meta', function(e) {
    if (!currentTool) return;
    try {
      var d = JSON.parse(e.data);
      currentTool.el._toolData = currentTool.el._toolData || {};
      Object.keys(d).forEach(function(k) { currentTool.el._toolData[k] = d[k]; });
      var meta = currentTool.el.querySelector('.tool-meta');
      if (!meta) {
        meta = document.createElement('div');
        meta.className = 'tool-meta';
        currentTool.el.insertBefore(meta, currentTool.el.querySelector('.output'));
      }
      var parts = [];
      if (d.exit_code !== undefined) parts.push('exit: ' + d.exit_code);
      if (d.byte_count !== undefined) parts.push(d.byte_count + 'B');
      if (d.total_lines !== undefined) parts.push(d.total_lines + ' lines');
      if (d.match_count !== undefined) parts.push(d.match_count + ' matches');
      if (d.file_count !== undefined) parts.push(d.file_count + ' files');
      if (d.files_scanned !== undefined) parts.push('in ' + d.files_scanned + ' files');
      if (d.replacements !== undefined) parts.push(d.replacements + ' replacements');
      meta.textContent = parts.join(' | ');
    } catch(ex) { console.error('tool_meta handler:', ex); }
  });

  evtSrc.addEventListener('error', function(e) {
    if (!e.data) return;
    var d = JSON.parse(e.data);
    var err = document.createElement('div');
    err.className = 'status-msg error';
    err.textContent = 'Error: ' + (d.message || d.code || 'unknown');
    ensureTextSegment().el.appendChild(err);
    scrollToBottom(msgs);
  });

  evtSrc.onerror = function() {
    abortPrompt();
    var spinners = asst.querySelectorAll('.spinner');
    for (var j = 0; j < spinners.length; j++) spinners[j].remove();
  };

  evtSrc.addEventListener('done', function(e) {
    if (evtSrc) { evtSrc.close(); evtSrc = null; }
    isStreaming = false;
    setStreaming(false);

    // render markdown per text segment
    curSegments.forEach(function(seg) {
      if (seg.type === 'text' && seg.text) {
        updateMarkdownBlocks(seg.el.querySelector('.content'), seg.text);
        var pres = seg.el.querySelectorAll('pre');
        for (var i = 0; i < pres.length; i++) addCopyButton(pres[i]);
      }
    });

    // usage footer
    if (e.data) {
      try {
        var d = JSON.parse(e.data);
        if (d.usage) { usageData = d.usage; }
        if (d.model) { modelName = d.model; }
        if (d.session_id && !currentId) { currentId = d.session_id; }
        if (d.first_message && d.first_message.content) {
          renderSystemPrompt(d.first_message.content);
        }
      } catch(er) {}
    }
    if (usageData && usageData.total) {
      var footer = document.createElement('div');
      footer.className = 'usage-footer';
      var parts = [];
      if (modelName) parts.push(esc(modelName));
      if (usageData.input) parts.push(usageData.input + '\u2191 input');
      if (usageData.output) parts.push(usageData.output + '\u2193 output');
      if (usageData.total) parts.push(usageData.total + ' total');
      if (usageData.cache_hit != null && usageData.cache_miss != null) {
        var total = usageData.cache_hit + usageData.cache_miss;
        if (total > 0) parts.push(Math.round(usageData.cache_hit / total * 100) + '% cache');
      }
      footer.innerHTML = parts.join(' &middot; ');
      var textSeg = ensureTextSegment();
      textSeg.el.appendChild(footer);
    }

    setStreaming(false);
    var spinners = asst.querySelectorAll('.spinner');
    for (var j = 0; j < spinners.length; j++) spinners[j].remove();
    // markdown render tool outputs + collapse + expand-all
    var tools = asst.querySelectorAll('.tool-card');
    tools.forEach(function(tc) {
      tc.onclick = function(e) {
        if (e.target.closest('.output')) return;
        tc.classList.toggle('open');
      };
      var out = tc.querySelector('.output');
      if (out) {
        out.innerHTML = renderMd(out.textContent);
      }
    });
    if (tools.length >= 2) {
      var toggleAll = document.createElement('button');
      toggleAll.className = 'tool-toggle-all';
      toggleAll.textContent = 'Expand all';
      toggleAll.onclick = function() {
        var expand = toggleAll.textContent === 'Expand all';
        tools.forEach(function(tc) { tc.classList.toggle('open', expand); });
        toggleAll.textContent = expand ? 'Collapse all' : 'Expand all';
      };
      asst.insertBefore(toggleAll, tools[0]);
    }
    if (typeof hljs !== 'undefined') hljs.highlightAll();
    // apply typed tool views
    tools.forEach(function(tc) {
      if (tc._toolName) applyToolType(tc, tc._toolName, tc._toolData || {});
    });
    // context tool grouping
    wrapContextToolGroups(asst);
    document.getElementById('prompt-input').focus();
    scrollToBottom(msgs);
    document.getElementById('prompt-input').focus();
    scrollToBottom(msgs);
loadModels();
loadSessions();
  });
}

async function loadCwd() {
  try {
    var r = await fetch(A + '/health');
    var d = await r.json();
    var hint = document.getElementById('cwd-hint');
    if (hint && d.cwd) hint.textContent = d.cwd;
  } catch(e) { /* health fetch is best-effort; hide hint on failure */ }
}

document.getElementById('send-btn').onclick = function() {
  if (isStreaming) { abortPrompt(); return; }
  var inp = document.getElementById('prompt-input');
  var text = inp.value.trim();
  if (!text) return;
  inp.value = '';
  inp.style.height = '';
  sendPrompt(text);
};

document.getElementById('prompt-input').onkeydown = function(e) {
  if (e.key === 'Enter' && !e.shiftKey && !e.ctrlKey) {
    e.preventDefault();
    if (slashVisible && slashFiltered.length > 0) { slashSelect(slashFiltered[slashIndex]); return; }
    var text = this.value.trim();
    if (text.startsWith('/')) { executeSlashCommand(text); return; }
    document.getElementById('send-btn').click();
  } else if (e.key === 'ArrowDown') {
    if (slashVisible) { e.preventDefault(); slashMove(1); }
  } else if (e.key === 'ArrowUp') {
    if (slashVisible) { e.preventDefault(); slashMove(-1); }
  } else if (e.key === 'Escape') {
    if (slashVisible) { e.preventDefault(); slashHide(); }
  }
};

document.getElementById('prompt-input').addEventListener('input', function() {
  this.style.height = '';
  this.style.height = Math.min(this.scrollHeight, 200) + 'px';
  slashUpdate();
});

// --- slash command popover ---
// Core commands come from GET /api/command (server-driven, no inline copy);
// Web-local commands are pure UI actions handled here.
var slashCommands = [];
var slashLocal = [
  { name: 'theme', description: 'Toggle light/dark theme', args_hint: '', run: function() { document.getElementById('theme-btn').click(); } },
  { name: 'clear', description: 'Clear current message view', args_hint: '', run: function() { document.getElementById('messages').innerHTML = ''; } },
  { name: 'model', description: 'Switch model', args_hint: 'provider/model', run: function() { document.getElementById('model-btn').click(); } },
];
var slashFiltered = [];
var slashIndex = -1;
var slashPopover = null;
var slashVisible = false;

function loadSlashCommands() {
  fetch(A + '/command').then(function(r) { return r.json(); }).then(function(list) {
    slashCommands = list || [];
  }).catch(function() { slashCommands = []; });
}

function slashAll() { return slashCommands.concat(slashLocal); }

function slashShow() {
  if (!slashPopover) {
    slashPopover = document.createElement('div');
    slashPopover.className = 'slash-popover';
    document.getElementById('input-bar').appendChild(slashPopover);
  }
  slashVisible = true;
  slashPopover.style.display = 'block';
  slashPopover.onmouseenter = function() { slashSetActive(-1); };
}

function slashHide() {
  slashVisible = false;
  if (slashPopover) slashPopover.style.display = 'none';
}

function slashRender() {
  slashPopover.innerHTML = '';
  slashFiltered.forEach(function(c, i) {
    var item = document.createElement('div');
    item.className = 'slash-item';
    var label = '/' + c.name + (c.args_hint ? ' <' + c.args_hint + '>' : '');
    item.textContent = label;
    var desc = document.createElement('span');
    desc.className = 'slash-desc';
    desc.textContent = '  ' + c.description;
    item.appendChild(desc);
    item.onclick = function() { slashSelect(c); };
    slashPopover.appendChild(item);
  });
  slashSetActive(slashIndex);
}

// Toggle the .active highlight without rebuilding the list — hover/navigation
// must not replace DOM nodes under the cursor (a rebuild between mousedown and
// mouseup would drop the click).
function slashSetActive(idx) {
  var items = slashPopover.querySelectorAll('.slash-item');
  for (var i = 0; i < items.length; i++) {
    items[i].classList.toggle('active', i === idx);
  }
}

function slashUpdate() {
  var input = document.getElementById('prompt-input');
  var value = input.value;
  if (!value.startsWith('/') || value.indexOf(' ') !== -1) { slashHide(); return; }
  var namePart = value.slice(1);
  slashFiltered = slashAll().filter(function(c) { return c.name.indexOf(namePart) === 0; });
  if (slashFiltered.length === 0) { slashHide(); return; }
  if (slashIndex < 0 || slashIndex >= slashFiltered.length) slashIndex = 0;
  slashShow();
  slashRender();
}

function slashMove(delta) {
  if (slashFiltered.length === 0) return;
  slashIndex = (slashIndex + delta + slashFiltered.length) % slashFiltered.length;
  slashSetActive(slashIndex);
}

function slashSelect(c) {
  var input = document.getElementById('prompt-input');
  slashHide();
  if (c.args_hint) {
    input.value = '/' + c.name + ' ';
    input.focus();
  } else {
    executeSlashCommand('/' + c.name);
  }
}

function executeSlashCommand(text) {
  var rest = text.slice(1);
  var argStart = rest.search(/\s/);
  var name = argStart === -1 ? rest : rest.slice(0, argStart);
  var args = argStart === -1 ? '' : rest.slice(argStart + 1).trim();
  clearPromptInput();

  var local = slashLocal.find(function(c) { return c.name === name; });
  if (local) { local.run(args); return; }

  if (!currentId && name !== 'new' && name !== 'list') {
    showStatus('no active session', true);
    return;
  }
  fetch(A + '/command', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: name, args: args, session_id: currentId || undefined }),
  })
    .then(function(r) { return r.json(); })
    .then(function(resp) {
      if (resp.status === 'ok') {
        if (resp.data && resp.data.session_id) {
          switchToSession(resp.data.session_id, resp.data.name);
        } else {
          loadSessions();
        }
        showStatus('/' + name + ' ok', false);
      } else {
        showStatus(resp.message || 'command failed', true);
      }
    })
    .catch(function() { showStatus('command failed', true); });
}

function clearPromptInput() {
  var inp = document.getElementById('prompt-input');
  inp.value = '';
  inp.style.height = '';
}

function switchToSession(id, name) {
  if (evtSrc) { evtSrc.close(); evtSrc = null; }
  currentId = id;
  currentName = name;
  setTopbarTitle(name || 'z-agent-core');
  loadSession(id);
}

function showStatus(text, isError) {
  var msgs = document.getElementById('messages');
  var tip = document.createElement('div');
  tip.className = 'status-msg' + (isError ? ' error' : '');
  tip.textContent = text;
  msgs.appendChild(tip);
  setTimeout(function() { if (tip.parentNode) tip.parentNode.removeChild(tip); }, 3000);
}

document.getElementById('new-session-btn').onclick = async function() {
  try {
    var body = currentModel ? JSON.stringify({model: currentModel}) : '{}';
    var r = await fetch(A + '/session', { method: 'POST', body: body, headers: {'Content-Type':'application/json'} });
    var sess = await r.json();
    if (sess.id) {
      currentId = sess.id;
      currentName = sess.name;
      setTopbarTitle(sess.name);
      document.getElementById('messages').innerHTML = '';
      setStreaming(false);
      await loadSessions();
    }
  } catch(e) { console.error(e); }
};

async function deleteSession(id) {
  if (!(await confirmModal('Delete this session?'))) return;
  try {
    await api('/session/' + id, { method: 'DELETE' });
    if (currentId === id) {
      currentId = null;
      currentName = null;
      setTopbarTitle('z-agent-core');
      document.getElementById('messages').innerHTML = '';
      setStreaming(false);
    }
    await loadSessions();
  } catch(e) { console.error(e); }
}

function copyText(text, btn, doneLabel) {
  var done = function() {
    if (!btn) return;
    var hasIcon = btn.querySelector('svg');
    if (hasIcon) {
      var orig = btn.title;
      btn.title = doneLabel || 'Copied!';
      setTimeout(function() { btn.title = orig; }, 1500);
    } else {
      var orig = btn.textContent;
      btn.textContent = doneLabel || 'Copied!';
      setTimeout(function() { btn.textContent = orig; }, 1500);
    }
  };
  if (navigator.clipboard && window.isSecureContext) {
    navigator.clipboard.writeText(text).then(done).catch(function() { fallbackCopy(text); done(); });
  } else { fallbackCopy(text); done(); }
}
function fallbackCopy(text) {
  var ta = document.createElement('textarea');
  ta.value = text;
  ta.style.position = 'fixed'; ta.style.opacity = '0';
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand('copy'); } catch(e) {}
  document.body.removeChild(ta);
}
function addCopyButton(container, getText) {
  var btn = document.createElement('button');
  btn.className = 'copy-btn';
  btn.textContent = 'Copy';
  btn.onclick = function(e) {
    e.stopPropagation();
    var codeEl = container.querySelector ? container.querySelector('code') : null;
    var text = getText ? getText() : (codeEl ? codeEl.textContent : container.textContent);
    copyText(text, btn);
  };
  container.appendChild(btn);
}
function genUuidV4() {
  if (crypto.randomUUID) return crypto.randomUUID();
  var b = new Uint8Array(16);
  crypto.getRandomValues(b);
  b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  var hex = Array.prototype.map.call(b, function(x) { return ('0' + x.toString(16)).slice(-2); });
  return hex.slice(0,4).join('') + '-' + hex.slice(4,6).join('') + '-' + hex.slice(6,8).join('') + '-' +
         hex.slice(8,10).join('') + '-' + hex.slice(10,16).join('');
}
var abortInFlight = false;
function abortPrompt() {
  if (!currentId || abortInFlight) return;
  abortInFlight = true;
  fetch(A + '/session/' + currentId + '/abort', { method: 'POST' })
    .catch(function() {})
    .finally(function() { abortInFlight = false; });
  if (evtSrc) { evtSrc.close(); evtSrc = null; }
  setStreaming(false);
  isStreaming = false;
  var spinners = document.querySelectorAll('#messages .spinner');
  for (var j = 0; j < spinners.length; j++) spinners[j].remove();
}
function esc(s) { return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

// --- tool registry (typed views) ---
var ToolRegistry = {
  bash: function(toolDiv, d) {
    var nameRow = toolDiv.querySelector('.name-row');
    if (nameRow) {
      var copyCmd = document.createElement('button');
      copyCmd.className = 'copy-cmd';
      copyCmd.textContent = 'Copy cmd';
      copyCmd.onclick = function(e) {
        e.stopPropagation();
        if (d.input) copyText(d.input, copyCmd, 'Copied!');
      };
      nameRow.appendChild(copyCmd);
    }
    // Bash output: wrap in pre/code
    var out = toolDiv.querySelector('.output');
    if (out) {
      out.innerHTML = '<pre><code>' + esc(out.textContent) + '</code></pre>';
    }
  },
  read: function(toolDiv, d) {
    setToolIcon(toolDiv, '&#8962;');
    var p = [];
    if (d.total_lines) p.push(d.total_lines + ' lines');
    if (d.byte_count) p.push(d.byte_count + 'B');
    if (p.length) setToolMeta(toolDiv, p);
  },
  write: function(toolDiv, d) {
    setToolIcon(toolDiv, '&#9998;');
    var p = [];
    if (d.byte_count) p.push(d.byte_count + 'B');
    if (d.existed !== undefined) p.push(d.existed ? 'overwrote' : 'new file');
    if (p.length) setToolMeta(toolDiv, p);
  },
  edit: function(toolDiv, d) {
    setToolIcon(toolDiv, '&#9986;');
    if (d.replacements) setToolMeta(toolDiv, [d.replacements + ' replacements']);
  },
  grep: function(toolDiv, d) {
    setToolIcon(toolDiv, '&#8981;');
    var p = [];
    if (d.match_count) p.push(d.match_count + ' matches');
    if (d.files_scanned) p.push('in ' + d.files_scanned + ' files');
    if (p.length) setToolMeta(toolDiv, p);
  },
  glob: function(toolDiv, d) {
    setToolIcon(toolDiv, '&#8727;');
    if (d.file_count) setToolMeta(toolDiv, [d.file_count + ' files']);
  },
  skill: function(toolDiv, d) {
    setToolIcon(toolDiv, '&#9889;');
    if (d.file_count) setToolMeta(toolDiv, [d.file_count + ' files']);
  }
};

function setToolIcon(toolDiv, html) {
  var label = toolDiv.querySelector('.tool-label');
  if (label) label.innerHTML = html;
}
function setToolMeta(toolDiv, parts) {
  var meta = toolDiv.querySelector('.tool-meta');
  if (!meta) {
    meta = document.createElement('div');
    meta.className = 'tool-meta';
    var nr = toolDiv.querySelector('.name-row');
    if (nr && nr.nextSibling) nr.parentNode.insertBefore(meta, nr.nextSibling);
    else nr.parentNode.appendChild(meta);
  }
  meta.textContent = parts.join(' | ');
}

// --- context tool grouping ---
function isContextTool(name) {
  return name === 'read' || name === 'grep' || name === 'glob';
}
function wrapContextToolGroups(container) {
  var cards = [];
  var all = container.querySelectorAll('.tool-card');
  for (var i = 0; i < all.length; i++) cards.push(all[i]);
  // Pass 1: mark boundaries
  var groups = [], start = null, groupEnd = null;
  for (var i = 0; i < cards.length; i++) {
    var c = cards[i];
    if (c._toolName && isContextTool(c._toolName)) {
      if (!start) start = c;
      groupEnd = c;
    } else {
      if (start) { groups.push({from: start, to: groupEnd}); start = groupEnd = null; }
    }
  }
  if (start) groups.push({from: start, to: groupEnd});
  // Pass 2: wrap
  for (var g = 0; g < groups.length; g++) {
    var group = groups[g];
    var wrap = document.createElement('div');
    wrap.className = 'context-tool-group';
    // summary
    var summary = document.createElement('div');
    summary.className = 'group-summary';
    var counts = {};
    var el = group.from;
    while (el) {
      var n = el._toolName || '?';
      counts[n] = (counts[n] || 0) + 1;
      if (el === group.to) break;
      el = el.nextSibling;
    }
    var parts = [];
    if (counts.read) parts.push('read: ' + counts.read + ' files');
    if (counts.grep) parts.push('grep: ' + counts.grep + ' calls');
    if (counts.glob) parts.push('glob: ' + counts.glob + ' files');
    summary.textContent = 'Gathering context (' + parts.join(', ') + ')';
    wrap.appendChild(summary);
    // move cards
    group.from.parentNode.insertBefore(wrap, group.from);
    el = group.from;
    while (el) {
      var next = el.nextSibling;
      wrap.appendChild(el);
      if (el === group.to) break;
      el = next;
    }
    hljs.highlightAll();
  }
}

function applyToolType(toolDiv, toolName, toolData) {
  if (ToolRegistry[toolName]) {
    toolDiv.className += ' tool-' + toolName;
    try { ToolRegistry[toolName](toolDiv, toolData); } catch(ex) { console.error('ToolRegistry error:', ex); }
  }
}

loadSessions();
loadModels();
loadSlashCommands();
loadCwd();
// Resume the most recently updated session after a refresh.
api('/session/active').then(function(s) {
  if (s && s.id && !currentId) loadSession(s.id);
}).catch(function() {});