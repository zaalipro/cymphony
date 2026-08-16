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
                Combobox: {
                  mounted() {
                    this._onInput = this.onInput.bind(this);
                    this._onKeydown = this.onKeydown.bind(this);
                    this._onPointer = this.onPointer.bind(this);
                    this._onDocPointer = this.onDocPointer.bind(this);
                    this._onFocus = this.onFocus.bind(this);
                    this.open = false;
                    this.activeIndex = -1;
                    this.options = [];
                    this.visibleOptions = [];
                    this.bind();
                    this.cacheOptions();
                    this.close();
                  },
                  updated() {
                    this.bind();
                    this.cacheOptions();
                    if (this.el.contains(document.activeElement)) {
                      this.filter(this.input ? this.input.value : '');
                    } else {
                      this.close();
                    }
                  },
                  destroyed() {
                    this.unbind();
                  },
                  queryParts() {
                    this.input = this.el.querySelector('.combobox-input');
                    this.hidden = this.el.querySelector('input[type="hidden"]');
                    this.list = this.el.querySelector('ul[role="listbox"]');
                  },
                  bind() {
                    this.unbind();
                    this.queryParts();
                    if (this.input) {
                      this.input.addEventListener('input', this._onInput);
                      this.input.addEventListener('keydown', this._onKeydown);
                      this.input.addEventListener('focus', this._onFocus);
                      this.input.addEventListener('click', this._onFocus);
                    }
                    this.el.addEventListener('mousedown', this._onPointer);
                    this.el.addEventListener('click', this._onPointer);
                    document.addEventListener('mousedown', this._onDocPointer);
                  },
                  unbind() {
                    if (this.input) {
                      this.input.removeEventListener('input', this._onInput);
                      this.input.removeEventListener('keydown', this._onKeydown);
                      this.input.removeEventListener('focus', this._onFocus);
                      this.input.removeEventListener('click', this._onFocus);
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
                    return opt ? (opt.textContent || '') : '';
                  },
                  syncHidden() {
                    if (this.hidden && this.input) this.hidden.value = this.input.value;
                  },
                  notifyHidden() {
                    if (!this.hidden) return;
                    this.hidden.dispatchEvent(new Event('input', {bubbles: true}));
                    this.hidden.dispatchEvent(new Event('change', {bubbles: true}));
                  },
                  setOpen(open) {
                    this.open = !!open;
                    if (this.list) this.list.hidden = !this.open;
                    if (this.input) {
                      this.input.setAttribute('aria-expanded', this.open ? 'true' : 'false');
                      if (!this.open) this.input.removeAttribute('aria-activedescendant');
                    }
                    if (!this.open) this.clearActive();
                  },
                  close() {
                    this.setOpen(false);
                  },
                  clearActive() {
                    this.activeIndex = -1;
                    (this.options || []).forEach(function(opt) {
                      opt.setAttribute('aria-selected', 'false');
                    });
                    if (this.input) this.input.removeAttribute('aria-activedescendant');
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
                    vis.forEach(function(opt, i) {
                      opt.setAttribute('aria-selected', i === index ? 'true' : 'false');
                    });
                    if (this.input) {
                      if (active && active.id) this.input.setAttribute('aria-activedescendant', active.id);
                      else this.input.removeAttribute('aria-activedescendant');
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
                    this.setOpen(true);
                  },
                  moveActive(delta) {
                    if (!this.open) this.filter(this.input ? this.input.value : '');
                    var vis = this.visibleOptions || [];
                    if (!vis.length) return;
                    var next;
                    if (this.activeIndex < 0) next = delta > 0 ? 0 : vis.length - 1;
                    else next = this.activeIndex + delta;
                    this.setActive(next);
                  },
                  onInput() {
                    this.syncHidden();
                    this.filter(this.input ? this.input.value : '');
                  },
                  onFocus() {
                    this.filter(this.input ? this.input.value : '');
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
                  commitOption(opt) {
                    var value = this.optionValue(opt);
                    if (this.input) this.input.value = value;
                    if (this.hidden) this.hidden.value = value;
                    this.notifyHidden();
                    this.close();
                  },
                  commitText() {
                    this.syncHidden();
                    this.close();
                  },
                  onKeydown(e) {
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
                      else this.commitText();
                      return;
                    }
                    if (key === 'Escape') {
                      if (!this.open) return;
                      e.preventDefault();
                      this.close();
                      return;
                    }
                    if (key === 'Tab') this.commitText();
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
