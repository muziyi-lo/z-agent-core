const A = '/api';
let currentId = null;
let currentName = null;
let currentModel = null;
let evtSrc = null;
let isStreaming = false;

// --- sidebar toggle ---
document.getElementById('sidebar-toggle').onclick = function() {
  if (window.matchMedia('(max-width: 768px)').matches) {
    document.body.classList.remove('sidebar-collapsed');
    document.getElementById('sidebar').classList.toggle('open');
  } else {
    var collapsed = document.body.classList.toggle('sidebar-collapsed');
    localStorage.setItem('zagent-sidebar-collapsed', collapsed ? '1' : '0');
  }
};
if (localStorage.getItem('zagent-sidebar-collapsed') === '1') {
  document.body.classList.add('sidebar-collapsed');
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

// --- auto-scroll helper ---
function isNearBottom(el) {
  return el.scrollHeight - el.scrollTop - el.clientHeight < 50;
}
function scrollToBottom(el) {
  if (isNearBottom(el)) el.scrollTop = el.scrollHeight;
}
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
async function loadModels() {
  var sel = document.getElementById('model-select');
  try {
    var models = await api('/model');
    if (!models || models.length === 0) throw new Error('empty');
    sel.innerHTML = '';
    models.forEach(function(m) {
      var opt = document.createElement('option');
      opt.value = m.id;
      opt.textContent = m.name;
      opt.title = m.id;
      sel.appendChild(opt);
    });
    // restore from localStorage or use first
    var saved = localStorage.getItem('zagent-model');
    if (saved && models.some(function(m) { return m.id === saved; })) {
      sel.value = saved;
    } else {
      sel.value = models[0].id;
    }
    currentModel = sel.value;
  } catch(e) {
    var saved = localStorage.getItem('zagent-model');
    if (saved) {
      sel.innerHTML = '<option value="' + esc(saved) + '">' + esc(saved) + '</option>';
      sel.value = saved;
      currentModel = saved;
    } else {
      sel.innerHTML = '<option value="">Default</option>';
      currentModel = '';
    }
  }
}
document.getElementById('model-select').onchange = function() {
  currentModel = this.value;
  if (currentModel) localStorage.setItem('zagent-model', currentModel);
  var hasMsgs = document.querySelectorAll('#messages .msg:not(#system-prompt), #messages .tool-card').length > 0;
  if (hasMsgs) {
    var tip = document.createElement('div');
    tip.className = 'status-msg';
    tip.textContent = 'Model switch applies to new sessions only';
    document.getElementById('messages').insertBefore(tip, document.getElementById('messages').firstChild);
    setTimeout(function() { if (tip.parentNode) tip.parentNode.removeChild(tip); }, 3000);
  }
};

// --- session list ---
async function loadSessions() {
  var list; try { list = await api('/session'); } catch(e) { console.error('loadSessions error', e); return; }
  var el = document.getElementById('session-list');
  el.innerHTML = '';
  if (list.length === 0) {
    el.innerHTML = '<div class="empty-hint">No sessions yet</div>';
    return;
  }

  var now = new Date();
  var todayStart = Math.floor(new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime() / 1000);
  var yesterdayStart = Math.floor(new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1).getTime() / 1000);
  var weekStart = Math.floor(new Date(now.getFullYear(), now.getMonth(), now.getDate() - 7).getTime() / 1000);

  var groups = { today: [], yesterday: [], week: [], older: [] };
  list.forEach(function(s) {
    if (s.timestamp >= todayStart) groups.today.push(s);
    else if (s.timestamp >= yesterdayStart) groups.yesterday.push(s);
    else if (s.timestamp >= weekStart) groups.week.push(s);
    else groups.older.push(s);
  });

  function renderGroup(label, items) {
    if (items.length === 0) return;
    var hdr = document.createElement('div');
    hdr.className = 'section-header';
    hdr.textContent = label;
    el.appendChild(hdr);
    items.forEach(function(s) {
      var div = document.createElement('div');
      div.className = 'session' + (s.id === currentId ? ' active' : '');
      div.innerHTML = '<div class="name">' + esc(s.name) + '</div><div class="meta">' + esc(s.model) + ' &middot; ' + s.msg_count + ' msgs</div><span class="delete-btn">&times;</span>';

      div.querySelector('.delete-btn').onclick = function(e) { e.stopPropagation(); deleteSession(s.id); };

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
              if (currentId === s.id) { currentName = newName; document.getElementById('topbar').textContent = newName; }
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
      el.appendChild(div);
    });
  }

  var labels = { today: 'Today', yesterday: 'Yesterday', week: 'This Week', older: 'Older' };
  for (var i = 0; i < ['today','yesterday','week','older'].length; i++) {
    var key = ['today','yesterday','week','older'][i];
    renderGroup(labels[key], groups[key]);
  }
}

async function loadSession(id) {
  var sess;
  try { sess = await api('/session/' + id); }
  catch(e) { console.error('loadSession error', e); return; }
  currentId = id;
  currentName = sess.name;
  document.getElementById('topbar').textContent = sess.name;
  document.getElementById('prompt-input').disabled = false;
  document.getElementById('send-btn').disabled = false;
  document.getElementById('stop-btn').disabled = true;
  var msgs = document.getElementById('messages');
  msgs.innerHTML = '';
  var start = 0;
  if (sess.messages.length > 0) {
    renderSystemPrompt(sess.messages[0].content);
    start = 1;
  }
  var lastAsst = null;
  for (var i = start; i < sess.messages.length; i++) {
    var m = sess.messages[i];
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
      continue;
    }
    lastAsst = addMessage(m, i, null);
    if (m.role === 'assistant') wrapContextToolGroups(lastAsst);
  }
  await loadSessions();
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
  el.innerHTML = renderMd(content);
  el.style.display = '';
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

