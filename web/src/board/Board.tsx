/* ════════════════════════════════════════════════════════════════════════════
 * w_creators · board/Board.tsx - the services board as the builders' notebook (2026-11-12; page contract
 * ops/local/plans/creators-board-contract.md, the notebook parts: docs/BUILDER_COMPAT.md)
 *
 *   the column   docked at the PHYSICAL right in both languages, the world stays seen beside it
 *   masthead     the board's name, the flash line under it after an answer
 *   head card    the section (clothing stores · barbers · clinics · wardrobes) as one row of tabs (Q / E),
 *                «مكان جديد هنا» (a note asks the name -> op create)
 *   the list     every place of the section as a line: its name, where it is in words and what it still needs;
 *                nearest first. A click / Enter opens it
 *   one place    PlaceCard.tsx: the story of its spots, the basics, «خيارات متقدمة»; above it «كل الأماكن» back
 *   readiness    «ينقصه: …» + «أصلحه» (the save's own checks, then the spots a player meets), or «جاهز»
 *   actions      حفظ · في العالم · انتقل · حذف المكان · إغلاق, and the keys row
 *   world mode   TAB / «في العالم»: Lua runs w_lib's lib.worldEdit (J «ماذا يحدث هنا؟», J on a pin), the column
 *                dims and the game has the keys until TAB comes back (boardWorld). Only with w_lib 4.5.0+.
 * Every call is nuiSend('board:action', { op, args }); an answer's `data` replaces the board at once (an older
 * answer never overwrites a newer one, and a `board` message counts as the newest). Unsaved edits ask before
 * another place, another section, the list or a close. Escape: a note first, then the place, then the board.
 * ════════════════════════════════════════════════════════════════════════════ */

import { useCallback, useEffect, useRef, useState } from 'react';
import { nuiSend } from '../nui';
import { useCursor } from './cursor';
import { Add } from './fields';
import { cls, Txt, useI18n } from './i18n';
import { IconOff, IconOn, TYPE_ICONS } from './icons';
import {
  asBoard, formOf, formOk, formProblems, LABEL_MAX, labelOk, missingSpots, obj, sameForm, saveArgs, townOk, TYPES,
  type BoardData, type Form, type Place, type PlaceType, type SpotKind,
} from './model';
import { ConfirmNote, InputNote } from './notes';
import { ActionStrip, Flash, StateLine, useErrorText, useFlash, type Action } from './parts';
import PlaceCard, { type PlaceWhat } from './PlaceCard';
import type { Live } from './Root';
import { cue } from './sound';

interface Answer { ok: boolean; error?: string; data: BoardData | null }

interface AskSpec { question: string; sub?: string; yes: string; no: string; run: () => void }

interface Draft { id: string; base: Form; form: Form }

/* where the admin was, kept between two openings of the board (this page's life only) */
const memory: { section: PlaceType; sel: Partial<Record<PlaceType, string>>; inPlace: boolean } = { section: TYPES[0], sel: {}, inPlace: false };

/* the field a problem of formProblems() sits in (for «أصلحه») */
const FIELD_OF: Record<string, string> = { label: 'f:label', town: 'f:town', radius: 'f:reach', npcModel: 'a:npcText' };

