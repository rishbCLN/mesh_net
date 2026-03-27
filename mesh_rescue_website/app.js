const DATA_URL = 'https://api.jsonbin.io/v3/b/69c63d08aa77b81da924ff94/latest';
const POLL_INTERVAL_MS = 30000; // re-fetch every 30 seconds

const STATUS_COLORS = { critical: '#ef5350', injured: '#ffd600', ok: '#00e676' };
const STATUS_RADII  = { critical: 9, injured: 8, ok: 7 };
const STATUS_ORDER  = { critical: 0, injured: 1, ok: 2 };

const pill = document.getElementById('statusPill');
const list = document.getElementById('survivorList');

const map = L.map('map', { zoomControl: true }).setView([20.5937, 78.9629], 5);
L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
  attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
  maxZoom: 19
}).addTo(map);

let activeMarkers = [];
let lastTs = null;

function makeIcon(status) {
  const color  = STATUS_COLORS[status] || '#8b949e';
  const r      = STATUS_RADII[status]  || 7;
  const size   = r * 2;
  const wrap   = size + 10;
  const pulse  = status === 'critical'
    ? `<div class="marker-pulse" style="width:${wrap}px;height:${wrap}px;background:${color};"></div>`
    : '';
  return L.divIcon({
    className : '',
    html      : `<div class="marker-wrap" style="width:${wrap}px;height:${wrap}px;">
                   ${pulse}
                   <div class="marker-dot" style="width:${size}px;height:${size}px;background:${color};"></div>
                 </div>`,
    iconSize  : [wrap, wrap],
    iconAnchor: [wrap / 2, wrap / 2],
    popupAnchor: [0, -(wrap / 2)]
  });
}

function clearMarkers() {
  activeMarkers.forEach(m => m.remove());
  activeMarkers = [];
}

function renderSurvivors(survivors) {
  clearMarkers();

  const sorted = [...survivors].sort(
    (a, b) => (STATUS_ORDER[a.status] ?? 3) - (STATUS_ORDER[b.status] ?? 3)
  );

  const bounds = [];

  sorted.forEach(s => {
    if (s.lat == null || s.lng == null) return;
    const seen = s.lastSeen ? `<br>Last seen: ${new Date(s.lastSeen).toLocaleTimeString()}` : '';
    const marker = L.marker([s.lat, s.lng], { icon: makeIcon(s.status) })
      .bindPopup(
        `<b>${s.name}</b><br>Status: ${s.status}<br>${s.lat.toFixed(4)}, ${s.lng.toFixed(4)}${seen}`
      )
      .addTo(map);
    activeMarkers.push(marker);
    bounds.push([s.lat, s.lng]);
  });

  if (bounds.length > 0) map.fitBounds(bounds, { padding: [48, 32] });

  list.innerHTML = sorted.length === 0
    ? '<li class="empty-state">Waiting for mesh data...</li>'
    : sorted.map(s => `
        <li class="${s.status === 'critical' ? 'critical' : ''}">
          <span class="dot dot-${s.status}"></span>
          <span class="name">${s.name}</span>
          <span class="status-label">${s.status}</span>
        </li>`).join('');
}

function setPill(text, live) {
  pill.textContent = text;
  pill.classList.toggle('live', live);
}

function minsAgo(ts) {
  const m = Math.floor((Date.now() / 1000 - ts) / 60);
  return m < 1 ? 'just now' : `${m} min ago`;
}

async function fetchData() {
  try {
    const res = await fetch(DATA_URL);
    if (!res.ok) throw new Error('Non-OK status');
    const json = await res.json();
    const data = json.record || json; // unwrap jsonbin.io wrapper
    if (!data.ts) throw new Error('No data yet');
    lastTs = data.ts;
    renderSurvivors(data.survivors || []);
    setPill(`Live \u2014 last updated ${minsAgo(lastTs)}`, true);
  } catch (_) {
    if (lastTs) {
      setPill(`Offline \u2014 last data ${minsAgo(lastTs)}`, false);
    } else {
      setPill('Waiting for data', false);
      list.innerHTML = '<li class="empty-state">Waiting for mesh data...</li>';
    }
  }
}

fetchData();
setInterval(fetchData, POLL_INTERVAL_MS);
