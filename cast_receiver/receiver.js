import {activeLyricIndex, clock, LyricsState, safeArtwork, normalizeAppearance} from './protocol.js';
const $ = id => document.getElementById(id);
const context = cast.framework.CastReceiverContext.getInstance();
const player = context.getPlayerManager();
const namespace = 'urn:x-cast:com.spotiflac.tv';
const lyrics = new LyricsState();
let active = -1, emptyLyrics = 'No lyrics available', duration = 0, scrubbing = false;
let rows = [], labels = {}, reducedMotion = false, currentGradient = '';
function status(text) { $('status').textContent = text; }
function profile(data) {
  if (typeof data.greeting === 'string') $('greeting').textContent = data.greeting.slice(0,200);
  if (typeof data.noLyrics === 'string') emptyLyrics = data.noLyrics;
}
function appearance(raw) {
  const ui = normalizeAppearance(raw);
  if (!ui.style) return;
  document.body.dataset.theme = ui.style;
  reducedMotion = ui.reduceMotion;
  document.body.classList.toggle('reduce-motion',reducedMotion);
  for (const [key, css] of Object.entries({surface:'surface',ink:'ink',muted:'muted',accent:'accent',onAccent:'on-accent'})) {
    if (ui[key]) document.documentElement.style.setProperty('--'+css,ui[key]);
  }
  if (ui.backgroundStart && ui.backgroundEnd) {
    const next = `linear-gradient(135deg, ${ui.backgroundStart}, ${ui.backgroundEnd})`;
    const base = $('ambience'), fade = $('ambience-fade');
    if (currentGradient !== next) {
      currentGradient = next;
      fade.style.background = getComputedStyle(base).backgroundImage;
      fade.style.opacity = '1';
      base.style.background = next;
      void fade.offsetWidth; // Start the crossfade from the preceding cover.
      fade.style.opacity = '0';
    }
  }
  document.documentElement.style.setProperty('--font',ui.font === 'system' ? 'system-ui,sans-serif' : `"${ui.font}",system-ui,sans-serif`);
  labels = ui.labels;
  $('session-label').textContent = labels.player || 'Now Playing';
  $('queue-label').textContent = labels.queue || 'Up next';
  for (const [id,key] of Object.entries({'previous':'previous','next':'next','lyrics-toggle':'lyrics','queue-toggle':'queue','cast':'stop','more':'more','volume':'volume'})) {
    if (labels[key]) $(id).setAttribute('aria-label',labels[key]);
  }
}
function showMedia(media) {
  if (!media) return;
  const data = media.customData || {};
  profile(data); appearance(data.ui);
  if (lyrics.mediaId !== data.mediaId) { lyrics.load(data.mediaId); renderLyrics(); }
  const metadata = media.metadata || {};
  $('title').textContent = metadata.title || 'SpotiFLAC';
  $('artist').textContent = metadata.artist || '';
  $('album').textContent = metadata.albumName || '';
  const url = safeArtwork(metadata.images?.[0]?.url || '');
  $('cover').hidden = !url; $('placeholder').hidden = !!url;
  if (url) $('cover').src = url; else $('cover').removeAttribute('src');
  duration = Number(media.duration) || 0;
  $('seek').max = Math.max(1,duration);
}
function renderLyrics() {
  const area = $('lyrics'); area.replaceChildren(); rows = []; active = -1;
  if (!lyrics.lines.length) {
    const p = document.createElement('p'); p.className = 'empty'; p.textContent = emptyLyrics; area.append(p); return;
  }
  for (const line of lyrics.lines) {
    const p = document.createElement('p'); p.textContent = line.text || '♪';
    if (line.translation) { const small = document.createElement('small'); small.textContent = line.translation; p.append(small); }
    area.append(p); rows.push(p);
  }
  area.style.paddingTop = lyrics.synced ? '' : '3vh';
  area.style.paddingBottom = lyrics.synced ? '' : '3vh';
  tick();
}
function progress(element, fraction) { element.style.setProperty('--progress',`${Math.max(0,Math.min(1,fraction))*100}%`); }
function tick() {
  const position = player.getCurrentTimeSec() || 0;
  $('elapsed').textContent = clock(position);
  $('duration').textContent = document.body.dataset.theme === 'mornye' ? '−'+clock(Math.max(0,duration-position)) : clock(duration);
  if (!scrubbing) { $('seek').value = Math.min(duration || position,position); progress($('seek'),position/(duration || 1)); }
  const playing = player.getPlayerState() === cast.framework.messages.PlayerState.PLAYING;
  $('play').innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="${playing ? 'M6 5h4v14H6zM14 5h4v14h-4z' : 'M8 5v14l11-7z'}"/></svg>`;
  $('play').setAttribute('aria-label', playing ? labels.pause || 'Pause' : labels.play || 'Play');
  const index = lyrics.synced ? activeLyricIndex(lyrics.lines,position) : -1;
  if (index !== active) {
    rows[active]?.classList.remove('active'); rows[index]?.classList.add('active'); active = index;
    if (index >= 0 && document.body.dataset.page === 'lyrics') {
      const area = $('lyrics'), row = rows[index];
      const box = row.getBoundingClientRect(), viewport = area.getBoundingClientRect();
      area.scrollTo({top:area.scrollTop+box.top-viewport.top-area.clientHeight/2+box.height/2,
        behavior:reducedMotion || matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth'});
    }
  }
}
function command(action, extra={}) { context.sendCustomMessage(namespace,undefined,{type:'command',action,...extra}); }
function page(value) {
  document.body.dataset.page = value;
  $('lyrics-toggle').setAttribute('aria-pressed',String(value === 'lyrics'));
  $('queue-toggle').setAttribute('aria-pressed',String(value === 'queue'));
  active = -1; tick();
}
for (const action of ['previous','next','shuffle','repeat','favorite']) $(action).onclick = () => command(action);
$('cast').onclick = () => command('disconnect');
$('menu-stop').onclick = () => command('disconnect');
$('menu-shuffle').onclick = () => { command('shuffle'); $('options').hidden = true; };
$('menu-repeat').onclick = () => { command('repeat'); $('options').hidden = true; };
$('more').onclick = () => { $('options').hidden = !$('options').hidden; if (!$('options').hidden) $('menu-shuffle').focus(); };
$('play').onclick = () => { if (player.getPlayerState() === cast.framework.messages.PlayerState.PLAYING) player.pause(); else player.play(); };
$('seek').oninput = () => { scrubbing = true; $('elapsed').textContent = clock($('seek').value); progress($('seek'),Number($('seek').value)/(duration || 1)); };
$('seek').onchange = () => { player.seek(Number($('seek').value)); scrubbing = false; };
$('volume').oninput = () => progress($('volume'),Number($('volume').value));
$('volume').onchange = () => {
  const request = new cast.framework.messages.VolumeRequestData();
  request.requestId = 0;
  request.volume = {level:Number($('volume').value)};
  player.sendLocalMediaRequest(request);
};
$('lyrics-toggle').onclick = () => page(document.body.dataset.page === 'lyrics' ? 'player' : 'lyrics');
$('queue-toggle').onclick = () => page(document.body.dataset.page === 'queue' ? 'player' : 'queue');
$('cover').onerror = () => { $('cover').hidden = true; $('placeholder').hidden = false; };
context.addCustomMessageListener(namespace,event => {
  let message;
  try { message = typeof event.data === 'string' ? JSON.parse(event.data) : event.data; } catch { return; }
  if (!message || typeof message !== 'object') return;
  if (message.type === 'profile') { profile(message); if (!lyrics.lines.length) renderLyrics(); }
  else if (message.type === 'appearance') appearance(message.ui);
  else if (message.type === 'queue' && Array.isArray(message.items)) {
    $('queue').replaceChildren();
    for (const item of message.items.slice(0,50)) {
      if (!Number.isInteger(item.index) || typeof item.title !== 'string') continue;
      const button = document.createElement('button'); button.textContent = item.title;
      const artist = document.createElement('small'); artist.textContent = typeof item.artist === 'string' ? item.artist : ''; button.append(artist);
      button.classList.toggle('selected',item.index === message.currentIndex);
      button.onclick = () => command('jump',{index:item.index}); $('queue').append(button);
    }
    $('favorite').classList.toggle('selected',message.loved === true);
    $('shuffle').classList.toggle('selected',message.shuffle === true);
    $('repeat').classList.toggle('selected',message.repeat !== 'none');
    $('menu-shuffle').textContent = message.shuffle ? 'Shuffle: On' : 'Shuffle: Off';
    $('menu-repeat').textContent = 'Repeat: '+(message.repeat || 'none');
  } else if (lyrics.accept(message)) renderLyrics();
});
player.setMessageInterceptor(cast.framework.messages.MessageType.LOAD,request => { showMedia(request.media); status('Loading music…'); return request; });
player.setMessageInterceptor(cast.framework.messages.MessageType.SET_VOLUME,request => {
  if (Number.isFinite(request.volume?.level)) {
    $('volume').value = request.volume.level;
    progress($('volume'),request.volume.level);
  }
  return request;
});
player.addEventListener(cast.framework.events.EventType.MEDIA_INFORMATION_CHANGED,() => showMedia(player.getMediaInformation()));
player.addEventListener(cast.framework.events.EventType.PLAYER_STATE_CHANGED,() => { tick(); status('SpotiFLAC Mobile'); });
player.addEventListener(cast.framework.events.EventType.ERROR,() => status('Unable to play this track. Check the phone connection and audio format.'));
document.addEventListener('keydown',event => {
  if (event.key === 'Escape' || event.key === 'Backspace') { $('options').hidden = true; page('player'); $('play').focus(); return; }
  // Left/right adjust a range; up/down must let a TV remote leave it.
  if (document.activeElement instanceof HTMLInputElement && !['ArrowUp','ArrowDown'].includes(event.key)) return;
  if (document.activeElement === $('lyrics')) {
    if (event.key === 'ArrowUp' || event.key === 'ArrowDown') { event.preventDefault(); $('lyrics').scrollBy({top:event.key === 'ArrowDown' ? 160 : -160,behavior:reducedMotion ? 'instant' : 'smooth'}); return; }
  }
  if (['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(event.key)) {
    event.preventDefault();
    const visible = Array.from(document.querySelectorAll('button,input,#lyrics,#queue-pane')).filter(el => el.getClientRects().length > 0);
    const index = visible.indexOf(document.activeElement), delta = ['ArrowLeft','ArrowUp'].includes(event.key) ? -1 : 1;
    visible[(index+delta+visible.length)%visible.length]?.focus();
  } else if (event.key === 'MediaPlayPause' || event.key === ' ') { event.preventDefault(); $('play').click(); }
});
player.setSupportedMediaCommands(cast.framework.messages.Command.PAUSE | cast.framework.messages.Command.SEEK | cast.framework.messages.Command.STREAM_VOLUME | cast.framework.messages.Command.STREAM_MUTE,true);
context.start({disableIdleTimeout:false,maxInactivity:600}); $('play').focus(); setInterval(tick,500);