export default function Board({ data, rev, hidden, close, live }: { data: unknown; rev: number; hidden: boolean; close: () => void; live: Live }) {
  const { t, rtl, lang } = useI18n();
  const errText = useErrorText();

  /* ── the board's data: a `board` message replaces it, and so does an answer's `data` ── */
  const [st, setSt] = useState<BoardData | null>(() => asBoard(data));
  const seq = useRef(0);
  const applied = useRef(0);
  useEffect(() => {
    const next = asBoard(data);
    if (!next) return;
    applied.current = seq.current;        // a message is the newest word: answers already on their way lose to it
    setSt(next);
  }, [data, rev]);

  const [section, setSection] = useState<PlaceType>(memory.section);
  const [sel, setSel] = useState<Partial<Record<PlaceType, string>>>(memory.sel);
  const [inPlace, setInPlace] = useState(memory.inPlace);
  const [adv, setAdv] = useState(false);
  useEffect(() => { memory.section = section; memory.sel = sel; memory.inPlace = inPlace; }, [section, sel, inPlace]);

  const where = live.where;
  const distance = (p: Place) => where[p.id]?.coords?.m ?? Number.MAX_SAFE_INTEGER;
  const places = st ? st.places.filter((p) => p.type === section).slice().sort((a, b) => distance(a) - distance(b)) : [];
  const picked: Place | null = places.find((p) => p.id === sel[section]) ?? null;
  const shown = inPlace && picked ? picked : null;

  /* ── Lua marks the shown place's spots in the world (and J's rows are for it) ── */
  useEffect(() => {
    nuiSend('board:sel', { id: shown ? shown.id : '' }).catch(() => undefined);
  }, [shown?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  /* ── the card's draft: kept while it holds unsaved edits, otherwise it follows the data ── */
  const [draft, setDraft] = useState<Draft | null>(null);
  useEffect(() => {
    if (!picked || !st) { setDraft(null); return; }
    const base = formOf(picked, st);
    setDraft((d) => (d && d.id === picked.id && !sameForm(d.form, d.base) ? { id: d.id, base, form: d.form } : { id: picked.id, base, form: base }));
  }, [picked, st]);
  const mine = draft && picked && draft.id === picked.id ? draft : null;
  const form: Form | null = mine ? mine.form : picked && st ? formOf(picked, st) : null;
  const dirty = !!mine && !sameForm(mine.form, mine.base);
  const patch = useCallback((p: Partial<Form>) => {
    if (!picked || !st) return;
    setDraft((d) => {
      const cur = d && d.id === picked.id ? d : { id: picked.id, base: formOf(picked, st), form: formOf(picked, st) };
      return { ...cur, form: { ...cur.form, ...p } };
    });
  }, [picked, st]);
  const [chairModel, setChairModel] = useState('');
  useEffect(() => { if (st && !st.chairModels.includes(chairModel)) setChairModel(st.chairModels[0] ?? ''); }, [st, chairModel]);

  /* ── notes, calls, the flash line ── */
  const [ask, setAsk] = useState<AskSpec | null>(null);
  const [creating, setCreating] = useState(false);
  const [busy, setBusy] = useState(false);
  const [flash, say] = useFlash();
  const noted = !!ask || creating;
  const resume = useRef<string | null>(null);
  const inflight = useRef(0);

  const act = useCallback(async (op: string, args: Record<string, unknown>): Promise<Answer> => {
    const my = ++seq.current;
    inflight.current += 1;
    setBusy(true);
    let res: unknown = null;
    try { res = await nuiSend('board:action', { op, args }); } catch { res = null; }
    inflight.current = Math.max(0, inflight.current - 1);
    if (inflight.current === 0) setBusy(false);
    const o = obj(res);
    if (!o) return { ok: false, error: 'no_answer', data: null };
    const next = o.data !== undefined && o.data !== null ? asBoard(o.data) : null;
    if (next && my > applied.current) { applied.current = my; setSt(next); }
    const ok = o.ok === true;
    return { ok, error: ok ? undefined : typeof o.error === 'string' && o.error !== '' ? o.error : 'generic', data: next };
  }, []);

  /** act + the sound + the flash line: `done` (a string id) on success, the worded error otherwise */
  const run = useCallback(async (op: string, args: Record<string, unknown>, done?: string): Promise<Answer | null> => {
    const res = await act(op, args);
    if (!res.ok) { cue('locked'); say(errText(res.error), true); return null; }
    cue('done');
    if (done) say(t(done));
    return res;
  }, [act, errText, say, t]);

  /* ── leaving unsaved edits asks first ── */
  const openAsk = (a: AskSpec) => { resume.current = cursor.focus; cue('select'); setAsk(a); };
  const backFromNote = () => {
    const r = resume.current;
    resume.current = null;
    if (r) cursor.setCursor(r);
  };
  const guard = (go: () => void) => {
    if (!dirty) { go(); return; }
    openAsk({
      question: t('note.unsavedTitle'),
      sub: t('note.unsavedBody'),
      yes: t('note.discard'),
      no: t('note.cancel'),
      run: () => { setDraft((d) => (d ? { ...d, form: d.base } : d)); go(); },
    });
  };

  const switchTo = (s: PlaceType) => {
    if (s === section) return;
    guard(() => {
      cue('select');
      setSection(s);
      setInPlace(false);
      cursor.setCursor(`side:${s}`);
    });
  };
  const openPlace = (id: string) => {
    const go = () => { cue('select'); setSel((v) => ({ ...v, [section]: id })); setInPlace(true); setAdv(false); cursor.setCursor('pv:back'); };
    if (picked && id === picked.id) { setInPlace(true); cursor.setCursor('pv:back'); cue('select'); return; }
    guard(go);
  };
  const toList = () => guard(() => {
    cue('back');
    setInPlace(false);
    cursor.setCursor(picked ? `pl:${picked.id}` : `side:${section}`);
  });
  const leave = () => guard(() => { cue('close'); close(); });

  const back = () => {
    if (ask) { cue('back'); setAsk(null); backFromNote(); return; }
    if (creating) { cue('back'); setCreating(false); backFromNote(); return; }
    if (shown) { toList(); return; }
    leave();
  };

  /* ── a place opened from the world (J on a pin «افتح المكان», or a new one made there) ── */
  const openRev = useRef(live.openRev);
  useEffect(() => {
    if (live.openRev === openRev.current) return;
    openRev.current = live.openRev;
    const p = st?.places.find((x) => x.id === live.openId);
    if (!p) return;
    setSection(p.type);
    setSel((v) => ({ ...v, [p.type]: p.id }));
    setInPlace(true);
    setAdv(false);
    cursor.setCursor('pv:back');
  }, [live.openRev, live.openId, st]); // eslint-disable-line react-hooks/exhaustive-deps

  /* ── the world mode: TAB here, TAB in the world comes back (Lua's boardWorld) ── */
  const inWorld = live.world;
  const toWorld = useCallback(async () => {
    if (!live.canWorld) { cue('locked'); say(t('err.no_world'), true); return; }
    if (busy || noted) return;
    cue('select');
    let res: unknown = null;
    try { res = await nuiSend('board:world', { on: true }); } catch { res = null; }
    const o = obj(res);
    if (!o || o.ok !== true) {
      const code = o && typeof o.error === 'string' ? o.error : '';
      // a refused switch right after the last one (w_lib's 300 ms gap) is silent: the board simply stays
      if (code && code !== 'busy') say(errText(code), true);
    }
  }, [live.canWorld, busy, noted, say, t, errText]);

  const cursor = useCursor({
    open: !hidden && !inWorld,
    rtl,
    initial: shown ? 'pv:back' : picked ? `pl:${picked.id}` : `side:${section}`,
    layer: () => (noted ? 'n:' : null),
    back,
    turn: (delta) => {
      if (noted) return;
      const i = TYPES.indexOf(section);
      switchTo(TYPES[(i + delta + TYPES.length) % TYPES.length]);
    },
    fallback: () => {
      if (ask) return 'n:no';
      if (creating) return 'n:input';
      if (shown) return 'pv:back';
      return places[0] ? `pl:${places[0].id}` : `side:${section}`;
    },
  });
  const { nav, focus } = cursor;

  // TAB on the board (never while typing in a field, never under a note)
  useEffect(() => {
    if (hidden || inWorld) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Tab') return;
      e.preventDefault();
      const el = document.activeElement;
      if (noted || (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA'))) return;
      void toWorld();
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  }, [hidden, inWorld, noted, toWorld]);

  /* ── the ops ── */
  const save = async () => {
    if (!picked || !form) return;
    if (!formOk(form)) { cue('locked'); say(t('err.invalid'), true); return; }
    const id = picked.id;
    const res = await run('save', saveArgs(picked, form), 'ok.saved');
    if (res) setDraft((d) => (d && d.id === id ? { ...d, base: d.form } : d));
  };

  const create = async (label: string) => {
    const type = section;
    const before = new Set(st ? st.places.map((p) => p.id) : []);
    const res = await run('create', { type, label }, 'ok.created');
    // Lua names the new place in data.selected; otherwise it is the one place of this type that was not there before
    const made = res?.data?.places.find((p) => p.id === res.data?.selected)
      ?? res?.data?.places.find((p) => p.type === type && !before.has(p.id));
    if (made) {
      setSel((v) => ({ ...v, [type]: made.id }));
      setInPlace(true);
      cursor.setCursor('pv:back');
    } else {
      cursor.setCursor('new');
    }
  };

  const askDelete = () => {
    if (!picked) return;
    const p = picked;
    openAsk({
      question: t('note.deleteTitle', p.label || p.id),
      sub: t('note.deleteBody'),
      yes: t('note.confirm'),
      no: t('note.cancel'),
      run: () => {
        void run('delete', { id: p.id }, 'ok.deleted').then((res) => {
          if (!res) { cursor.setCursor('act:delete'); return; }
          setSel((v) => ({ ...v, [p.type]: undefined }));
          setDraft(null);
          setInPlace(false);
          cursor.setCursor('new');
        });
      },
    });
  };

  const place = async (what: PlaceWhat, model?: string) => {
    if (!picked || !form || busy) return;
    const p = picked;
    // unsaved edits (an NPC look chosen above, a new name) are saved first, so the spot is placed with them
    if (dirty) {
      if (!formOk(form)) { cue('locked'); say(t('err.invalid'), true); return; }
      const saved = await run('save', saveArgs(p, form));
      if (!saved) return;
      setDraft((d) => (d && d.id === p.id ? { ...d, base: d.form } : d));
    }
    const args: Record<string, unknown> = { id: p.id, what };
    if (what === 'chair' && model) args.model = model;
    // Lua answers at once, hides the board (boardHide), runs the world editor and sends the board again (the
    // section and the selected place stay); a missing answer is not an error, the board comes back by itself
    const res = await act('place', args);
    if (!res.ok && res.error !== 'no_answer') { cue('locked'); say(errText(res.error), true); }
  };

  const clear = async (what: SpotKind) => {
    if (!picked) return;
    const res = await run('clear', { id: picked.id, what }, 'ok.cleared');
    if (res) cursor.setCursor(`sp:${what}:place`);
  };

  const teleport = () => {
    if (!picked) return;
    void run('teleport', { id: picked.id }, 'ok.teleported');
  };

  /* ── readiness: the save's checks first, then the spots a player meets ── */
  const problems = form ? formProblems(form) : [];
  const missing = shown ? missingSpots(shown) : [];
  const needs: { text: string; fix: () => void }[] = [
    ...problems.map((k) => ({
      text: t(`rd.${k}`),
      fix: () => { if (k === 'npcModel') setAdv(true); cursor.setCursor(FIELD_OF[k]); },
    })),
  ];
  // a spot left unset is optional (no NPC stands there / the player stays where he is): told softly, never "missing"
  const optional = missing.map((w) => ({ text: t(`what.${w}`), fix: () => cursor.setCursor(`sp:${w}:place`) }));
  const listNeeds = (p: Place) => [
    ...(labelOk(p.label) ? [] : [t('rd.label')]),
    ...(townOk(p.town) ? [] : [t('rd.town')]),
  ];
  const listOpt = (p: Place) => missingSpots(p).map((w) => t(`what.${w}`));

  /* ── drawing ── */
  const onHead = (focus.startsWith('side:') || focus === 'new') && !noted;
  const onList = focus.startsWith('pl:') && !noted;
  const onCard = (focus.startsWith('f:') || focus.startsWith('a:') || focus.startsWith('sp:') || focus === 'pv:back') && !noted;
  const onReady = (focus === 'rd:fix' || focus === 'rd:add') && !noted;
  const onActs = focus.startsWith('act:') && !noted;
  const SectionIcon = TYPE_ICONS[section];
  const total = st ? TYPES.reduce((n, s) => n + st.counts[s], 0) : 0;

  const actions: Action[] = shown ? [
    { id: 'act:save', label: t('btn.save'), primary: true, disabled: !dirty || !form || !formOk(form), run: () => { void save(); } },
    ...(live.canWorld ? [{ id: 'act:world', label: t('btn.world'), run: () => { void toWorld(); } }] : []),
    { id: 'act:teleport', label: t('btn.teleport'), run: () => { cue('select'); teleport(); } },
    { id: 'act:delete', label: t('btn.delete'), run: askDelete },
    { id: 'act:close', label: t('btn.close'), run: leave },
  ] : [
    ...(live.canWorld ? [{ id: 'act:world', label: t('btn.world'), primary: true, run: () => { void toWorld(); } }] : []),
    { id: 'act:close', label: t('btn.close'), run: leave },
  ];

  const keys: [string, string][] = [
    ...(live.canWorld ? [['TAB', t('key.world')] as [string, string]] : []),
    ['Q E', t('key.sections')],
    ['Enter', t('key.pick')],
    ['Esc', shown ? t('key.list') : t('btn.close')],
  ];

  return (
    <div className={cls('wcb-root wf wf-bd is-nb', rtl && 'is-rtl', hidden && 'is-hidden', inWorld && 'is-world')} dir={rtl ? 'rtl' : 'ltr'} lang={lang}>
      <div className="wf-scrim" aria-hidden="true" />
      <main className={cls('wf-panel', noted && 'is-dim')}>
        <header className="wf-mast wf-in" style={{ ['--i' as string]: 0 }}>
          <span className="wf-mark">{t('board.title')}</span>
          <span className="wf-mast-rule" aria-hidden="true" />
          {st && <span className="wf-mast-item"><b className="wf-num">{total}</b>{t('mast.places')}</span>}
        </header>
        <Flash flash={flash} />

        {inWorld && (
          <section className="wf-wrap wcb-worldcard">
            <div className="wf-card"><div className="wf-card-body">
              <div className="wf-kicker">{t('btn.world')}</div>
              <p className="wcb-world-line">{t('world.on')}</p>
              {shown && <p className="wcb-world-place"><Txt s={shown.label || shown.id} /></p>}
            </div></div>
          </section>
        )}

        <section className={cls('wf-wrap wf-head-wrap wf-in wcb-headw', onHead && 'is-focus')} style={{ ['--i' as string]: 1 }}>
          <div className="wf-card wf-head">
            <div className="wf-card-body">
              <div className="wf-card-head">
                <div style={{ minWidth: 0 }}>
                  <div className="wf-kicker">{t('board.kicker')}</div>
                  <h2 className="wf-h">{t(`type.${section}`)}</h2>
                </div>
                <div className="wcb-head-end">
                  <Add id="new" nav={nav} label={t('btn.create')} disabled={busy || !st}
                    onClick={() => guard(() => { resume.current = focus; setCreating(true); })} />
                  <SectionIcon />
                </div>
              </div>
              <div className="wcb-tabs" role="tablist">
                {TYPES.map((s) => {
                  const id = `side:${s}`;
                  return (
                    <button key={s} type="button" role="tab" ref={nav.reg(id)} onMouseEnter={nav.hover(id)}
                      aria-selected={section === s}
                      className={cls('wcb-tab', section === s && 'is-active', nav.here(id) && 'is-here')}
                      onClick={() => switchTo(s)}>
                      <span>{t(`tab.${s}`)}</span>
                      {st && <span className="wf-num">{st.counts[s]}</span>}
                    </button>
                  );
                })}
              </div>
            </div>
          </div>
          <i className="wf-tick" aria-hidden="true" />
        </section>

        {!shown ? (
          <section className={cls('wf-wrap wcb-listw wf-in', onList && 'is-focus')} style={{ ['--i' as string]: 2 }}>
            <div className="wf-card">
              <div className="wf-card-body">
                {!st ? <StateLine kind="error" text={errText('generic')} />
                  : places.length === 0 ? <StateLine kind="empty" text={t('empty.places')} />
                    : (
                      <ul className="wf-rows is-scroll">
                        {places.map((p) => {
                          const id = `pl:${p.id}`;
                          const need = listNeeds(p);
                          const opt = listOpt(p);
                          const at = where[p.id]?.coords?.t || p.town;
                          return (
                            <li key={p.id} ref={nav.reg(id)} onMouseEnter={nav.hover(id)}
                              className={cls('wf-row wcb-row', nav.here(id) && 'is-here', picked?.id === p.id && 'is-picked')}
                              onClick={() => openPlace(p.id)}>
                              {p.enabled ? <IconOn /> : <IconOff />}
                              <div className="wf-row-main">
                                <span className="wf-row-name"><Txt s={p.label || p.id} /></span>
                                <span className="wcb-row-where"><Txt s={at || t('where.set')} /></span>
                                <span className={cls('wcb-row-need', need.length > 0 && 'is-miss')}>
                                  {!p.enabled ? t('list.off') : need.length > 0 ? t('rd.need', need.join(t('rd.sep'))) : t('list.ready')}
                                </span>
                                {need.length === 0 && opt.length > 0 && <span className="wcb-row-opt">{t('rd.opt', opt.join(t('rd.sep')))}</span>}
                              </div>
                            </li>
                          );
                        })}
                      </ul>
                    )}
              </div>
            </div>
            <i className="wf-tick" aria-hidden="true" />
          </section>
        ) : (
          <>
            <section className={cls('wf-wrap wcb-placew wf-in', onCard && 'is-focus')} style={{ ['--i' as string]: 2 }}>
              <div className="wf-card">
                <div className="wf-card-body">
                  <div className="wcb-pv-head">
                    <button type="button" ref={nav.reg('pv:back')} onMouseEnter={nav.hover('pv:back')}
                      className={cls('wcb-back', nav.here('pv:back') && 'is-here')} onClick={toList}>
                      <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true"><path d={rtl ? 'M9 6l6 6-6 6' : 'M15 6l-6 6 6 6'} /></svg>
                      <span>{t('pv.back')}</span>
                    </button>
                    <div className="wcb-title">
                      <span className="wcb-title-name"><Txt s={(form?.label.trim() || shown.label || shown.id)} /></span>
                      <span className={cls('wf-tag', shown.enabled && 'is-solid')}>{t(shown.enabled ? 'state.on' : 'state.off')}</span>
                      {shown.usable && <span className="wf-tag">{t('state.usable')}</span>}
                      {dirty && <span className="wf-tag is-hush">{t('tag.unsaved')}</span>}
                    </div>
                  </div>
                  {st && form && (
                    <PlaceCard key={shown.id} place={shown} form={form} board={st} where={where} nav={nav} busy={busy}
                      adv={adv} setAdv={setAdv} chairModel={chairModel} setChairModel={setChairModel}
                      patch={patch} onPlace={(w, m) => { void place(w, m); }} onClear={(w) => { void clear(w); }} />
                  )}
                </div>
              </div>
              <i className="wf-tick" aria-hidden="true" />
            </section>

            <section className={cls('wf-wrap wcb-readyw', onReady && 'is-focus')}>
              <div className="wf-card"><div className="wf-card-body">
                {needs.length > 0 ? (
                  <div className="wcb-ready is-miss">
                    <i className="wcb-dot" aria-hidden="true" />
                    <span>{t('rd.need', needs.map((n) => n.text).join(t('rd.sep')))}</span>
                    <button type="button" ref={nav.reg('rd:fix')} onMouseEnter={nav.hover('rd:fix')}
                      className={cls('wcb-fix', nav.here('rd:fix') && 'is-here')} onClick={() => { cue('select'); needs[0].fix(); }}>
                      {t('rd.fix')}
                    </button>
                  </div>
                ) : (
                  <div className="wcb-ready">
                    <i className="wcb-dot is-ok" aria-hidden="true" />
                    <span>{shown.enabled ? t('rd.ok') : t('rd.okOff')}</span>
                  </div>
                )}
                {optional.length > 0 && (
                  <div className="wcb-ready is-opt">
                    <i className="wcb-dot is-soft" aria-hidden="true" />
                    <span>{t('rd.opt', optional.map((n) => n.text).join(t('rd.sep')))}</span>
                    <button type="button" ref={nav.reg('rd:add')} onMouseEnter={nav.hover('rd:add')}
                      className={cls('wcb-fix is-soft', nav.here('rd:add') && 'is-here')} onClick={() => { cue('select'); optional[0].fix(); }}>
                      {t('rd.add')}
                    </button>
                  </div>
                )}
              </div></div>
            </section>
          </>
        )}

        <ActionStrip actions={actions} nav={nav} focused={onActs} busy={busy} i={4} />
        <div className="wcb-keys" aria-hidden="true">
          {keys.map(([k, label]) => <span key={k}><span className="wcb-key">{k}</span>{label}</span>)}
        </div>

        {ask && (
          <ConfirmNote nav={nav} question={ask.question} sub={ask.sub} yes={ask.yes} no={ask.no}
            onYes={() => { const a = ask; setAsk(null); resume.current = null; cue('select'); a.run(); }}
            onNo={() => { cue('back'); setAsk(null); backFromNote(); }} />
        )}
        {creating && (
          <InputNote nav={nav} title={t('note.createTitle')} hint={t('note.createHint')} initial="" max={LABEL_MAX}
            yes={t('note.confirm')} no={t('note.cancel')} valid={labelOk}
            onSave={(v) => { setCreating(false); resume.current = null; cue('select'); void create(v.trim()); }}
            onCancel={() => { cue('back'); setCreating(false); backFromNote(); }} />
        )}
      </main>
    </div>
  );
}
