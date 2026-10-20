// Policy simulation: animates a packet through the firewall, walks the rulebase top to bottom
// and explains the decision. Data comes from the server as JSON (test security-policy-match +
// show running security-policy); nothing is sent to the network by this page.
(function () {
  'use strict';
  var NS = 'http://www.w3.org/2000/svg';
  var D = JSON.parse(document.getElementById('sim-data').textContent);
  if (!D) return;
  var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

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
  function list(v) { return (v && v.length) ? v.join(', ') : 'any'; }
  function addrSet(a) {
    if (!a || !a.count) return 'any';
    if (a.values.length === 1 && a.values[0] === 'any') return 'any';
    return a.values.join(', ') + (a.more ? ', …' : '');
  }
  function addrWhy(label, ip, a) {
    var set = addrSet(a);
    if (set === 'any') return label + ' ' + ip + ': the rule accepts any ' + label.toLowerCase() + '.';
    if (a.more) {
      return label + ' ' + ip + ' is one of the rule’s ' + label.toLowerCase() + ' addresses — a large set ' +
        '(the firewall lists only the first ones: ' + set + '). A set this size is a PANW predefined IP list (IP Defense).';
    }
    return label + ' ' + ip + ' matches the rule’s ' + label.toLowerCase() + ' set: ' + set + '.';
  }

  var m = D.matched || {};
  var action = (m.action || '').toLowerCase();
  var allowed = action === 'allow';
  var ZONE_NAME = {trust: 'trust (spokes, DC)', untrust: 'untrust (internet)', vpn: 'vpn (GlobalProtect users)'};

  // ---- static scene ----------------------------------------------------------------------
  var svg = $('flow');
  var packet, cross, dstBox;
  function scene() {
    clear(svg);
    svg.setAttribute('viewBox', '0 0 960 230');
    svg.appendChild(s('path', {d: 'M200,115 L360,115', 'class': 'edge'}));
    svg.appendChild(s('path', {d: 'M600,115 L760,115', 'class': 'edge'}));
    function node(x, w, cls, lines) {
      var r = s('rect', {x: x, y: 50, width: w, height: 130, rx: 12, 'class': 'node ' + cls});
      svg.appendChild(r);
      lines.forEach(function (ln, i) {
        svg.appendChild(s('text', {x: x + w / 2, y: 80 + i * 22, 'text-anchor': 'middle', 'class': ln[1] || ''}, ln[0]));
      });
      return r;
    }
    node(10, 190, '', [['Source', ''], [D.src, 'big'], ['zone ' + D.zfrom, 'small'], [D.proto + ' → port ' + D.port, 'small']]);
    node(360, 240, 'standby', [['Firewall', ''], [D.firewall + ' (active)', 'small'],
      [D.zfrom + '  →  ' + D.zto, 'big'], ['security policy, top to bottom', 'small']]);
    dstBox = node(760, 190, '', [['Destination', ''], [D.dst, 'big'], ['zone ' + D.zto, 'small'], ['port ' + D.port, 'small']]);
    packet = s('circle', {cx: 200, cy: 115, r: 9, 'class': 'packet'});
    svg.appendChild(packet);
    cross = s('g', {opacity: 0});
    cross.appendChild(s('line', {x1: 462, y1: 17, x2: 498, y2: 47, 'class': 'cross'}));
    cross.appendChild(s('line', {x1: 498, y1: 17, x2: 462, y2: 47, 'class': 'cross'}));
    svg.appendChild(cross);
  }

  // ---- rules list ------------------------------------------------------------------------
  var rows = [];
  function rules() {
    var ol = $('rules');
    clear(ol);
    rows = [];
    if (D.hidden_before) ol.appendChild(h('li', {'class': 'skip'}, D.hidden_before + ' earlier rules (zone mismatch / not shown)'));
    (D.rules || []).forEach(function (r) {
      var li = h('li', {'data-verdict': r.verdict});
      li.appendChild(h('span', {}, '#' + r.index + '  ' + r.name + '  —  ' + list(r.from) + ' → ' + list(r.to) +
        (r.action ? ('  ·  ' + r.action) : '')));
      li.appendChild(h('span', {'class': 'reason'}, ''));
      ol.appendChild(li);
      rows.push({li: li, rule: r});
    });
    if (D.rules_error) ol.appendChild(h('li', {'class': 'skip'}, 'Rulebase not available: ' + D.rules_error));
  }

  // ---- explanation -----------------------------------------------------------------------
  function why() {
    var ul = $('why');
    clear(ul);
    if (!m.name) { ul.appendChild(h('li', {}, 'No rule matched: the session would hit the implicit default rules.')); return; }
    var skipped = (D.rules || []).filter(function (r) { return r.verdict === 'skip'; }).length + (D.hidden_before || 0);
    ul.appendChild(h('li', {}, skipped + ' rule(s) above it did not match (reasons in the list).'));
    ul.appendChild(h('li', {}, 'Zones: the session goes ' + (ZONE_NAME[D.zfrom] || D.zfrom) + ' → ' + (ZONE_NAME[D.zto] || D.zto) +
      '; rule "' + m.name + '" accepts ' + list(m.from) + ' → ' + list(m.to) + '.'));
    ul.appendChild(h('li', {}, addrWhy('Destination', D.dst, m.destination)));
    ul.appendChild(h('li', {}, addrWhy('Source', D.src, m.source)));
    if (m.application) ul.appendChild(h('li', {}, 'Application / service: ' + m.application + '.'));
    ul.appendChild(h('li', {}, 'Action: ' + (m.action || '?') + (allowed
      ? ' — the session would be allowed (and inspected by the rule’s profiles).'
      : ' — the session would be blocked and logged.')));
  }

  // ---- animation -------------------------------------------------------------------------
  var timers = [];
  function later(ms, fn) { timers.push(setTimeout(fn, reduce ? 0 : ms)); }
  function move(from, to, ms, done) {
    if (reduce) { packet.setAttribute('cx', to); if (done) done(); return; }
    var t0 = null;
    function step(ts) {
      if (t0 === null) t0 = ts;
      var k = Math.min(1, (ts - t0) / ms);
      var e = k < 0.5 ? 2 * k * k : -1 + (4 - 2 * k) * k;
      packet.setAttribute('cx', from + (to - from) * e);
      if (k < 1) requestAnimationFrame(step); else if (done) done();
    }
    requestAnimationFrame(step);
  }
  function verdict(text, cls) {
    var v = $('verdict');
    v.className = 'verdict ' + (cls || '');
    v.textContent = text;
  }

  function play() {
    timers.forEach(clearTimeout);
    timers = [];
    scene();
    rules();
    why();
    verdict('Packet arrives at the firewall…');
    move(200, 360, 900, function () {
      var i = 0;
      function next() {
        if (i >= rows.length) return finish();
        var row = rows[i++];
        if (row.rule.verdict === 'unused') {
          row.li.className = 'unused';
          row.li.lastChild.textContent = row.rule.reason;
          return next();
        }
        row.li.className = 'eval';
        row.li.scrollIntoView({block: 'nearest'});
        later(row.rule.verdict === 'match' ? 500 : 220, function () {
          if (row.rule.verdict === 'match') {
            row.li.className = allowed ? 'match-allow' : 'match-deny';
            row.li.lastChild.textContent = 'MATCH — ' + row.rule.reason;
            // the remaining rows are only shown as not evaluated
            while (i < rows.length) {
              rows[i].li.className = 'unused';
              rows[i].li.lastChild.textContent = rows[i].rule.reason;
              i++;
            }
            return finish();
          }
          row.li.className = 'skip';
          row.li.lastChild.textContent = 'skip — ' + row.rule.reason;
          next();
        });
      }
      move(360, 384, 300, next);
    });
  }

  function finish() {
    if (!m.name) { verdict('No rule matched: implicit default rules decide.', 'deny'); return; }
    if (allowed) {
      packet.setAttribute('class', 'packet allow');
      verdict('ALLOWED by rule "' + m.name + '"', 'allow');
      move(384, 760, 1000, function () { dstBox.setAttribute('class', 'node live'); });
    } else {
      packet.setAttribute('class', 'packet deny');
      cross.setAttribute('opacity', 1);
      verdict('BLOCKED by rule "' + m.name + '" (' + (m.action || 'deny') + ')', 'deny');
      dstBox.setAttribute('class', 'node bad');
    }
  }

  $('replay').addEventListener('click', play);
  play();
})();
