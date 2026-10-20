/* ════════════════════════════════════════════════════════════════════════════
 * w_creators · board/Board.tsx - the services board (ops/local/plans/creators-board-contract.md), on the board
 * kit's shell (w_centralbank board/Board.tsx)
 *
 *   masthead     the board's name, and the flash line under it after an answer
 *   side rail    متاجر الملابس · الحلاقون · عيادات التجميل · الخزائن with their counts (Q / E turn them)
 *   a section    its head card («مكان جديد هنا»: a note asks the name -> op create), the list of its places
 *                (name, town, on / off, the spots it has) beside the selected place's card (PlaceCard.tsx),
 *                and the actions strip: حفظ (op save) · انتقل (op teleport) · حذف المكان (asks -> op delete) · إغلاق
 * Selecting: a hover only lights a row; a click, Enter or the keyboard landing on a row selects it (the keyboard
 * only while nothing is left unsaved). Unsaved edits ask before another place, another section or a close.
 * Every call is nuiSend('board:action', { op, args }); an answer's `data` replaces the board at once (an older
 * answer never overwrites a newer one, and a `board` message counts as the newest). A refused op is worded from
 * err.<code> (err.generic otherwise). Escape closes a note first, then the board (nuiSend('board:close')).
 * ════════════════════════════════════════════════════════════════════════════ */

import { useCallback, useEffect, useRef, useState } from 'react';
import { nuiSend } from '../nui';
import { useCursor } from './cursor';
import { Add } from './fields';
import { cls, Txt, useI18n } from './i18n';
import { GlyphDash, GlyphTick, IconOff, IconOn, TYPE_ICONS } from './icons';
import {
  asBoard, formOf, formOk, hasSpot, LABEL_MAX, labelOk, obj, sameForm, saveArgs, SPOTS, TYPES,
  type BoardData, type Form, type Place, type PlaceType, type SpotKind,
} from './model';
import { ConfirmNote, InputNote } from './notes';
import { ActionStrip, Flash, StateLine, useErrorText, useFlash, type Action } from './parts';
import PlaceCard, { type PlaceWhat } from './PlaceCard';
import { cue } from './sound';

interface Answer { ok: boolean; error?: string; data: BoardData | null }

interface AskSpec { question: string; sub?: string; yes: string; no: string; run: () => void }

interface Draft { id: string; base: Form; form: Form }

/* where the admin was, kept between two openings of the board (this page's life only) */
const memory: { section: PlaceType; sel: Partial<Record<PlaceType, string>> } = { section: 'clothing', sel: {} };

