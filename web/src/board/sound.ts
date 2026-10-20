/* w_creators · board/sound.ts - the board's cues, played with the page's own RDR menu sounds (main.jsx
   window.uiSound: button, menu_open, menu_close, selected). A cue with no sound stays silent; a sound never
   stops the board. */

export type Cue = 'navUp' | 'navDown' | 'select' | 'back' | 'locked' | 'toggleOn' | 'toggleOff' | 'done' | 'open' | 'close';

const SOUND: Partial<Record<Cue, string>> = {
  navUp: 'button',
  navDown: 'button',
  select: 'selected',
  toggleOn: 'selected',
  toggleOff: 'button',
  done: 'selected',
  back: 'menu_close',
  open: 'menu_open',
  close: 'menu_close',
};

export function cue(name: Cue): void {
  const play = (window as unknown as { uiSound?: (n: string) => void }).uiSound;
  const sound = SOUND[name];
  if (!sound || typeof play !== 'function') return;
  try { play(sound); } catch { /* a sound is never worth an error */ }
}