function addMessage(m, index, toolName) {
  var msgs = document.getElementById('messages');
  var role = m.role;
  var content = m.content || '';
  var div = document.createElement('div');

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
  if (index !== undefined && index > 0 && role !== 'user') {
    var delBtn = document.createElement('span');
    delBtn.className = 'msg-delete';
    delBtn.textContent = '\u00d7';
    delBtn.title = 'Delete this message';
    delBtn.onclick = async function(e) {
      e.stopPropagation();
      if (isStreaming) return;
      if (!(await confirmModal('Delete this message?'))) return;
      try {
        await api('/session/' + currentId + '/message/' + index, { method: 'DELETE' });
        div.remove();
        await loadSession(currentId);
      } catch(err) { console.error(err); }
    };
    div.appendChild(delBtn);
  }

  // action buttons for user messages
  if (role === 'user') {
    var actions = document.createElement('div');
    actions.className = 'msg-actions';
    var revertBtn = document.createElement('button');
    revertBtn.className = 'msg-action';
    revertBtn.textContent = 'revert';
    revertBtn.onclick = function(e) {
      e.stopPropagation();
      document.getElementById('prompt-input').value = content;
      document.getElementById('prompt-input').focus();
    };
    actions.appendChild(revertBtn);
    var copyBtn = document.createElement('button');
    copyBtn.className = 'msg-action';
    copyBtn.textContent = 'copy';
    copyBtn.onclick = function(e) {
      e.stopPropagation();
      copyText(content, copyBtn, 'copied!');
    };
    actions.appendChild(copyBtn);
    if (index !== undefined && index > 0) {
      var delActionBtn = document.createElement('button');
      delActionBtn.className = 'msg-action danger';
      delActionBtn.textContent = '\u00d7';
      delActionBtn.onclick = async function(e) {
        e.stopPropagation();
        if (isStreaming) return;
        if (!(await confirmModal('Delete this message?'))) return;
        try {
          await api('/session/' + currentId + '/message/' + index, { method: 'DELETE' });
          div.remove();
          await loadSession(currentId);
        } catch(err) { console.error(err); }
      };
      actions.appendChild(delActionBtn);
    }
    div.appendChild(actions);
  }

  msgs.appendChild(div);
  msgs.scrollTop = msgs.scrollHeight;
  return div;
}

// --- SSE streaming ---
function sendPrompt(prompt) {
  if (!currentId) {
    currentId = genUuidV4();
  }
  document.getElementById('send-btn').disabled = true;
  document.getElementById('stop-btn').disabled = false;
  document.getElementById('prompt-input').disabled = true;
  isStreaming = true;

  var msgs = document.getElementById('messages');
  var nextIndex = document.querySelectorAll('#messages .msg, #messages .tool-card').length;
  addMessage({role:'user', content:prompt}, nextIndex);

  var asst = document.createElement('div');
  asst.className = 'msg assistant';
  asst.innerHTML = '<span class="spinner"></span>';
  msgs.appendChild(asst);
  msgs.scrollTop = msgs.scrollHeight;

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
  var url = A + '/session/' + currentId + '/prompt?prompt=' + encodeURIComponent(prompt);
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
      if (d.name) { currentName = d.name; document.getElementById('topbar').textContent = d.name; }
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
    document.getElementById('stop-btn').disabled = true;

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

    document.getElementById('send-btn').disabled = false;
    document.getElementById('prompt-input').disabled = false;
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

document.getElementById('send-btn').onclick = function() {
  var inp = document.getElementById('prompt-input');
  var text = inp.value.trim();
  if (!text) return;
  inp.value = '';
  inp.style.height = '';
  sendPrompt(text);
};

document.getElementById('stop-btn').onclick = function() { abortPrompt(); };

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
  { name: 'model', description: 'Switch model', args_hint: 'provider/model', run: function() { document.getElementById('model-select').focus(); } },
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
  document.getElementById('topbar').textContent = name || 'z-agent-core';
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
      document.getElementById('topbar').textContent = sess.name;
      document.getElementById('messages').innerHTML = '';
      document.getElementById('prompt-input').disabled = false;
      document.getElementById('send-btn').disabled = false;
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
      document.getElementById('topbar').textContent = 'z-agent-core';
      document.getElementById('messages').innerHTML = '';
      document.getElementById('prompt-input').disabled = false;
      document.getElementById('send-btn').disabled = false;
      document.getElementById('stop-btn').disabled = true;
    }
    await loadSessions();
  } catch(e) { console.error(e); }
}

function copyText(text, btn, doneLabel) {
  var done = function() {
    if (!btn) return;
    var orig = btn.textContent;
    btn.textContent = doneLabel || 'Copied!';
    setTimeout(function() { btn.textContent = orig; }, 1500);
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
    copyText(getText ? getText() : container.textContent, btn);
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
  document.getElementById('send-btn').disabled = false;
  document.getElementById('stop-btn').disabled = true;
  document.getElementById('prompt-input').disabled = false;
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