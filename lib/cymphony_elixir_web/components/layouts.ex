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
            try {
              var t = localStorage.getItem('cymphony-theme');
              if (t === 'dark' || t === 'light') {
                document.documentElement.setAttribute('data-theme', t);
              }
            } catch (e) {}

            try {
              var prefs = JSON.parse(localStorage.getItem('cymphony-prefs') || '{}');
              var html = document.documentElement;
              if (prefs.density === 'compact') html.setAttribute('data-density', 'compact');
              if (prefs.hiddenSections && prefs.hiddenSections.length) {
                html.setAttribute('data-hidden-sections', prefs.hiddenSections.join(' '));
              }
              if (prefs.collapsedSections && prefs.collapsedSections.length) {
                html.setAttribute('data-collapsed-sections', prefs.collapsedSections.join(' '));
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
              params: {_csrf_token: csrfToken}
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

            function syncPrefControls() {
              var prefs = readPrefs();
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
            }

            document.addEventListener('click', function(e) {
              var target = e.target.closest('[data-theme-set]');
              if (target) {
                applyTheme(target.getAttribute('data-theme-set'));
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
                var collapsed = prefs.collapsedSections || [];
                var now = collapsed.indexOf(key) !== -1
                  ? collapsed.filter(function(k) { return k !== key; })
                  : collapsed.concat([key]);
                prefs.collapsedSections = now;
                writePrefs(prefs);
                setToken('data-collapsed-sections', key, now.indexOf(key) !== -1);
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