export default function Board({ data, rev, hidden, close }: { data: unknown; rev: number; hidden: boolean; close: () => void }) {
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
  useEffect(() => { memory.section = section; memory.sel = sel; }, [section, sel]);

  const places = st ? st.places.filter((p) => p.type === section) : [];
  const picked: Place | null = places.find((p) => p.id === sel[section]) ?? places[0] ?? null;

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
      cursor.setCursor(`side:${s}`);
    });
  };
  const select = (id: string) => {
    if (picked && id === picked.id) { cue('select'); return; }
    guard(() => { cue('select'); setSel((v) => ({ ...v, [section]: id })); });
  };
  const leave = () => guard(() => { cue('close'); close(); });

  const back = () => {
    if (ask) { cue('back'); setAsk(null); backFromNote(); return; }
    if (creating) { cue('back'); setCreating(false); backFromNote(); return; }
    leave();
  };

  const cursor = useCursor({
    open: !hidden,
    rtl,
    initial: picked ? `pl:${picked.id}` : `side:${section}`,
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
      return picked ? `pl:${picked.id}` : `side:${section}`;
    },
  });
  const { nav, focus } = cursor;

  // the keyboard / pad landing on a row selects it (never the mouse passing over it, never over unsaved edits)
  useEffect(() => {
    if (cursor.byMouse() || dirty || !focus.startsWith('pl:')) return;
    const id = focus.slice(3);
    if (picked && id !== picked.id && places.some((p) => p.id === id)) setSel((v) => ({ ...v, [section]: id }));
  }, [focus]); // eslint-disable-line react-hooks/exhaustive-deps

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
      cursor.setCursor(`pl:${made.id}`);
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
          cursor.setCursor('new');
        });
      },
    });
  };

  const place = async (what: PlaceWhat, model?: string) => {
    if (!picked || !form || busy) return;
    const p = picked;
    // unsaved edits (an NPC model chosen above, a new name) are saved first, so the spot is placed with them
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

  /* ── drawing ── */
  const onRail = focus.startsWith('side:') && !noted;
  const onHead = focus === 'new' && !noted;
  const onList = focus.startsWith('pl:') && !noted;
  const onCard = (focus.startsWith('f:') || focus.startsWith('sp:')) && !noted;
  const onActs = focus.startsWith('act:') && !noted;
  const SectionIcon = TYPE_ICONS[section];

  const actions: Action[] = [
    { id: 'act:save', label: t('btn.save'), primary: true, disabled: !picked || !dirty || !form || !formOk(form), run: () => { void save(); } },
    { id: 'act:teleport', label: t('btn.teleport'), disabled: !picked, run: () => { cue('select'); teleport(); } },
    { id: 'act:delete', label: t('btn.delete'), disabled: !picked, run: askDelete },
    { id: 'act:close', label: t('btn.close'), run: leave },
  ];

  return (
    <div className={cls('wcb-root wf wf-bd', rtl && 'is-rtl', hidden && 'is-hidden')} dir={rtl ? 'rtl' : 'ltr'} lang={lang}>
      <div className="wf-scrim" aria-hidden="true" />
      <main className={cls('wf-panel', noted && 'is-dim')}>
        <i className="wf-strip" aria-hidden="true" />

        <header className="wf-mast wf-in" style={{ ['--i' as string]: 0 }}>
          <span className="wf-mark">{t('board.title')}</span>
          <span className="wf-mast-rule" aria-hidden="true" />
        </header>
        <Flash flash={flash} />

        <div className="wf-bd-body">
          <nav className={cls('wf-wrap wf-bd-rail wf-in', onRail && 'is-focus')} style={{ ['--i' as string]: 1 }} aria-label={t('board.title')}>
            <div className="wf-card">
              <div className="wf-card-body">
                <div className="wf-bd-sides" role="tablist" aria-orientation="vertical">
                  {TYPES.map((s) => {
                    const id = `side:${s}`;
                    const Icon = TYPE_ICONS[s];
                    return (
                      <button key={s} type="button" role="tab" ref={nav.reg(id)} onMouseEnter={nav.hover(id)}
                        aria-selected={section === s}
                        className={cls('wf-bd-side', section === s && 'is-active', nav.here(id) && 'is-here')}
                        onClick={() => switchTo(s)}>
                        <Icon className="wf-bd-side-ico" />
                        <span className="wf-bd-side-name">{t(`type.${s}`)}</span>
                        {st && <span className="wf-bd-side-num wf-num">{st.counts[s]}</span>}
                      </button>
                    );
                  })}
                </div>
                <p className="wf-bd-rail-hint">{t('hint.rail')}</p>
              </div>
            </div>
            <i className="wf-tick" aria-hidden="true" />
          </nav>

          <div className="wf-bd-main">
            <section className={cls('wf-wrap wf-head-wrap wf-in', onHead && 'is-focus')} style={{ ['--i' as string]: 2 }}>
              <div className="wf-card wf-head">
                <div className="wf-card-body">
                  <div className="wf-card-head">
                    <div style={{ minWidth: 0 }}>
                      <div className="wf-kicker">{t('board.title')}</div>
                      <h2 className="wf-h">{t(`type.${section}`)}</h2>
                    </div>
                    <div className="wcb-head-end">
                      <Add id="new" nav={nav} label={t('btn.create')} disabled={busy || !st}
                        onClick={() => guard(() => { resume.current = focus; setCreating(true); })} />
                      <SectionIcon />
                    </div>
                  </div>
                </div>
              </div>
              <i className="wf-tick" aria-hidden="true" />
            </section>

            <div className="wcb-split">
              <section className={cls('wf-wrap wcb-list wf-in', onList && 'is-focus')} style={{ ['--i' as string]: 3 }}>
                <div className="wf-card">
                  <div className="wf-card-body">
                    {!st ? <StateLine kind="error" text={errText('generic')} />
                      : places.length === 0 ? <StateLine kind="empty" text={t('empty.places')} />
                        : (
                          <ul className="wf-rows is-scroll">
                            {places.map((p) => {
                              const id = `pl:${p.id}`;
                              return (
                                <li key={p.id} ref={nav.reg(id)} onMouseEnter={nav.hover(id)}
                                  className={cls('wf-row wcb-row', nav.here(id) && 'is-here', picked?.id === p.id && 'is-picked')}
                                  onClick={() => select(p.id)}>
                                  {p.enabled ? <IconOn /> : <IconOff />}
                                  <div className="wf-row-main">
                                    <span className="wf-row-name"><Txt s={p.label || p.id} /></span>
                                    <span className="wf-row-meta">
                                      <span className={cls('wf-tag', p.enabled && 'is-solid')}>{t(p.enabled ? 'state.on' : 'state.off')}</span>
                                      {p.town && <span className="wcb-town"><Txt s={p.town} /></span>}
                                    </span>
                                    <span className="wcb-chips">
                                      {SPOTS[p.type].map((w) => (
                                        <span key={w} className={cls('wcb-chip', hasSpot(p, w) && 'is-on')}>
                                          {hasSpot(p, w) ? <GlyphTick /> : <GlyphDash />}
                                          {t(`spot.${w}`)}
                                        </span>
                                      ))}
                                    </span>
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

              <section className={cls('wf-wrap wcb-place wf-in', onCard && 'is-focus')} style={{ ['--i' as string]: 4 }}>
                <div className="wf-card">
                  <div className="wf-card-body">
                    {st && picked && form ? (
                      <PlaceCard key={picked.id} place={picked} form={form} board={st} nav={nav} busy={busy}
                        patch={patch} onPlace={(w, m) => { void place(w, m); }} onClear={(w) => { void clear(w); }} />
                    ) : (
                      <StateLine kind="empty" text={t('hint.pick')} />
                    )}
                  </div>
                </div>
                <i className="wf-tick" aria-hidden="true" />
              </section>
            </div>

            <ActionStrip actions={actions} nav={nav} focused={onActs} busy={busy} i={5} />
          </div>
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
