/* ════════════════════════════════════════════════════════════════════════════
 * w_creators · board/cursor.ts - the board's cursor (the board kit's, w_centralbank web/src/cursor.ts)
 *
 * Every stop registers its element under an id (reg); the arrows, WASD, the pad and the mouse move between the
 * stops spatially (nav.ts pickNext reads the boxes the browser laid out, so it mirrors with Arabic by itself).
 * Enter / Space presses what the cursor is on (an input takes the keyboard instead); Left / Right turn a Stepper
 * where the cursor rests; Q / E (LB / RB) turn the section; Escape / Backspace go back.
 * A hover only lights a stop (byMouse() is then true): it never selects anything, and it is silent.
 *
 * A note (a paper sheet over the board) is a LAYER: while one is up only the ids that start with its prefix
 * ('n:') are stops; the rest of the board waits under it.
 * ════════════════════════════════════════════════════════════════════════════ */

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { pickNext, startPad, type Dir, type PadAction } from './nav';
import { cue, type Cue } from './sound';

export interface Nav {
  reg: (id: string) => (el: HTMLElement | null) => void;
  hover: (id: string) => () => void;
  here: (id: string) => boolean;
  regStep: (id: string, fn: ((delta: number) => void) | null) => void;
  focusTo: (id: string) => void;
}

export interface CursorOptions {
  /** false while the board is hidden or closed: no key, no pad */
  open: boolean;
  rtl: boolean;
  initial: string;
  /** the prefix of the note that is up ('n:'), or null: then every id that does NOT start with 'n:' */
  layer: () => string | null;
  back: () => void;
  turn?: (delta: number) => void;
  /** where the cursor goes when its stop vanished (a row removed, a note closed) */
  fallback: () => string | null;
  /** an Enter typed in this input, handled by the surface (true = handled: no move down) */
  enterInput?: (id: string) => boolean;
}

export interface Cursor {
  focus: string;
  nav: Nav;
  setCursor: (id: string) => void;
  focusTo: (id: string, sound?: Cue) => void;
  move: (dir: Dir) => void;
  has: (id: string) => boolean;
  /** true while the cursor sits where the mouse put it: a hover lights a stop, it never selects */
  byMouse: () => boolean;
}

const NOTE = 'n:';

