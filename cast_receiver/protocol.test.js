import test from 'node:test';
import assert from 'node:assert/strict';
import {activeLyricIndex, clock, LyricsState, safeArtwork} from './protocol.js';
test('lyric highlight follows playback and seeks backwards', () => {
  const lines = [{timeMs:1000}, {timeMs:5000}, {timeMs:12000}];
  assert.equal(activeLyricIndex(lines, 0), -1);
  assert.equal(activeLyricIndex(lines, 5), 1);
  assert.equal(activeLyricIndex(lines, 15), 2);
  assert.equal(activeLyricIndex(lines, 2), 0);
});
test('late lyrics from a previous track cannot replace current lyrics', () => {
  const state = new LyricsState(); state.load('new');
  assert.equal(state.accept({type:'lyricsReset',mediaId:'old',synced:true}), false);
  assert.equal(state.accept({type:'lyrics',mediaId:'old',lines:[{timeMs:0,text:'old'}]}), false);
  assert.equal(state.accept({type:'lyricsReset',mediaId:'new',synced:true}), true);
  state.accept({type:'lyrics',mediaId:'new',lines:[{timeMs:10,text:'second'}, {timeMs:0,text:'first'}]});
  assert.equal(state.lines[0].text, 'first');
  state.load('next'); assert.deepEqual(state.lines, []);
});
test('invalid payloads and non-network artwork URLs are ignored', () => {
  const state = new LyricsState(); state.load('a');
  state.accept({type:'lyrics',mediaId:'a',lines:[{timeMs:'oops',text:'a'}, {timeMs:0,text:'<script>literal text</script>'}]});
  assert.equal(state.lines.length, 1);
  assert.equal(safeArtwork('javascript:alert(1)'), '');
  assert.equal(safeArtwork('file:///private/file'), '');
  assert.equal(safeArtwork('http://192.168.1.5:3000/media/token'), 'http://192.168.1.5:3000/media/token');
});
test('time labels handle unknown durations and long tracks', () => {
  assert.equal(clock(NaN), '0:00'); assert.equal(clock(-5), '0:00');
  assert.equal(clock(65), '1:05'); assert.equal(clock(3661), '1:01:01');
});
test('receiver adopts sender appearance without accepting arbitrary CSS', async () => {
  const {normalizeAppearance} = await import('./protocol.js');
  const ui = normalizeAppearance({style:'material',font:'Inter',surface:'#fafafa',ink:'#121212',accent:'#ff2d55',muted:'url(javascript:bad)',labels:{lyrics:'Lyrics',bad:42}});
  assert.equal(ui.style,'material'); assert.equal(ui.font,'Inter'); assert.equal(ui.surface,'#fafafa');
  assert.equal(ui.accent,'#ff2d55'); assert.equal(ui.muted,undefined); assert.equal(ui.labels.bad,undefined);
});
