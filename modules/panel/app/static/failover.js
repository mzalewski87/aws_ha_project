// Failover page: live topology, progress of the current run (phases, timeline, metrics), history.
// Builds every element with DOM APIs (no innerHTML), so values from the server are never parsed as HTML.
(function () {
  'use strict';
  var NS = 'http://www.w3.org/2000/svg';
  var META = JSON.parse(document.getElementById('fo-data').textContent);

  function $(id) { return document.getElementById(id); }
  function h(tag, attrs, text) {
    var e = document.createElement(tag);
    Object.keys(attrs || {}).forEach(function (k) { e.setAttribute(k, attrs[k]); });
    if (text !== undefined && text !== null) e.textContent = text;
    return e;
  }
  function s(tag, attrs, text) {
    var e = document.createElementNS(NS, tag);
    Object.keys(attrs || {}).forEach(function (k) { e.setAttribute(k, attrs[k]); });
    if (text !== undefined && text !== null) e.textContent = text;
    return e;
  }
  function clear(e) { while (e.firstChild) e.removeChild(e.firstChild); }
  function fmt(v, unit) { return (v === undefined || v === null) ? '–' : (v + (unit || '')); }
  function clock(ts) { return new Date(ts * 1000).toLocaleTimeString(); }

  // ---- live topology -------------------------------------------------------------------
  function stateClass(u) {
    var st = (u.state || '').toLowerCase();
    if (u.ec2 && u.ec2 !== 'running') return 'bad';
    if (st.indexOf('active') === 0) return 'live';
    if (st === 'passive') return 'standby';
    if (st === 'suspended' || st === 'initial' || st === 'non-functional') return 'warn';
    return 'bad';
  }

  function box(svg, x, y, w, hgt, cls, lines) {
    svg.appendChild(s('rect', {x: x, y: y, width: w, height: hgt, rx: 10, 'class': 'node ' + (cls || '')}));
    lines.forEach(function (ln, i) {
      svg.appendChild(s('text', {x: x + w / 2, y: y + 22 + i * 18, 'text-anchor': 'middle', 'class': ln[1] || ''}, ln[0]));
    });
  }

  function drawTopology(t) {
    var svg = $('topo');
    clear(svg);
    var keys = Object.keys(t.pairs || {}).sort();
    var multi = keys.length > 1;
    var ROW = 330, TOP = 24;
    var H = TOP + keys.length * ROW;
    svg.setAttribute('viewBox', '0 0 960 ' + H);
    var midY = H / 2;

    // per-region rows first (edges under boxes), the client side last
    var regionUp = {};
    keys.forEach(function (key, r) {
      var p = t.pairs[key], oy = TOP + r * ROW;
      var names = Object.keys(p.units).sort();
      var pos = {};
      names.forEach(function (n, i) { pos[n] = {x: 455, y: oy + (i === 0 ? 0 : 180)}; });
      var routeCount = {};
      (p.routes || []).forEach(function (rt) { routeCount[rt.unit] = (routeCount[rt.unit] || 0) + 1; });
      var routeUnit = names.filter(function (n) { return routeCount[n]; })[0];
      var isUp = function (n) { return !!n && stateClass(p.units[n]) === 'live'; };
      var active = names.filter(isUp)[0];
      // AWS keeps pointing the EIP and the routes at a unit that is stopped; that is not traffic.
      var eipUp = isUp(p.eip_holder), routeUp = isUp(routeUnit);
      regionUp[key] = !!(active && eipUp);
      var eipY = oy + 120;

      names.forEach(function (n) {
        var q = pos[n];
        svg.appendChild(s('path', {d: 'M430,' + (eipY + 35) + ' C445,' + (eipY + 35) + ' 440,' + (q.y + 60) + ' 455,' + (q.y + 60),
          'class': 'edge ' + (p.eip_holder === n ? (isUp(n) ? 'live' : 'bad') : '')}));
        svg.appendChild(s('path', {d: 'M670,' + (q.y + 60) + ' C690,' + (q.y + 60) + ' 690,' + (eipY + 40) + ' 720,' + (eipY + 40),
          'class': 'edge ' + (routeUnit === n ? (isUp(n) ? 'live' : 'bad') : '')}));
      });
      if (names.length === 2) {
        var a = p.units[names[0]], b = p.units[names[1]];
        var synced = a.config_sync === 'synchronized' && b.config_sync === 'synchronized';
        svg.appendChild(s('path', {d: 'M562,' + (oy + 120) + ' L562,' + (oy + 180), 'class': 'edge ' + (synced ? 'ok' : 'bad')}));
        svg.appendChild(s('text', {x: 572, y: oy + 147, 'class': 'small'}, 'HA1 / HA2'));
        svg.appendChild(s('text', {x: 572, y: oy + 163, 'class': 'small'}, synced ? 'config synchronized' : 'config NOT synchronized'));
      }
      svg.appendChild(s('text', {x: 300, y: oy + 14, 'class': 'big'}, p.label));
      svg.appendChild(s('text', {x: 300, y: oy + 32, 'class': 'small'}, p.region));
      box(svg, 300, eipY, 130, 70, eipUp ? 'live' : 'bad',
        [['Public EIP', ''], [p.public_ip || '', 'small'],
         [p.eip_holder ? ('\u2192 ' + p.eip_holder + (eipUp ? '' : ' (down)')) : 'not attached', 'small']]);
      names.forEach(function (n) {
        var u = p.units[n], q = pos[n];
        var pref = names.slice().sort(function (x, y) {
          return (parseInt(p.units[x].priority, 10) || 1e6) - (parseInt(p.units[y].priority, 10) || 1e6);
        })[0] === n;
        box(svg, q.x, q.y, 215, 120, stateClass(u), [
          [n + '  \u00b7  ' + u.ip, ''],
          [(u.state || 'unknown').toUpperCase(), 'big'],
          ['EC2 ' + (u.ec2 || '?') + '  \u00b7  sync ' + (u.config_sync || '?'), 'small'],
          ['priority ' + (u.priority || '?') + (pref ? '  \u00b7  preferred' : ''), 'small'],
          [(p.eip_holder === n ? 'holds the EIP' : '') + (routeCount[n] ? ((p.eip_holder === n ? ' \u00b7 ' : '') + routeCount[n] + ' route(s)') : ''), 'small']
        ]);
      });
      box(svg, 720, eipY, 230, 80, routeUp ? 'live' : 'bad',
        [['Transit Gateway', ''], ['spokes: DC, apps, GP pool', 'small'],
         [routeUnit ? ((routeUp ? 'inspection via ' : 'routes point at DOWN ') + routeUnit) : 'no route to a firewall', 'small']]);
    });

    // client side: clients -> (Global Accelerator) -> each region's EIP
    var gpCls = t.gp_up === false ? 'bad' : (t.gp_up ? 'live' : '');
    if (multi) {
      // Global Accelerator does NOT split traffic and has no priority: with both endpoint groups
      // at 100 % traffic dial each client goes to the NEAREST HEALTHY region. Shown here: the
      // region that serves clients near this panel (Poland -> eu-central-1), the other healthy
      // region as standby (it serves clients nearer to it and takes over on failure).
      var ga = t.ga || {groups: {}};
      var noGa = !t.ga;
      // A region whose active firewall is down is not serving, whatever GA still reports during
      // its detection lag (plus the panel's 15 s cache of the GA API).
      var gaHealthy = function (key) {
        var g = ga.groups[t.pairs[key].region];
        return regionUp[key] && (g ? g.health === 'HEALTHY' : true);
      };
      var home = keys.filter(function (k) { return t.pairs[k].region === ga.home && gaHealthy(k); })[0] ||
                 keys.filter(gaHealthy)[0];
      keys.forEach(function (key, r) {
        var eipY = TOP + r * ROW + 120;
        var cls = !gaHealthy(key) ? 'bad' : (key === home ? 'live' : 'standby');
        svg.appendChild(s('path', {d: 'M285,' + midY + ' C292,' + midY + ' 292,' + (eipY + 35) + ' 300,' + (eipY + 35),
          'class': 'edge ' + cls}));
        var g = ga.groups[t.pairs[key].region];
        svg.appendChild(s('text', {x: 300, y: TOP + r * ROW + 50, 'class': 'small'},
          noGa ? 'no Global Accelerator' : ('GA: ' + (g ? g.health : 'n/a') + (regionUp[key] ? '' : ' (firewalls down)'))));
        svg.appendChild(s('text', {x: 300, y: TOP + r * ROW + 66, 'class': 'small'},
          !gaHealthy(key) ? 'not serving'
            : (key === home ? (noGa || t.pairs[key].region === ga.home ? 'serving (nearest)' : 'serving (failover)') : 'standby')));
      });
      svg.appendChild(s('path', {d: 'M150,' + midY + ' L165,' + midY, 'class': 'edge ' + (t.gp_up === false ? 'bad' : 'live')}));
      box(svg, 165, midY - 55, 120, 110, gpCls, [['Global', ''], ['Accelerator', ''], ['nearest healthy', 'small'], ['region wins', 'small']]);
    } else if (keys.length) {
      var y1 = TOP + 120 + 35;
      svg.appendChild(s('path', {d: 'M150,' + midY + ' C220,' + midY + ' 220,' + y1 + ' 300,' + y1, 'class': 'edge ' + (t.gp_up === false ? 'bad' : 'live')}));
    }
    box(svg, 10, midY - 45, 140, 90, gpCls,
      [['GP clients', ''], [t.gp_fqdn || 'portal', 'small'], [t.gp_up === null ? 'portal: n/a' : ('portal ' + (t.gp_up ? 'UP' : 'DOWN')), 'big']]);

    var note = 'Updated ' + clock(t.ts) + '.';
    if (t.errors && t.errors.length) note += ' ' + t.errors.join(' ');
    $('topo-note').textContent = note;
  }

  // ---- current run ---------------------------------------------------------------------
  function timeline(j) {
    var W = 900, H = 96, L = 10, R = 10;
    var span = Math.max(j.elapsed || 0, 30);
    var x = function (t) { return L + (W - L - R) * Math.min(t, span) / span; };
    var svg = s('svg', {viewBox: '0 0 ' + W + ' ' + H, 'class': 'diagram', role: 'img', 'aria-label': 'Timeline'});
    svg.appendChild(s('rect', {x: L, y: 34, width: W - L - R, height: 20, rx: 4, 'class': 'node live'}));
    ((j.probe && j.probe.outages) || []).forEach(function (o) {
      svg.appendChild(s('rect', {x: x(o[0]), y: 34, width: Math.max(2, x(o[1]) - x(o[0])), height: 20, 'class': 'node bad'}));
    });
    var step = span > 600 ? 120 : span > 240 ? 60 : span > 90 ? 30 : 10;
    for (var t = 0; t <= span; t += step) {
      svg.appendChild(s('line', {x1: x(t), x2: x(t), y1: 56, y2: 62, stroke: 'currentColor', 'stroke-width': 1}));
      svg.appendChild(s('text', {x: x(t), y: 76, 'text-anchor': 'middle', 'class': 'small'}, t + 's'));
    }
    (j.marks || []).forEach(function (m, i) {
      svg.appendChild(s('line', {x1: x(m.t), x2: x(m.t), y1: 14, y2: 56, stroke: 'currentColor', 'stroke-width': 1.5}));
      svg.appendChild(s('text', {x: x(m.t), y: 11, 'text-anchor': 'middle', 'class': 'small'}, String(i + 1)));
    });
    svg.appendChild(s('text', {x: W - R, y: 92, 'text-anchor': 'end', 'class': 'small'},
      'GlobalProtect portal: green = reachable, red = unreachable'));
    return svg;
  }

  function drawRun(d) {
    var box = $('run');
    clear(box);
    var j = d.job;
    if (!j) { box.appendChild(h('p', {'class': 'muted'}, 'No test has been run yet.')); return; }
    var sc = META.scenarios[j.scenario] || {label: j.scenario, typical: 60};
    var head = h('p');
    head.appendChild(h('b', {}, sc.label + ((j.options && j.options.pair_label) ? (' \u2014 ' + j.options.pair_label) : '') + ' '));
    head.appendChild(h('span', {'class': 'badge ' + j.status}, j.status));
    head.appendChild(h('span', {'class': 'muted'}, '  started ' + clock(j.started) + ' by ' + j.user +
      ', ' + j.elapsed + 's' + (j.status === 'running' ? (' (typically ' + Math.max(1, Math.floor(sc.typical / 60)) + ' min)') : '')));
    box.appendChild(head);

    var phases = j.phases || [];
    var ol = h('ol', {'class': 'phases'});
    phases.forEach(function (p, i) {
      var cls = i < j.phase ? 'done' : (i === j.phase ? (j.status === 'running' ? 'current' : (j.status === 'done' ? 'done' : 'failed')) : '');
      ol.appendChild(h('li', {'class': cls}, p));
    });
    box.appendChild(ol);
    var pct = phases.length ? Math.round(100 * Math.min(j.phase + (j.status === 'running' ? 0.5 : 0), phases.length) / phases.length) : 0;
    if (j.status !== 'running') pct = j.status === 'done' ? 100 : pct;
    var bar = h('div', {'class': 'bar ' + (j.status === 'running' ? '' : j.status)});
    bar.appendChild(h('div', {style: 'width:' + pct + '%'}));
    box.appendChild(bar);

    var r = j.result || {}, p = j.probe || {};
    var met = h('div', {'class': 'metrics'});
    [[fmt(r.takeover_s, ' s'), 'takeover (peer active)'], [fmt(r.failback_s, ' s'), 'failback to preferred'],
     [fmt(p.total_outage_s, ' s'), 'portal unreachable, total'], [fmt(p.longest_outage_s, ' s'), 'longest single outage'],
     [fmt(p.checks), 'portal checks (1/s)']].forEach(function (m) {
      var c = h('div', {'class': 'metric'});
      c.appendChild(h('b', {}, m[0]));
      c.appendChild(h('span', {}, m[1]));
      met.appendChild(c);
    });
    box.appendChild(met);
    box.appendChild(timeline(j));
    if ((j.marks || []).length) {
      var lg = h('ol', {'class': 'legend'});
      j.marks.forEach(function (m) { lg.appendChild(h('li', {}, '+' + m.t + 's  ' + m.label)); });
      box.appendChild(lg);
    }
    var det = h('details', j.status === 'running' ? {open: ''} : {});
    det.appendChild(h('summary', {}, 'Step log (' + (j.steps || []).length + ')'));
    var ul = h('ul', {'class': 'steps'});
    (j.steps || []).forEach(function (st) { ul.appendChild(h('li', {'class': st.level}, '+' + st.t + 's  ' + st.msg)); });
    det.appendChild(ul);
    box.appendChild(det);
    if (j.status === 'interrupted') {
      box.appendChild(h('p', {'class': 'err'}, 'The panel host running this test went away. Check the topology above and use Recover if needed.'));
    }
  }

  // ---- history -------------------------------------------------------------------------
  function drawHistory(d) {
    var box = $('history');
    clear(box);
    if (!d.runs || !d.runs.length) { box.appendChild(h('p', {'class': 'muted'}, 'No runs stored yet.')); return; }
    var t = h('table', {'class': 'hist'});
    var tr = h('tr');
    ['Started', 'Region', 'Test', 'By', 'Result', 'Duration', 'Takeover', 'Failback', 'Portal down (total / longest)'].forEach(function (c) { tr.appendChild(h('th', {}, c)); });
    t.appendChild(tr);
    d.runs.forEach(function (r) {
      var row = h('tr');
      row.appendChild(h('td', {}, new Date(r.started * 1000).toLocaleString()));
      row.appendChild(h('td', {}, r.pair || ''));
      row.appendChild(h('td', {}, r.scenario + (r.restore === false ? ' (no failback)' : '')));
      row.appendChild(h('td', {}, r.user));
      var st = h('td');
      st.appendChild(h('span', {'class': 'badge ' + r.status}, r.status));
      row.appendChild(st);
      row.appendChild(h('td', {}, fmt(r.elapsed, ' s')));
      row.appendChild(h('td', {}, fmt(r.takeover_s, ' s')));
      row.appendChild(h('td', {}, fmt(r.failback_s, ' s')));
      row.appendChild(h('td', {}, fmt(r.outage_total_s, ' s') + ' / ' + fmt(r.outage_longest_s, ' s')));
      t.appendChild(row);
    });
    box.appendChild(t);
  }

  // ---- form: the failback option only applies to tests that change the roles -----------------
  var form = $('run-form');
  if (form) {
    var sync = function () {
      var chosen = form.querySelector('input[name=scenario]:checked');
      var applies = chosen && META.scenarios[chosen.value] && META.scenarios[chosen.value].restore;
      $('restore').disabled = !applies;
    };
    form.addEventListener('change', sync);
    sync();
  }

  // ---- polling -------------------------------------------------------------------------
  var running = false;
  function get(url) {
    return fetch(url, {credentials: 'same-origin'}).then(function (r) {
      if (r.status === 401) { window.location = '/login'; throw new Error('signed out'); }
      return r.json();
    });
  }
  function pollStatus() {
    get('/failover/status').then(function (d) {
      var was = running;
      running = !!(d.job && d.job.status === 'running');
      drawRun(d);
      if (was && !running) pollHistory();
    }).catch(function () {}).then(function () { setTimeout(pollStatus, running ? 2000 : 6000); });
  }
  function pollTopology() {
    get('/failover/topology').then(drawTopology).catch(function () {})
      .then(function () { setTimeout(pollTopology, running ? 2500 : 5000); });
  }
  function pollHistory() { get('/failover/history').then(drawHistory).catch(function () {}); }
  pollStatus();
  pollTopology();
  pollHistory();
  setInterval(pollHistory, 30000);
})();