export function useCursor(o: CursorOptions): Cursor {
  const [focus, setFocus] = useState(o.initial);
  const focusRef = useRef(focus);
  focusRef.current = focus;
  const els = useRef(new Map<string, HTMLElement>());
  const steppers = useRef(new Map<string, (delta: number) => void>());
  const openedAt = useRef(0);
  const opts = useRef(o);
  opts.current = o;
  const via = useRef<'key' | 'mouse'>('key');

  const inScope = useCallback((id: string) => {
    const layer = opts.current.layer();
    return layer ? id.startsWith(layer) : !id.startsWith(NOTE);
  }, []);

  const reg = useCallback((id: string) => (el: HTMLElement | null) => {
    if (el) els.current.set(id, el); else if (els.current.get(id) !== undefined) els.current.delete(id);
  }, []);
  const regStep = useCallback((id: string, fn: ((delta: number) => void) | null) => {
    if (fn) steppers.current.set(id, fn); else steppers.current.delete(id);
  }, []);
  const setCursor = useCallback((id: string) => { via.current = 'key'; focusRef.current = id; setFocus(id); }, []);
  const focusTo = useCallback((id: string, sound?: Cue) => {
    if (id === focusRef.current) return;
    setCursor(id);
    if (sound) cue(sound);
  }, [setCursor]);

  const scope = useCallback(() => {
    const out: { id: string; rect: DOMRect }[] = [];
    els.current.forEach((el, id) => { if (inScope(id) && el.isConnected) out.push({ id, rect: el.getBoundingClientRect() }); });
    return out;
  }, [inScope]);

  const move = useCallback((dir: Dir) => {
    const targets = scope();
    if (targets.length === 0) return;
    const cur = els.current.get(focusRef.current);
    if (!cur || !targets.some((x) => x.id === focusRef.current)) { focusTo(targets[0].id, 'navDown'); return; }
    const next = pickNext(cur.getBoundingClientRect(), targets.filter((x) => x.id !== focusRef.current), dir);
    if (next) focusTo(next, dir === 'up' || dir === 'left' ? 'navUp' : 'navDown');
  }, [scope, focusTo]);

  const side = useCallback((dir: 'left' | 'right') => {
    const step = steppers.current.get(focusRef.current);
    if (step && inScope(focusRef.current)) { step((dir === 'left') !== opts.current.rtl ? -1 : 1); return; }
    move(dir);
  }, [move, inScope]);

  const hover = useCallback((id: string) => () => {
    if (id === focusRef.current) return;
    focusTo(id);
    via.current = 'mouse';
  }, [focusTo]);

  const activate = useCallback(() => {
    const el = els.current.get(focusRef.current);
    if (!el || !inScope(focusRef.current)) return;
    if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) { el.focus(); el.select(); return; }
    el.click();
  }, [inScope]);

  /* the stop the cursor is on stays in view inside a scrolling box */
  useLayoutEffect(() => {
    const el = els.current.get(focus);
    if (el && via.current === 'key' && el.closest('.is-scroll')) el.scrollIntoView({ block: 'nearest' });
  }, [focus]);

  /* the stop vanished, or a note came up / went away: the surface says where the cursor goes */
  useLayoutEffect(() => {
    if (!o.open) return;
    if (els.current.has(focusRef.current) && inScope(focusRef.current)) return;
    const fb = opts.current.fallback();
    if (fb && fb !== focusRef.current) setCursor(fb);
  });

  /* the keyboard and the pad, while the board is up */
  useEffect(() => {
    if (!o.open) return;
    openedAt.current = performance.now();
    const onKey = (e: KeyboardEvent) => {
      if (performance.now() - openedAt.current < 150) return;
      const O = opts.current;
      const target = e.target as HTMLElement | null;
      if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) {
        switch (e.key) {
          case 'Escape': target.blur(); break;
          case 'Enter':
            target.blur();
            if (!(O.enterInput && O.enterInput(focusRef.current))) move('down');
            break;
          case 'ArrowUp': target.blur(); move('up'); break;
          case 'ArrowDown': target.blur(); move('down'); break;
          default: return;
        }
        e.preventDefault();
        return;
      }
      switch (e.key) {
        case 'ArrowUp': case 'w': case 'W': move('up'); break;
        case 'ArrowDown': case 's': case 'S': move('down'); break;
        case 'ArrowLeft': case 'a': case 'A': side('left'); break;
        case 'ArrowRight': case 'd': case 'D': side('right'); break;
        case 'Enter': case ' ': activate(); break;
        case 'Escape': case 'Backspace': O.back(); break;
        case 'q': case 'Q': O.turn?.(O.rtl ? 1 : -1); break;
        case 'e': case 'E': O.turn?.(O.rtl ? -1 : 1); break;
        case 'PageUp': O.turn?.(-1); break;
        case 'PageDown': O.turn?.(1); break;
        default: return;
      }
      e.preventDefault();
    };
    window.addEventListener('keydown', onKey);
    const stopPad = startPad((a: PadAction) => {
      const O = opts.current;
      const typing = document.activeElement;
      if (typing instanceof HTMLInputElement || typing instanceof HTMLTextAreaElement) {
        typing.blur();
        if (a === 'back') return;
      }
      if (a === 'select') activate();
      else if (a === 'back') O.back();
      else if (a === 'prev') O.turn?.(O.rtl ? 1 : -1);      // LB is Q, RB is E: the side of the screen they point to
      else if (a === 'next') O.turn?.(O.rtl ? -1 : 1);
      else if (a === 'left' || a === 'right') side(a);
      else move(a);
    });
    return () => { window.removeEventListener('keydown', onKey); stopPad(); };
  }, [o.open, move, side, activate]);

  const here = (id: string) => focus === id;
  const nav: Nav = { reg, hover, here, regStep, focusTo: setCursor };
  return { focus, nav, setCursor, focusTo, move, has: (id: string) => els.current.has(id), byMouse: () => via.current === 'mouse' };
}
