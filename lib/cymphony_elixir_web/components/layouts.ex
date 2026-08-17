defmodule CymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @version Mix.Project.config()[:version]

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:version, @version)

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Cymphony Observability</title>
        <script>
          // Apply persisted theme + display prefs before paint to avoid FOUC.
          (function() {
            document.documentElement.setAttribute('data-ui-mode', 'simple');

            try {
              var t = localStorage.getItem('cymphony-theme');
              if (t === 'dark' || t === 'light') {
                document.documentElement.setAttribute('data-theme', t);
              }
            } catch (e) {}

            try {
              var prefs = JSON.parse(localStorage.getItem('cymphony-prefs') || '{}');
              var html = document.documentElement;
              html.setAttribute('data-ui-mode', prefs.uiMode === 'advanced' ? 'advanced' : 'simple');
              if (prefs.density === 'compact') html.setAttribute('data-density', 'compact');
              if (prefs.hiddenSections && prefs.hiddenSections.length) {
                html.setAttribute('data-hidden-sections', prefs.hiddenSections.join(' '));
              }
              if (prefs.collapsedSections && prefs.collapsedSections.length) {
                html.setAttribute('data-collapsed-sections', prefs.collapsedSections.join(' '));
              }
              var expandedSections = Array.isArray(prefs.expandedSections) ? prefs.expandedSections : [];
              var legacyExpandedCompletions = !Object.prototype.hasOwnProperty.call(prefs, 'expandedSections') &&
                Object.prototype.hasOwnProperty.call(prefs, 'collapsedSections') &&
                Array.isArray(prefs.collapsedSections) && prefs.collapsedSections.length === 0;
              if (legacyExpandedCompletions) expandedSections = ['completions'];
              if (expandedSections.length) {
                html.setAttribute('data-expanded-sections', expandedSections.join(' '));
              }
              if (prefs.hiddenCols && prefs.hiddenCols.length) {
                html.setAttribute('data-hidden-cols', prefs.hiddenCols.join(' '));
              }
              if (prefs.completionsLimit && prefs.completionsLimit !== '100') {
                html.setAttribute('data-completions-limit', prefs.completionsLimit);
              }
            } catch (e) {}
          })();
        </script>
        <script src={"/vendor/phoenix_html/phoenix_html.js?v=#{@version}"}></script>
        <script src={"/vendor/phoenix/phoenix.js?v=#{@version}"}></script>
        <script src={"/vendor/phoenix_live_view/phoenix_live_view.js?v=#{@version}"}></script>
        <link rel="stylesheet" href={"/dashboard.css?v=#{@version}"} />
      </head>
      <body>
        {@inner_content}

        <script>
          (function() {
            var meta = document.querySelector("meta[name='csrf-token']");
            var csrfToken = meta ? meta.getAttribute("content") : null;

            if (!window.Phoenix || !window.LiveView) {
              console.error("Phoenix or LiveView not loaded");
              return;
            }

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: {
                HarnessTail: {
                  mounted() { this.updated(); },
                  updated() {
                    var el = this.el;
                    if (el.getAttribute('data-follow') === 'true') {
                      var body = el.querySelector('.harness-tail-body');
                      if (body) body.scrollTop = body.scrollHeight;
                    }
                  }
                },
                // Advances every [data-clock] span locally so the server never has to
                // re-render time strings on a timer. Anchors are remaining/elapsed
                // amounts (never absolute wall times), so client clock skew cannot
                // accumulate: each tick compares the span's current data attributes
                // against the snapshot cached on the node and re-anchors when the
                // server patched them. Formatting mirrors dashboard_live.ex byte for
                // byte; a span with missing or unparseable data is left untouched, so
                // the server-rendered text stays as the no-JS fallback.
                LiveClock: {
                  mounted() {
                    this._onClockTick = this.tick.bind(this);
                    this.tick();
                    this._clockTimer = window.setInterval(this._onClockTick, 1000);
                  },
                  // Every LiveView patch re-serializes this container from the server's
                  // cached tree and morphdom writes each span's textContent back to what
                  // the server rendered at the last payload load. Without repainting here
                  // the clocks would rewind on every patch (a streaming harness pane
                  // patches ~12x/sec) and stay wrong until the next 1s interval.
                  updated() {
                    this.tick();
                  },
                  destroyed() {
                    if (this._clockTimer) {
                      window.clearInterval(this._clockTimer);
                      this._clockTimer = null;
                    }
                  },
                  tick() {
                    var nodes = this.el.querySelectorAll('[data-clock]');
                    var now = Date.now();
                    for (var i = 0; i < nodes.length; i++) {
                      this.paint(nodes[i], now);
                    }
                  },
                  paint(el, now) {
                    var kind = el.getAttribute('data-clock');
                    var remaining = el.getAttribute('data-remaining-ms');
                    var base = el.getAttribute('data-base-seconds');
                    var rate = el.getAttribute('data-rate');
                    var snapshot = kind + '|' + remaining + '|' + base + '|' + rate;
                    if (el._clockSnapshot !== snapshot) {
                      el._clockSnapshot = snapshot;
                      el._clockAnchoredAt = now;
                    }
                    var elapsedMs = now - el._clockAnchoredAt;
                    if (!(elapsedMs > 0)) elapsedMs = 0;
                    var text = null;
                    if (kind === 'countdown' || kind === 'due') {
                      var left = parseFloat(remaining);
                      if (!isFinite(left)) return;
                      left = left - elapsedMs;
                      text = kind === 'due' ? this.formatDue(left) : this.formatCountdown(left);
                    } else if (kind === 'elapsed') {
                      var seconds = parseFloat(base);
                      if (!isFinite(seconds)) return;
                      var perSecond = parseFloat(rate);
                      if (!isFinite(perSecond)) perSecond = 1;
                      text = this.formatElapsed(seconds + perSecond * (elapsedMs / 1000));
                    } else {
                      return;
                    }
                    if (el.textContent !== text) el.textContent = text;
                  },
                  // format_runtime_seconds/1
                  formatElapsed(seconds) {
                    var whole = Math.trunc(seconds);
                    if (!(whole > 0)) whole = 0;
                    var mins = Math.trunc(whole / 60);
                    return mins + 'm ' + (whole - mins * 60) + 's';
                  },
                  // format_poll_countdown/1
                  formatCountdown(ms) {
                    var seconds = Math.trunc(ms / 1000);
                    if (!(seconds > 0)) seconds = 0;
                    return seconds + 's';
                  },
                  // format_retry_countdown/2
                  formatDue(ms) {
                    if (!(ms > 0)) return 'now';
                    return this.formatElapsed(Math.trunc(ms / 1000));
                  }
                },
                Combobox: {
                  mounted() {
                    this._onSearchInput = this.onSearchInput.bind(this);
                    this._onSearchKeydown = this.onSearchKeydown.bind(this);
                    this._onTriggerClick = this.onTriggerClick.bind(this);
                    this._onTriggerKeydown = this.onTriggerKeydown.bind(this);
                    this._onPointer = this.onPointer.bind(this);
                    this._onDocPointer = this.onDocPointer.bind(this);
                    this.open = false;
                    this.activeIndex = -1;
                    this.activeValue = null;
                    this.query = '';
                    this.options = [];
                    this.visibleOptions = [];
                    this._restore = null;
                    this.bind();
                    this.cacheOptions();
                    this.close();
                    this.syncTrigger();
                  },
                  // A LiveView patch morphs this whole subtree: the panel's
                  // server-rendered `hidden` comes back, `combobox--open` is
                  // stripped off the root, the search input's value and the
                  // per-option `hidden`/`aria-selected` flags are rewritten, and
                  // hiding an ancestor of the focused search box blurs it. So
                  // snapshot the hook-owned DOM *before* the morph (beforeUpdate
                  // is paired with updated) and put it back afterwards. The old
                  // code inferred "still open" from document.activeElement in
                  // updated(), which is already false by then, and fell through
                  // to close() — which clears the typed filter. That is the
                  // "dropdowns get refreshed" bug.
                  beforeUpdate() {
                    this.queryParts();
                    this._restore = null;
                    if (!this.open) return;
                    var focused = !!(this.search && document.activeElement === this.search);
                    this._restore = {
                      query: this.search ? this.search.value : (this.query || ''),
                      activeValue: this.activeValue || null,
                      focused: focused,
                      selStart: focused ? this.search.selectionStart : null,
                      selEnd: focused ? this.search.selectionEnd : null
                    };
                  },
                  updated() {
                    this.bind();
                    this.cacheOptions();
                    this.syncTrigger();
                    var r = this._restore;
                    this._restore = null;
                    // Was closed: assert closed chrome without calling close(),
                    // which would clear a query the user may still be typing.
                    if (!r) { this.setOpen(false); return; }
                    // Order matters: setOpen first so the panel is visible before
                    // we focus into it, and re-highlight after filter() because
                    // filter() calls clearActive().
                    this.setOpen(true);
                    if (this.search) this.search.value = r.query;
                    this.query = r.query;
                    this.filter(r.query);
                    if (r.activeValue) {
                      // Re-highlight by value, not index: the option list itself
                      // may have changed (a kind switch rewrites the models).
                      var vis = this.visibleOptions || [];
                      for (var i = 0; i < vis.length; i++) {
                        if (this.optionValue(vis[i]) === r.activeValue) { this.setActive(i); break; }
                      }
                    }
                    // Only steal focus back if it was ours before the morph, so a
                    // patch landing while the operator types elsewhere cannot
                    // yank the caret.
                    if (r.focused && this.search) {
                      this.search.focus();
                      if (r.selStart !== null && this.search.setSelectionRange) {
                        this.search.setSelectionRange(r.selStart, r.selEnd);
                      }
                    }
                  },
                  destroyed() {
                    if (this.setChrome) this.setChrome(false);
                    this.unbind();
                  },
                  allowCustom() {
                    return this.el.getAttribute('data-allow-custom') === 'true';
                  },
                  queryParts() {
                    this.trigger = this.el.querySelector('.combobox-trigger');
                    this.search = this.el.querySelector('.combobox-search, .combobox-input');
                    this.hidden = this.el.querySelector('input[type="hidden"]');
                    this.panel = this.el.querySelector('.combobox-panel');
                    this.list = this.el.querySelector('ul[role="listbox"]');
                    this.triggerLabel = this.el.querySelector('.combobox-trigger-label');
                  },
                  bind() {
                    this.unbind();
                    this.queryParts();
                    if (this.trigger) {
                      this.trigger.addEventListener('click', this._onTriggerClick);
                      this.trigger.addEventListener('keydown', this._onTriggerKeydown);
                    }
                    if (this.search) {
                      this.search.addEventListener('input', this._onSearchInput);
                      this.search.addEventListener('keydown', this._onSearchKeydown);
                    }
                    this.el.addEventListener('mousedown', this._onPointer);
                    this.el.addEventListener('click', this._onPointer);
                    document.addEventListener('mousedown', this._onDocPointer);
                  },
                  unbind() {
                    if (this.trigger) {
                      this.trigger.removeEventListener('click', this._onTriggerClick);
                      this.trigger.removeEventListener('keydown', this._onTriggerKeydown);
                    }
                    if (this.search) {
                      this.search.removeEventListener('input', this._onSearchInput);
                      this.search.removeEventListener('keydown', this._onSearchKeydown);
                    }
                    this.el.removeEventListener('mousedown', this._onPointer);
                    this.el.removeEventListener('click', this._onPointer);
                    document.removeEventListener('mousedown', this._onDocPointer);
                  },
                  cacheOptions() {
                    this.queryParts();
                    this.options = this.list
                      ? Array.prototype.slice.call(this.list.querySelectorAll('li[role="option"]'))
                      : [];
                    var prefix = (this.list && this.list.id) ? this.list.id : 'combobox';
                    this.options.forEach(function(opt, i) {
                      if (!opt.id) opt.id = prefix + '-opt-' + i;
                    });
                  },
                  optionValue(opt) {
                    if (!opt) return '';
                    var data = opt.getAttribute('data-value');
                    if (data !== null) return data;
                    return (opt.textContent || '').trim();
                  },
                  optionText(opt) {
                    if (!opt) return '';
                    var label = opt.getAttribute('data-label');
                    if (label) return label;
                    return (opt.textContent || '').trim();
                  },
                  currentValue() {
                    return this.hidden ? (this.hidden.value || '') : '';
                  },
                  placeholder() {
                    return this.el.getAttribute('data-placeholder') || '';
                  },
                  syncTrigger() {
                    if (!this.triggerLabel) return;
                    var value = this.currentValue();
                    var label = this.placeholder();
                    var i, opt;
                    if (value !== '') {
                      label = value;
                      for (i = 0; i < (this.options || []).length; i++) {
                        opt = this.options[i];
                        if (this.optionValue(opt) === value) {
                          label = this.optionText(opt);
                          break;
                        }
                      }
                    }
                    this.triggerLabel.textContent = label;
                    if (this.trigger) this.trigger.classList.toggle('combobox-trigger--empty', value === '');
                  },
                  notifyHidden() {
                    if (!this.hidden) return;
                    this.hidden.dispatchEvent(new Event('input', {bubbles: true}));
                    this.hidden.dispatchEvent(new Event('change', {bubbles: true}));
                  },
                  setChrome(open) {
                    var on = !!open;
                    this.el.classList.toggle('combobox--open', on);
                    this.syncChromeAncestor('.project-section', on);
                    this.syncChromeAncestor('.session-row', on);
                    this.syncChromeAncestor('.queue-card', on);
                  },
                  // A section/row/card holds several comboboxes and a patch runs
                  // updated() on every one of them. Unconditionally removing the
                  // class because *this* one is closed would strip the open
                  // chrome (z-index, overflow) from a sibling that is still open,
                  // depending on DOM order. `combobox--open` is toggled on self
                  // first, so this never sees itself.
                  syncChromeAncestor(selector, on) {
                    var node = this.el.closest(selector);
                    if (!node) return;
                    if (on) node.classList.add('is-combobox-open');
                    else if (!node.querySelector('.combobox--open')) node.classList.remove('is-combobox-open');
                  },
                  setOpen(open) {
                    this.open = !!open;
                    if (this.panel) this.panel.hidden = !this.open;
                    this.setChrome(this.open);
                    if (this.trigger) this.trigger.setAttribute('aria-expanded', this.open ? 'true' : 'false');
                    if (this.search) {
                      this.search.setAttribute('aria-expanded', this.open ? 'true' : 'false');
                      if (!this.open) this.search.removeAttribute('aria-activedescendant');
                    }
                    if (!this.open) this.clearActive();
                  },
                  openPanel() {
                    if (this.search) this.search.value = '';
                    this.query = '';
                    this.filter('');
                    this.setOpen(true);
                    var search = this.search;
                    if (search) window.setTimeout(function() { search.focus(); }, 0);
                  },
                  close() {
                    if (this.search) this.search.value = '';
                    this.query = '';
                    this.setOpen(false);
                  },
                  clearActive() {
                    this.activeIndex = -1;
                    this.activeValue = null;
                    (this.options || []).forEach(function(opt) {
                      opt.setAttribute('aria-selected', 'false');
                    });
                    if (this.search) this.search.removeAttribute('aria-activedescendant');
                  },
                  setActive(index) {
                    var vis = this.visibleOptions || [];
                    if (!vis.length) {
                      this.clearActive();
                      return;
                    }
                    if (index < 0) index = 0;
                    if (index >= vis.length) index = vis.length - 1;
                    this.activeIndex = index;
                    var active = vis[index];
                    this.activeValue = this.optionValue(active);
                    vis.forEach(function(opt, i) {
                      opt.setAttribute('aria-selected', i === index ? 'true' : 'false');
                    });
                    if (this.search) {
                      if (active && active.id) this.search.setAttribute('aria-activedescendant', active.id);
                      else this.search.removeAttribute('aria-activedescendant');
                    }
                    if (active && active.scrollIntoView) active.scrollIntoView({block: 'nearest'});
                  },
                  filter(query) {
                    var q = (query || '').toLowerCase();
                    var visible = [];
                    (this.options || []).forEach(function(opt) {
                      var value = this.optionValue(opt).toLowerCase();
                      var label = this.optionText(opt).toLowerCase();
                      var match = !q || value.indexOf(q) !== -1 || label.indexOf(q) !== -1;
                      opt.hidden = !match;
                      if (match) visible.push(opt);
                    }, this);
                    this.visibleOptions = visible;
                    this.clearActive();
                  },
                  moveActive(delta) {
                    if (!this.open) this.openPanel();
                    var vis = this.visibleOptions || [];
                    if (!vis.length) return;
                    var next;
                    if (this.activeIndex < 0) next = delta > 0 ? 0 : vis.length - 1;
                    else next = this.activeIndex + delta;
                    this.setActive(next);
                  },
                  onSearchInput() {
                    this.query = this.search ? this.search.value : '';
                    this.filter(this.query);
                    if (!this.open) this.setOpen(true);
                  },
                  onTriggerClick(e) {
                    e.preventDefault();
                    if (this.open) this.close();
                    else this.openPanel();
                  },
                  onTriggerKeydown(e) {
                    var key = e.key;
                    if (key === 'ArrowDown' || key === 'Enter' || key === ' ') {
                      e.preventDefault();
                      this.openPanel();
                    }
                  },
                  onPointer(e) {
                    var opt = e.target.closest ? e.target.closest('[role="option"]') : null;
                    if (!opt || !this.list || !this.list.contains(opt)) return;
                    if (e.type === 'mousedown') e.preventDefault();
                    this.commitOption(opt);
                  },
                  onDocPointer(e) {
                    if (!this.el.contains(e.target)) this.close();
                  },
                  commitValue(value, label) {
                    if (this.hidden) this.hidden.value = value;
                    if (this.triggerLabel) this.triggerLabel.textContent = label || value || this.placeholder();
                    if (this.trigger) this.trigger.classList.toggle('combobox-trigger--empty', !value);
                    this.notifyHidden();
                    this.close();
                  },
                  commitOption(opt) {
                    this.commitValue(this.optionValue(opt), this.optionText(opt));
                  },
                  commitSearchText() {
                    if (!this.allowCustom()) {
                      this.close();
                      return;
                    }
                    var text = this.search ? this.search.value.trim() : '';
                    this.commitValue(text, text || this.placeholder());
                  },
                  onSearchKeydown(e) {
                    var key = e.key;
                    if (key === 'ArrowDown') {
                      e.preventDefault();
                      this.moveActive(1);
                      return;
                    }
                    if (key === 'ArrowUp') {
                      e.preventDefault();
                      this.moveActive(-1);
                      return;
                    }
                    if (key === 'Home') {
                      if (!this.open) return;
                      e.preventDefault();
                      if ((this.visibleOptions || []).length) this.setActive(0);
                      return;
                    }
                    if (key === 'End') {
                      if (!this.open) return;
                      e.preventDefault();
                      var last = (this.visibleOptions || []).length - 1;
                      if (last >= 0) this.setActive(last);
                      return;
                    }
                    if (key === 'Enter') {
                      if (!this.open) return;
                      e.preventDefault();
                      var vis = this.visibleOptions || [];
                      if (this.activeIndex >= 0 && vis[this.activeIndex]) this.commitOption(vis[this.activeIndex]);
                      else this.commitSearchText();
                      return;
                    }
                    if (key === 'Escape') {
                      e.preventDefault();
                      this.close();
                      if (this.trigger) this.trigger.focus();
                      return;
                    }
                    if (key === 'Tab') this.close();
                  }
                },
                QueueBoard: {
                  mounted() {
                    this._onPointerDown = this.onPointerDown.bind(this);
                    this._onPointerMove = this.onPointerMove.bind(this);
                    this._onPointerUp = this.onPointerUp.bind(this);
                    this._onKeydown = this.onKeydown.bind(this);
                    this._onMotionChange = this.onMotionChange.bind(this);
                    this._onDragStart = this.onDragStart.bind(this);
                    this.dragging = false;
                    this.pending = null;
                    this.sourceCard = null;
                    this.ghost = null;
                    this.lastBefore = undefined;
                    this.orderAtPick = [];
                    this.pointerId = null;
                    this.flipGen = 0;
                    this.ghostTimer = null;
                    this.opacityTimer = null;
                    this.flipTimer = null;
                    this.cards = [];
                    this.lastOrderAttr = this.el.getAttribute('data-order') || '';
                    this.bindMotion();
                    this.el.addEventListener('pointerdown', this._onPointerDown);
                    this.el.addEventListener('keydown', this._onKeydown);
                    this.el.addEventListener('dragstart', this._onDragStart);
                    this.refreshCards();
                  },
                  updated() {
                    this.bindMotion();
                    this.refreshCards();
                    if (this.dragging) return;
                    var attr = this.el.getAttribute('data-order') || '';
                    if (attr === this.lastOrderAttr) return;
                    this.lastOrderAttr = attr;
                    var serverOrder = this.parseOrder(attr);
                    if (!this.sameOrder(serverOrder, this.currentOrder())) {
                      this.reconcileTo(serverOrder);
                    }
                  },
                  destroyed() {
                    this.teardownDrag(true);
                    this.unbindMotion();
                    if (this.el) {
                      this.el.removeEventListener('pointerdown', this._onPointerDown);
                      this.el.removeEventListener('keydown', this._onKeydown);
                      this.el.removeEventListener('dragstart', this._onDragStart);
                    }
                    this.unbindWindow();
                    this.removeGhost();
                    this.clearTimers();
                  },
                  bindMotion() {
                    this.reducedMotion = false;
                    if (typeof window.matchMedia !== 'function') {
                      this.syncReducedClass();
                      return;
                    }
                    if (!this.motionQuery) {
                      this.motionQuery = window.matchMedia('(prefers-reduced-motion: reduce)');
                      if (this.motionQuery.addEventListener) {
                        this.motionQuery.addEventListener('change', this._onMotionChange);
                      } else if (this.motionQuery.addListener) {
                        this.motionQuery.addListener(this._onMotionChange);
                      }
                    }
                    this.reducedMotion = !!this.motionQuery.matches;
                    this.syncReducedClass();
                  },
                  unbindMotion() {
                    if (!this.motionQuery) return;
                    if (this.motionQuery.removeEventListener) {
                      this.motionQuery.removeEventListener('change', this._onMotionChange);
                    } else if (this.motionQuery.removeListener) {
                      this.motionQuery.removeListener(this._onMotionChange);
                    }
                    this.motionQuery = null;
                  },
                  onMotionChange() {
                    this.reducedMotion = !!(this.motionQuery && this.motionQuery.matches);
                    this.syncReducedClass();
                  },
                  syncReducedClass() {
                    if (this.el) this.el.classList.toggle('is-reduced-motion', !!this.reducedMotion);
                  },
                  refreshCards() {
                    this.cards = this.queryCards();
                  },
                  queryCards() {
                    return Array.prototype.filter.call(this.el.children, function(node) {
                      return node.nodeType === 1 && node.matches && node.matches('article.queue-card');
                    });
                  },
                  cardKey(card) {
                    return card ? (card.getAttribute('data-issue') || '') : '';
                  },
                  currentOrder() {
                    return this.queryCards().map(function(card) {
                      return card.getAttribute('data-issue') || '';
                    }).filter(Boolean);
                  },
                  parseOrder(raw) {
                    var text = (raw == null ? '' : String(raw)).trim();
                    if (!text) return [];
                    if (text.charAt(0) === '[') {
                      try {
                        var parsed = JSON.parse(text);
                        if (Object.prototype.toString.call(parsed) === '[object Array]') {
                          return parsed.map(function(v) { return String(v); }).filter(Boolean);
                        }
                      } catch (err) {}
                    }
                    return text.split(/[,\s]+/).map(function(part) {
                      return part.trim();
                    }).filter(Boolean);
                  },
                  sameOrder(a, b) {
                    if (!a || !b || a.length !== b.length) return false;
                    for (var i = 0; i < a.length; i++) {
                      if (a[i] !== b[i]) return false;
                    }
                    return true;
                  },
                  tokenMs(name, fallback) {
                    var value;
                    try {
                      value = window.getComputedStyle(document.documentElement).getPropertyValue(name).trim();
                    } catch (err) {
                      return fallback;
                    }
                    if (!value) return fallback;
                    var n = parseFloat(value);
                    if (isNaN(n)) return fallback;
                    if (value.indexOf('ms') !== -1) return n;
                    if (value.charAt(value.length - 1) === 's') return n * 1000;
                    return n;
                  },
                  isInteractive(target) {
                    if (!target || !target.closest) return false;
                    return !!target.closest('a, button, input, select, textarea, label, option, .queue-card-edit, .queue-edit-form, .combobox');
                  },
                  refreshRanks() {
                    var cards = this.queryCards();
                    for (var i = 0; i < cards.length; i++) {
                      cards[i].setAttribute('data-rank', String(i));
                    }
                    this.cards = cards;
                  },
                  emitOrder() {
                    var order = this.currentOrder();
                    this.pushEvent('reorder_queue', {
                      project: this.el.getAttribute('data-project') || '',
                      order: order
                    });
                  },
                  reconcileTo(desired) {
                    if (!desired || !desired.length) return;
                    var cards = this.queryCards();
                    var byKey = {};
                    var i, key, card;
                    for (i = 0; i < cards.length; i++) {
                      key = this.cardKey(cards[i]);
                      if (key) byKey[key] = cards[i];
                    }
                    if (this.sameOrder(this.currentOrder(), desired)) return;
                    var host = this.el;
                    this.flip(function() {
                      for (i = 0; i < desired.length; i++) {
                        card = byKey[desired[i]];
                        if (card) host.appendChild(card);
                      }
                    }, null);
                  },
                  clearFlipStyles() {
                    var cards = this.queryCards();
                    for (var i = 0; i < cards.length; i++) {
                      cards[i].style.transition = '';
                      cards[i].style.transform = '';
                    }
                  },
                  flip(mutate, skipEl) {
                    var cards, first, i, card, key, rect, last, dx, dy, gen, self;
                    if (this.reducedMotion) {
                      mutate();
                      this.refreshRanks();
                      return;
                    }
                    this.flipGen += 1;
                    gen = this.flipGen;
                    cards = this.queryCards();
                    first = {};
                    for (i = 0; i < cards.length; i++) {
                      card = cards[i];
                      card.style.transition = 'none';
                      card.style.transform = '';
                    }
                    this.el.offsetWidth;
                    for (i = 0; i < cards.length; i++) {
                      card = cards[i];
                      if (skipEl && card === skipEl) continue;
                      key = this.cardKey(card) || ('idx-' + i);
                      rect = card.getBoundingClientRect();
                      first[key] = {left: rect.left, top: rect.top};
                    }
                    mutate();
                    cards = this.queryCards();
                    for (i = 0; i < cards.length; i++) {
                      card = cards[i];
                      if (skipEl && card === skipEl) continue;
                      key = this.cardKey(card) || ('idx-' + i);
                      if (!first[key]) continue;
                      last = card.getBoundingClientRect();
                      dx = first[key].left - last.left;
                      dy = first[key].top - last.top;
                      if (!dx && !dy) continue;
                      card.style.transition = 'none';
                      card.style.transform = 'translate(' + dx + 'px, ' + dy + 'px)';
                    }
                    this.el.offsetWidth;
                    for (i = 0; i < cards.length; i++) {
                      card = cards[i];
                      if (skipEl && card === skipEl) continue;
                      if (!card.style.transform) continue;
                      card.style.transition = 'transform var(--dur-flip, 280ms) var(--ease, cubic-bezier(0.2, 0.8, 0.2, 1))';
                      card.style.transform = 'translate(0, 0)';
                    }
                    this.refreshRanks();
                    self = this;
                    if (this.flipTimer) window.clearTimeout(this.flipTimer);
                    this.flipTimer = window.setTimeout(function() {
                      if (self.flipGen !== gen) return;
                      self.clearFlipStyles();
                    }, this.tokenMs('--dur-flip', 280) + 30);
                  },
                  bindWindow() {
                    window.addEventListener('pointermove', this._onPointerMove, {passive: false});
                    window.addEventListener('pointerup', this._onPointerUp);
                    window.addEventListener('pointercancel', this._onPointerUp);
                  },
                  unbindWindow() {
                    window.removeEventListener('pointermove', this._onPointerMove);
                    window.removeEventListener('pointerup', this._onPointerUp);
                    window.removeEventListener('pointercancel', this._onPointerUp);
                  },
                  clearTimers() {
                    if (this.ghostTimer) window.clearTimeout(this.ghostTimer);
                    if (this.opacityTimer) window.clearTimeout(this.opacityTimer);
                    if (this.flipTimer) window.clearTimeout(this.flipTimer);
                    this.ghostTimer = null;
                    this.opacityTimer = null;
                    this.flipTimer = null;
                  },
                  removeGhost() {
                    if (this.ghost && this.ghost.parentNode) {
                      this.ghost.parentNode.removeChild(this.ghost);
                    }
                    this.ghost = null;
                  },
                  clearDragChrome() {
                    var section = this.el && this.el.closest('.project-section');
                    if (section) section.classList.remove('is-queue-dragging');
                    if (document.body) document.body.classList.remove('queue-board-dragging');
                    if (document.body) document.body.style.userSelect = '';
                  },
                  teardownDrag(immediate) {
                    var source = this.sourceCard;
                    if (source) {
                      source.classList.remove('is-dragging');
                      source.style.opacity = '';
                      source.style.transition = '';
                    }
                    this.clearDragChrome();
                    this.unbindWindow();
                    if (this.pointerId != null && this.el && this.el.releasePointerCapture) {
                      try { this.el.releasePointerCapture(this.pointerId); } catch (err) {}
                    }
                    if (immediate) this.removeGhost();
                    this.dragging = false;
                    this.pending = null;
                    this.sourceCard = null;
                    this.lastBefore = undefined;
                    this.pointerId = null;
                  },
                  onDragStart(e) {
                    if (this.pending || this.dragging) {
                      e.preventDefault();
                      return;
                    }
                    var card = e.target.closest ? e.target.closest('article.queue-card') : null;
                    if (card && this.el.contains(card) && !this.isInteractive(e.target)) e.preventDefault();
                  },
                  onPointerDown(e) {
                    if (e.button != null && e.button !== 0) return;
                    if (this.dragging || this.pending) return;
                    var card = e.target.closest ? e.target.closest('article.queue-card') : null;
                    if (!card || !this.el.contains(card)) return;
                    if (this.isInteractive(e.target)) return;
                    this.pending = {
                      card: card,
                      pointerId: e.pointerId,
                      startX: e.clientX,
                      startY: e.clientY,
                      originOrder: this.currentOrder()
                    };
                    this.bindWindow();
                  },
                  onPointerMove(e) {
                    if (this.pending && !this.dragging) {
                      var adx = e.clientX - this.pending.startX;
                      var ady = e.clientY - this.pending.startY;
                      if ((adx * adx) + (ady * ady) < 25) return;
                      this.pick(e);
                    }
                    if (!this.dragging) return;
                    if (e.cancelable) e.preventDefault();
                    this.moveGhost(e.clientX, e.clientY);
                    this.maybeReorder(e.clientX, e.clientY);
                  },
                  onPointerUp() {
                    if (this.dragging) {
                      var changed = !this.sameOrder(this.currentOrder(), this.orderAtPick || []);
                      this.drop(changed);
                      return;
                    }
                    this.pending = null;
                    this.unbindWindow();
                  },
                  pick(e) {
                    var pending = this.pending;
                    if (!pending || !pending.card || !pending.card.parentNode) {
                      this.pending = null;
                      return;
                    }
                    var card = pending.card;
                    var rect = card.getBoundingClientRect();
                    this.dragging = true;
                    this.sourceCard = card;
                    this.orderAtPick = pending.originOrder || [];
                    this.pointerId = pending.pointerId;
                    this.offsetX = e.clientX - rect.left;
                    this.offsetY = e.clientY - rect.top;
                    this.lastBefore = card.nextElementSibling;
                    this.createGhost(card, rect);
                    card.classList.add('is-dragging');
                    card.style.opacity = '0.35';
                    var section = this.el.closest('.project-section');
                    if (section) section.classList.add('is-queue-dragging');
                    if (document.body) {
                      document.body.classList.add('queue-board-dragging');
                      document.body.style.userSelect = 'none';
                    }
                    if (this.el.setPointerCapture && this.pointerId != null) {
                      try { this.el.setPointerCapture(this.pointerId); } catch (err) {}
                    }
                    if (e.cancelable) e.preventDefault();
                  },
                  createGhost(card, rect) {
                    this.removeGhost();
                    var ghost = card.cloneNode(true);
                    var nodes = ghost.querySelectorAll('[id]');
                    var i, edit;
                    ghost.removeAttribute('id');
                    ghost.classList.remove('is-dragging', 'is-editing', 'is-combobox-open');
                    ghost.classList.add('queue-drag-ghost');
                    ghost.setAttribute('aria-hidden', 'true');
                    ghost.tabIndex = -1;
                    for (i = 0; i < nodes.length; i++) nodes[i].removeAttribute('id');
                    edit = ghost.querySelector('.queue-card-edit');
                    if (edit && edit.parentNode) edit.parentNode.removeChild(edit);
                    ghost.style.position = 'fixed';
                    ghost.style.left = rect.left + 'px';
                    ghost.style.top = rect.top + 'px';
                    ghost.style.width = rect.width + 'px';
                    ghost.style.height = rect.height + 'px';
                    ghost.style.margin = '0';
                    ghost.style.boxSizing = 'border-box';
                    ghost.style.pointerEvents = 'none';
                    ghost.style.zIndex = 'var(--z-drag)';
                    ghost.style.boxShadow = 'var(--shadow-drag)';
                    ghost.style.backgroundColor = 'var(--accent-soft)';
                    ghost.style.opacity = '1';
                    ghost.style.transform = 'scale(1)';
                    ghost.style.transition = 'none';
                    document.body.appendChild(ghost);
                    this.ghost = ghost;
                    if (!this.reducedMotion) {
                      ghost.style.transition = 'transform var(--dur-fast, 140ms) var(--ease, cubic-bezier(0.2, 0.8, 0.2, 1))';
                      ghost.offsetWidth;
                      ghost.style.transform = 'scale(1.03)';
                    }
                  },
                  moveGhost(x, y) {
                    if (!this.ghost) return;
                    this.ghost.style.left = (x - this.offsetX) + 'px';
                    this.ghost.style.top = (y - this.offsetY) + 'px';
                  },
                  cardBeforePoint(x, y) {
                    var cards = this.queryCards();
                    var source = this.sourceCard;
                    var board = this.el.getBoundingClientRect();
                    var i, card, r, midX, midY, full;
                    for (i = 0; i < cards.length; i++) {
                      card = cards[i];
                      if (card === source) continue;
                      r = card.getBoundingClientRect();
                      midX = r.left + r.width / 2;
                      midY = r.top + r.height / 2;
                      full = r.width > board.width * 0.6;
                      if (y < r.top) return card;
                      if (full) {
                        if (y < midY) return card;
                      } else if (y <= r.bottom && x < midX) {
                        return card;
                      }
                    }
                    return null;
                  },
                  maybeReorder(x, y) {
                    var source = this.sourceCard;
                    if (!source) return;
                    var before = this.cardBeforePoint(x, y);
                    if (before === this.lastBefore) return;
                    if (!before && this.el.lastElementChild === source) {
                      this.lastBefore = before;
                      return;
                    }
                    if (before && source.nextElementSibling === before) {
                      this.lastBefore = before;
                      return;
                    }
                    this.lastBefore = before;
                    var host = this.el;
                    this.flip(function() {
                      if (before && host.contains(before)) host.insertBefore(source, before);
                      else host.appendChild(source);
                    }, source);
                  },
                  drop(changed) {
                    var self = this;
                    var source = this.sourceCard;
                    var ghost = this.ghost;
                    var mid = this.tokenMs('--dur-mid', 220);
                    if (source) {
                      source.classList.remove('is-dragging');
                      if (this.reducedMotion) {
                        source.style.opacity = '';
                        source.style.transition = '';
                      } else {
                        source.style.transition = 'opacity var(--dur-mid, 220ms) var(--ease-spring, cubic-bezier(0.22, 1.15, 0.36, 1))';
                        source.style.opacity = '1';
                        if (this.opacityTimer) window.clearTimeout(this.opacityTimer);
                        this.opacityTimer = window.setTimeout(function() {
                          source.style.opacity = '';
                          source.style.transition = '';
                        }, mid + 20);
                      }
                    }
                    if (ghost) {
                      if (this.reducedMotion) {
                        this.removeGhost();
                      } else {
                        ghost.style.transition = 'transform var(--dur-mid, 220ms) var(--ease-spring, cubic-bezier(0.22, 1.15, 0.36, 1)), opacity var(--dur-mid, 220ms) var(--ease-spring, cubic-bezier(0.22, 1.15, 0.36, 1))';
                        ghost.style.transform = 'scale(1)';
                        ghost.style.opacity = '0';
                        if (this.ghostTimer) window.clearTimeout(this.ghostTimer);
                        this.ghostTimer = window.setTimeout(function() { self.removeGhost(); }, mid + 20);
                      }
                    }
                    this.clearDragChrome();
                    this.unbindWindow();
                    if (this.pointerId != null && this.el && this.el.releasePointerCapture) {
                      try { this.el.releasePointerCapture(this.pointerId); } catch (err) {}
                    }
                    this.dragging = false;
                    this.pending = null;
                    this.sourceCard = null;
                    this.lastBefore = undefined;
                    this.pointerId = null;
                    this.refreshRanks();
                    if (changed) this.emitOrder();
                  },
                  onKeydown(e) {
                    if (this.dragging) return;
                    var card = e.target.closest ? e.target.closest('article.queue-card') : null;
                    if (!card || !this.el.contains(card)) return;
                    if (this.isInteractive(e.target)) return;
                    var dir = 0;
                    if (e.key === 'ArrowLeft' || e.key === '[') dir = -1;
                    else if (e.key === 'ArrowRight' || e.key === ']') dir = 1;
                    else return;
                    e.preventDefault();
                    this.nudge(card, dir);
                  },
                  nudge(card, dir) {
                    var cards = this.queryCards();
                    var index = cards.indexOf(card);
                    if (index < 0) return;
                    var next = index + dir;
                    if (next < 0 || next >= cards.length) return;
                    var host = this.el;
                    var target = cards[next];
                    this.flip(function() {
                      if (dir > 0) host.insertBefore(card, target.nextSibling);
                      else host.insertBefore(card, target);
                    }, null);
                    this.emitOrder();
                    if (card.focus) card.focus();
                  }
                },
                QueueEditPanel: {
                  mounted() {
                    this._place = this.place.bind(this);
                    this._onDoc = this.onDoc.bind(this);
                    this.place();
                    window.addEventListener('resize', this._place);
                    window.addEventListener('scroll', this._place, true);
                    document.addEventListener('mousedown', this._onDoc, true);
                    document.documentElement.removeAttribute('data-drawer');
                  },
                  updated() { this.place(); },
                  destroyed() {
                    window.removeEventListener('resize', this._place);
                    window.removeEventListener('scroll', this._place, true);
                    document.removeEventListener('mousedown', this._onDoc, true);
                  },
                  onDoc(e) {
                    var t = e.target;
                    if (!t || !t.closest) return;
                    if (this.el.contains(t)) return;
                    if (t.closest('.queue-card-edit-toggle')) return;
                    if (t.closest('.combobox-list') || t.closest('.combobox-panel')) return;
                    document.documentElement.removeAttribute('data-drawer');
                    this.pushEvent('dismiss_overlays', {});
                  },
                  place() {
                    var card = this.el.closest('.queue-card');
                    if (!card) return;
                    var r = card.getBoundingClientRect();
                    var width = Math.min(Math.max(r.width, 304), Math.min(360, window.innerWidth - 24));
                    var left = Math.min(Math.max(12, r.left), window.innerWidth - width - 12);
                    this.el.style.position = 'fixed';
                    this.el.style.left = left + 'px';
                    this.el.style.width = width + 'px';
                    this.el.style.right = 'auto';
                    var below = r.bottom + 8;
                    var h = this.el.offsetHeight || 240;
                    if (below + h > window.innerHeight - 12 && r.top - h - 8 > 12) {
                      this.el.style.top = (r.top - h - 8) + 'px';
                    } else {
                      this.el.style.top = below + 'px';
                    }
                  }
                },
                OverlayDismiss: {
                  mounted() {
                    this._onDoc = this.onDoc.bind(this);
                    document.addEventListener('mousedown', this._onDoc, true);
                  },
                  destroyed() {
                    document.removeEventListener('mousedown', this._onDoc, true);
                  },
                  keepOpen(target) {
                    if (!target || !target.closest) return false;
                    if (target.closest('.settings-drawer')) return true;
                    if (target.closest('.queue-card-edit')) return true;
                    if (target.closest('.combobox-list')) return true;
                    if (target.closest('.combobox-panel')) return true;
                    if (target.closest('.combobox.combobox--open')) return true;
                    return false;
                  },
                  onDoc(e) {
                    var target = e.target;
                    if (target && target.closest && target.closest('[data-drawer-toggle]')) {
                      this.pushEvent('dismiss_overlays', {});
                      return;
                    }
                    if (target && target.closest && target.closest('.queue-card-edit-toggle')) {
                      document.documentElement.removeAttribute('data-drawer');
                      return;
                    }
                    if (this.keepOpen(target)) return;
                    document.documentElement.removeAttribute('data-drawer');
                    this.pushEvent('dismiss_overlays', {});
                  }
                }
              }
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;

            // Theme toggle wiring (delegated, so it survives LiveView re-renders).
            function applyTheme(value) {
              if (value === 'system') {
                document.documentElement.removeAttribute('data-theme');
                try { localStorage.removeItem('cymphony-theme'); } catch (e) {}
              } else if (value === 'dark' || value === 'light') {
                document.documentElement.setAttribute('data-theme', value);
                try { localStorage.setItem('cymphony-theme', value); } catch (e) {}
              }
            }

            // Display prefs wiring: localStorage 'cymphony-prefs' <-> data-*
            // attributes on <html>. Attributes live outside the LiveView
            // container, so DOM patches never clobber them; CSS keys off them.
            function readPrefs() {
              try { return JSON.parse(localStorage.getItem('cymphony-prefs') || '{}'); } catch (e) { return {}; }
            }

            function writePrefs(prefs) {
              try { localStorage.setItem('cymphony-prefs', JSON.stringify(prefs)); } catch (e) {}
            }

            function applyMode(value) {
              var mode = value === 'advanced' ? 'advanced' : 'simple';
              var prefs = readPrefs();
              prefs.uiMode = mode;
              document.documentElement.setAttribute('data-ui-mode', mode);
              writePrefs(prefs);
              syncPrefControls();
            }

            function setToken(attr, key, on) {
              var html = document.documentElement;
              var tokens = (html.getAttribute(attr) || '').split(' ').filter(Boolean);
              var idx = tokens.indexOf(key);
              if (on && idx === -1) tokens.push(key);
              if (!on && idx !== -1) tokens.splice(idx, 1);
              if (tokens.length) html.setAttribute(attr, tokens.join(' '));
              else html.removeAttribute(attr);
              return tokens;
            }

            function prefTokens(prefs, key) {
              if (key === 'expandedSections' &&
                  !Object.prototype.hasOwnProperty.call(prefs, key) &&
                  Object.prototype.hasOwnProperty.call(prefs, 'collapsedSections') &&
                  Array.isArray(prefs.collapsedSections) &&
                  prefs.collapsedSections.length === 0) {
                return ['completions'];
              }

              return Array.isArray(prefs[key]) ? prefs[key] : [];
            }

            function sectionIsCollapsed(key, prefs) {
              if (prefTokens(prefs, 'collapsedSections').indexOf(key) !== -1) return true;
              if (prefTokens(prefs, 'expandedSections').indexOf(key) !== -1) return false;

              var mode = document.documentElement.getAttribute('data-ui-mode') || 'simple';
              return mode === 'simple' && key === 'completions';
            }

            function syncPrefControls() {
              var prefs = readPrefs();
              var mode = document.documentElement.getAttribute('data-ui-mode') || 'simple';
              document.querySelectorAll('[data-mode-set]').forEach(function(el) {
                var pressed = el.getAttribute('data-mode-set') === mode ? 'true' : 'false';
                if (el.getAttribute('aria-pressed') !== pressed) el.setAttribute('aria-pressed', pressed);
              });
              document.querySelectorAll('[data-pref="density"]').forEach(function(el) {
                el.checked = (prefs.density || 'comfortable') === el.value;
              });
              document.querySelectorAll('[data-pref-section]').forEach(function(el) {
                el.checked = (prefs.hiddenSections || []).indexOf(el.getAttribute('data-pref-section')) === -1;
              });
              document.querySelectorAll('[data-pref-col]').forEach(function(el) {
                el.checked = (prefs.hiddenCols || []).indexOf(el.getAttribute('data-pref-col')) === -1;
              });
              document.querySelectorAll('[data-pref="completions-limit"]').forEach(function(el) {
                el.value = prefs.completionsLimit || '100';
              });
              document.querySelectorAll('[data-collapse-toggle]').forEach(function(el) {
                var collapsed = sectionIsCollapsed(el.getAttribute('data-collapse-toggle'), prefs);
                var marker = collapsed ? '▸' : '▾';
                if (el.textContent !== marker) el.textContent = marker;
                el.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
                el.setAttribute('aria-label', collapsed ? 'Expand section' : 'Collapse section');
              });
            }

            document.addEventListener('click', function(e) {
              var target = e.target.closest('[data-theme-set]');
              if (target) {
                applyTheme(target.getAttribute('data-theme-set'));
                return;
              }

              var modeTarget = e.target.closest('[data-mode-set]');
              if (modeTarget) {
                applyMode(modeTarget.getAttribute('data-mode-set'));
                return;
              }

              var drawerToggle = e.target.closest('[data-drawer-toggle]');
              if (drawerToggle) {
                var html = document.documentElement;
                var open = html.getAttribute('data-drawer') === 'open';
                if (open) html.removeAttribute('data-drawer');
                else html.setAttribute('data-drawer', 'open');
                if (!open) syncPrefControls();
                return;
              }

              var collapse = e.target.closest('[data-collapse-toggle]');
              if (collapse) {
                var key = collapse.getAttribute('data-collapse-toggle');
                var prefs = readPrefs();
                var wasCollapsed = sectionIsCollapsed(key, prefs);
                var collapsed = prefTokens(prefs, 'collapsedSections');
                var expanded = prefTokens(prefs, 'expandedSections');

                if (wasCollapsed) {
                  collapsed = collapsed.filter(function(k) { return k !== key; });
                  if (expanded.indexOf(key) === -1) expanded = expanded.concat([key]);
                } else {
                  if (collapsed.indexOf(key) === -1) collapsed = collapsed.concat([key]);
                  expanded = expanded.filter(function(k) { return k !== key; });
                }

                prefs.collapsedSections = collapsed;
                prefs.expandedSections = expanded;
                writePrefs(prefs);
                setToken('data-collapsed-sections', key, collapsed.indexOf(key) !== -1);
                setToken('data-expanded-sections', key, expanded.indexOf(key) !== -1);
                syncPrefControls();
              }
            });

            document.addEventListener('change', function(e) {
              var html = document.documentElement;
              var prefs = readPrefs();

              if (e.target.matches('[data-pref="density"]')) {
                prefs.density = e.target.value;
                if (prefs.density === 'compact') html.setAttribute('data-density', 'compact');
                else html.removeAttribute('data-density');
              } else if (e.target.matches('[data-pref-section]')) {
                prefs.hiddenSections = setToken('data-hidden-sections', e.target.getAttribute('data-pref-section'), !e.target.checked);
              } else if (e.target.matches('[data-pref-col]')) {
                prefs.hiddenCols = setToken('data-hidden-cols', e.target.getAttribute('data-pref-col'), !e.target.checked);
              } else if (e.target.matches('[data-pref="completions-limit"]')) {
                prefs.completionsLimit = e.target.value;
                if (prefs.completionsLimit === '100') html.removeAttribute('data-completions-limit');
                else html.setAttribute('data-completions-limit', prefs.completionsLimit);
              } else {
                return;
              }

              writePrefs(prefs);
            });

            syncPrefControls();
            window.addEventListener('phx:page-loading-stop', syncPrefControls);

            var liveRoot = document.querySelector('[data-phx-main]');
            if (liveRoot && window.MutationObserver) {
              new MutationObserver(syncPrefControls).observe(liveRoot, {
                attributes: true,
                attributeFilter: ['aria-pressed'],
                childList: true,
                subtree: true
              });
            }
          })();
        </script>
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
