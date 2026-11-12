import React, {useEffect, useReducer, useRef, useState} from 'react';
import {nuiSend} from './nui';
import {brandOf} from './brand';
import {Frame, Glyph, KeysRow} from './Chrome';
import SceneCamera from './SceneCamera';
import {MenuRow, NodeView} from './TreeView';
import {
  backAction, cameraFor, createMemory, filterChildren, formatMoney, hasArabic, headingFor, identityDirty, idleRequest, initialIdentity,
  isPending, leadParts, priceLines, readiness, LEAVE_SAVE_NEXT, missingIdentity, modalFor, confirmRequest, nextOpId, openPath, popTarget, recall, searchOrigin, remember, requestReducer, resolvePath, selectedStage,
} from './treeState';

// Navigation memory per editor session id (same id = same path/search/identity after an update).
const memory = createMemory();
export const editorMemory = memory;

// A notebook part (treeState.leadParts / readiness): plain text, or its text with the value in place
// of '%s' (an amount as its own run, a plain value such as field names in the page's direction).
function withAmount(part, amount) {
  if (part === null || part === undefined) return null;
  if (typeof part === 'string') return part;
  const text = String(part.text || '');
  const at = text.indexOf('%s');
  if (at < 0 || part.value === undefined || part.value === null) return text;
  return <>{text.slice(0, at)}{part.plain ? <bdi>{part.value}</bdi> : amount(part.value)}{text.slice(at + 2)}</>;
}

// The appearance editor: renders the Lua node tree generically (§8). Visual identity is the
// original atelier panel; every text comes from payload.strings / the tree.
export default function Editor({payload, onPayload, onClose}) {
  const session = payload.session || {};
  const S = payload.strings || {};
  const sessionId = session.id;
  const saved = recall(memory, sessionId) || {};
  const [path, setPath] = useState(saved.path || []);
  const [search, setSearch] = useState(saved.search || '');
  // the search result list a row was opened from: Back returns to it (treeState.popTarget)
  const [origin, setOrigin] = useState(saved.origin || null);
  const [identity, setIdentity] = useState(saved.identity || initialIdentity(payload.identity));
  const [request, dispatch] = useReducer(requestReducer, idleRequest);
  const [confirm, setConfirm] = useState(null);
  // the store's "save this look as an outfit" name, typed in the save confirmation (optional)
  const [outfitName, setOutfitName] = useState('');
  const [cameraPart, setCameraPart] = useState(payload.camera || 'fullBody');
  // the creator's "hide clothes" view (Lua owns it: payload.hidden / the camera answer)
  const [hidden, setHidden] = useState(!!payload.hidden);
  useEffect(() => { setHidden(!!payload.hidden); }, [payload.hidden]);
  // ★ Per-field identity verdicts from Lua. The rules live in WCIdentity and are asked for while the
  //   player types, so a bad name is caught in the identity tab instead of at the final save.
  const [identityErrors, setIdentityErrors] = useState({});
  const lock = useRef(false), main = useRef(null), returnRow = useRef(null);
  const busy = isPending(request);

  const {nodes, path: validPath} = resolvePath(payload.tree, path);
  const current = nodes[nodes.length - 1] || payload.tree || {};
  const children = filterChildren(current, search);
  const stages = Array.isArray(payload.stages) && payload.stages.length ? payload.stages : null;
  const stage = selectedStage(validPath, stages);
  const missing = missingIdentity(payload.identity, identity);

  useEffect(() => { remember(memory, sessionId, {path: validPath, search, identity, origin}); }, [sessionId, validPath.join('/'), search, identity, origin]);
  // Debounced so a burst of keystrokes is one call; a dropped answer simply leaves the marks as they
  // were — the save still validates server-side, this only tells the player sooner.
  useEffect(() => {
    if (!payload.identity || payload.identity.locked) return undefined;
    const timer = setTimeout(async () => {
      try {
        const result = await nuiSend('editor:identity', {id: sessionId, identity});
        if (result?.ok) setIdentityErrors(result.fields || {});
      } catch { /* never interrupts an appearance edit */ }
    }, 350);
    return () => clearTimeout(timer);
  }, [sessionId, identity.firstname, identity.lastname, identity.dob, payload.identity]);
  useEffect(() => { if (validPath.length !== path.length) setPath(validPath); }, [validPath.join('/'), path.length]);

  const camera = async data => {
    try {
      const result = await nuiSend('editor:camera', {...data, id: sessionId});
      if (result?.ok && result.camera) setCameraPart(result.camera);
      if (result && typeof result.hidden === 'boolean') setHidden(result.hidden);
    } catch { /* a missed camera input never interrupts an appearance edit */ }
  };
  const focusCamera = list => { const preset = cameraFor(list); if (preset) camera({preset}); };
  // entering the clothing stage puts the clothes back on: the player is about to dress the character
  const showClothesFor = next => { if (hidden && next[0] === 'clothing') camera({hide: false}); };

  // Live preview channel. One request in flight at a time and the newest values win, so a drag
  // never queues up behind itself; nothing is dispatched into the request state, so the pad and
  // the sliders stay enabled while the hand is down; and a real action waits for the last
  // preview to land, so Lua never sees two operations at once (it would answer BUSY).
  const previewQ = useRef({inflight: null, latest: undefined});
  const pumpPreview = () => {
    const q = previewQ.current;
    if (q.inflight || q.latest === undefined) return;
    const values = q.latest; q.latest = undefined;
    q.inflight = nuiSend('editor:action', {op: 'preview', values: values || {}, id: sessionId, opId: nextOpId(sessionId)})
      .catch(() => {})
      .finally(() => { q.inflight = null; pumpPreview(); });
  };
  const preview = values => { previewQ.current.latest = values; pumpPreview(); };

  async function action(data) {
    if (lock.current) return false;
    lock.current = true;
    dispatch({type: 'start'});
    try {
      // an unsent frame is dropped, but a queued RESTORE (null) must still land before the action
      const q = previewQ.current;
      if (q.latest !== null) q.latest = undefined;
      while (q.inflight || q.latest !== undefined) { pumpPreview(); await q.inflight; }
      const result = await nuiSend('editor:action', {...data, id: sessionId, opId: nextOpId(sessionId)});
      if (result?.payload) onPayload(result.payload);
      if (result?.ok) dispatch({type: 'success'});
      else dispatch({type: 'error', error: result?.message || S.error || ''});
      if (result?.closed) onClose();
      return !!result?.ok;
    } catch {
      dispatch({type: 'error', error: S.error || ''});
      return false;
    } finally {
      lock.current = false;
      setConfirm(null);
    }
  }

  const handlers = {
    open: node => {
      returnRow.current = null;
      const next = openPath(validPath, node);
      setOrigin(searchOrigin(validPath, next, search));
      setPath(next); setSearch('');
      showClothesFor(next);
      focusCamera(resolvePath(payload.tree, next).nodes);
    },
    set: (control, value) => action({op: 'set', control, value}),
    setMany: values => action({op: 'setMany', values}),
    preview,
    invoke: (control, value) => action({op: 'invoke', control, value}),
    // a destructive action (node.danger) runs only after the confirmation modal
    confirm: node => setConfirm({kind: 'invoke', node, where: current.label}),
  };

  const chooseStage = id => {
    returnRow.current = null;
    setOrigin(null);
    setPath([id]); setSearch('');
    showClothesFor([id]);
    focusCamera(resolvePath(payload.tree, [id]).nodes);
  };

  const save = () => action({op: 'save', identity, ...(payload.saveOutfit && outfitName.trim() ? {outfitName: outfitName.trim()} : {})});
  const back = () => {
    if (lock.current) return;
    // a typed creator identity is unsaved input too: leaving asks Save / Discard / Stay
    const dirty = !!payload.dirty || identityDirty(payload.identity, identity);
    // payload.backDirect: the creator's root Back keeps the look as a draft, so it never asks
    const next = backAction({confirm, pathLength: validPath.length, dirty, search, direct: !!payload.backDirect});
    if (next === 'dismiss') setConfirm(null);
    else if (next === 'clearSearch') setSearch('');
    else if (next === 'pop') {
      returnRow.current = validPath[validPath.length - 1];
      const up = popTarget(validPath, origin);
      setOrigin(null);
      setPath(up.path); setSearch(up.search);
      focusCamera(resolvePath(payload.tree, up.path).nodes);
    } else if (next === 'confirmLeave') setConfirm('leave');
    // the typed name travels with the cancel: the creator keeps it for the next gender it opens
    else action({op: 'cancel', identity});
  };
  const backRef = useRef(back); backRef.current = back;
  useEffect(() => {
    const key = e => { if (e.key === 'Escape') { e.preventDefault(); backRef.current(); } };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, []);

  const viewKey = validPath.join('/') || 'root';
  useEffect(() => {
    if (!main.current) return;
    main.current.scrollTop = 0;
    const rows = Array.from(main.current.querySelectorAll('.menu-row'));
    const target = rows.find(el => el.dataset.navkey === returnRow.current) || rows[0] || main.current;
    target.focus({preventScroll: true}); target.scrollIntoView?.({block: 'nearest'});
  }, [viewKey]);
  const menuKeys = e => {
    if (!e.target.classList.contains('menu-row')) return;
    const rows = Array.from(e.currentTarget.querySelectorAll('.menu-row:not(:disabled)'));
    const i = rows.indexOf(e.target);
    const next = e.key === 'ArrowDown' ? (i + 1) % rows.length : e.key === 'ArrowUp' ? (i + rows.length - 1) % rows.length : e.key === 'Home' ? 0 : e.key === 'End' ? rows.length - 1 : null;
    if (next !== null) { e.preventDefault(); rows[next]?.focus(); }
  };

  const price = payload.price;
  const atRoot = validPath.length === 0;
  // the masthead's "03 / 09" and the hairline progress under the stage index
  const stageIndex = stages ? stages.findIndex(s => s.id === stage) : -1;
  const pad2 = n => String(n).padStart(2, '0');
  const confirmCopy = payload.confirm || {};
  const creatorName = session.mode === 'creator' && payload.identity;
  // what is charged, line by line (store items and dyes, barber services) above the total, in the
  // store's chosen currency
  const money = n => formatMoney(n, price?.currency, S);
  // '$6.00' reads left to right in both languages; a gold amount carries the payload's own word
  // ('0.30 ذهب' / '0.30 gold'), so it takes the direction of that word instead of a forced LTR
  const amountDir = price?.currency === 'gold' ? 'auto' : 'ltr';
  const lines = creatorName ? [] : priceLines(price, S);
  const total = price ? `${S.total || ''} · ${money(price.total)}` : '';
  const saveBody = creatorName
    ? `${identity.firstname} ${identity.lastname}`.trim()
    : [confirmCopy.body, lines.length ? '' : total].filter(Boolean).join(' — ');
  const modal = modalFor(confirm, {strings: S, copy: confirmCopy, saveBody, lines, total: price ? money(price.total) : ''});
  const outfitField = confirm === 'save' && payload.saveOutfit;
  const brand = brandOf(S);
  const rtl = (session.dir || (session.locale === 'ar' ? 'rtl' : 'ltr')) === 'rtl';
  const confirmAction = () => {
    const next = confirmRequest(confirm);
    if (next?.op === 'save') save();
    else if (next) action(next);
  };
  // the notebook lines: what this screen does and costs (head), and whether it is ready (foot)
  const amount = text => <bdi dir={amountDir}>{text}</bdi>;
  const lead = leadParts({mode: session.mode, strings: S, price, wallet: payload.wallet, money});
  const ready = readiness({mode: session.mode, strings: S, payload, identity, identityErrors, money, rtl});
  const fixIdentity = () => chooseStage('identity');

  return <div className="editor-shell" dir={session.dir || (session.locale === 'ar' ? 'rtl' : 'ltr')}>
    <SceneCamera camera={camera} part={cameraPart} text={S} disabled={busy || !!confirm}
      hide={payload.canHide ? {hidden, onToggle: next => camera({hide: next})} : null}/>
    <section className="wst-panel atelier" aria-label={session.title} aria-busy={busy}>
      <div className="wc-mast wf-mast">{brand && <span className="wc-mark wf-mark">{hasArabic(brand) ? <span className="wf-ar">{brand}</span> : brand}</span>}<span className="wc-mast-rule wf-mast-rule" aria-hidden="true"/>{stageIndex >= 0 && <span className="wc-mast-step wf-mast-item" dir="ltr"><b>{pad2(stageIndex + 1)}</b> / {pad2(stages.length)}</span>}</div>
      <div className="wc-card wc-head"><Frame/>
      <header className="wst-header"><h1>{session.title}</h1>{session.subtitle && <p className="wc-sub">{session.subtitle}</p>}
        {lead.length > 0 && <p className="wc-lead">{lead.map((part, i) => <React.Fragment key={i}>{i > 0 && <span className="wc-lead-dot" aria-hidden="true"> · </span>}{withAmount(part, amount)}</React.Fragment>)}</p>}</header>
      {stages && <nav className="atelier-sections" aria-label={S.appearance} style={{'--p': `${stageIndex >= 0 ? (stageIndex + 1) / stages.length * 100 : 0}%`}}>{stages.map((s, i) => <button key={s.id} type="button" disabled={busy || s.disabled} className={`wst-tab ${stage === s.id ? 'selected' : ''}`} aria-current={stage === s.id ? 'page' : undefined} onClick={() => chooseStage(s.id)}><b>{String(i + 1).padStart(2, '0')}</b>{s.label}{s.id === 'identity' && missing && <i/>}</button>)}<span className="wc-progress" aria-hidden="true"><span className="wc-progress-fill"/></span></nav>}
      </div>
      <div className="wc-card wc-work"><Frame/>
      <div className="wst-plate menu-heading">
        {!atRoot && <button className="wst-button menu-back" aria-label={S.back} disabled={busy} onClick={back}><Glyph tex="selection_arrow_left"/></button>}
        <h2>{headingFor(nodes)}</h2>
      </div>
      <main key={viewKey} ref={main} tabIndex={-1} className="editor-workspace" onKeyDown={menuKeys}>
        {current.searchable && <span className="wst-field input-plate search-plate"><input className="wst-input search" aria-label={S.search} placeholder={S.search} value={search} onChange={e => setSearch(e.target.value)}/></span>}
        <fieldset className="fields" disabled={busy}>
          <NodeView node={current} nodes={children} strings={S} disabled={busy} handlers={handlers}
            identity={payload.identity} identityForm={identity} onIdentity={setIdentity} identityErrors={identityErrors}/>
          {atRoot && payload.canRandom && <nav className="menu-list"><div className="wst-rule wc-hr"/><MenuRow id="random" label={S.random} action onClick={() => action({op: 'random'})}/></nav>}
          {current.kind === 'group' && children.length === 0 && <p className="empty-search" role="status">{S.empty}</p>}
        </fieldset>
      </main>
      </div>
      <div className="wc-card wc-foot"><Frame/>
      <footer>
        {request.status === 'error' && request.error && <p className="error" role="alert">{request.error}</p>}
        {payload.saveBlocked && <p className="menu-help save-blocked" role="status">{payload.saveBlocked}</p>}
        {(!atRoot || !stages) && <div className="tools"><button className="wst-button" disabled={busy || !payload.canUndo} onClick={() => action({op: 'undo'})}>{S.undo}</button><button className="wst-button" disabled={busy || !payload.dirty} onClick={() => setConfirm('reset')}>{S.reset}</button></div>}
        {atRoot && stages && !missing && <p className="menu-help">{S.details}</p>}
        {ready && <div className={'wc-ready is-' + ready.tone} role="status"><i className="wc-ready-dot" aria-hidden="true"/><span className="wc-ready-text">{withAmount(ready, amount)}</span>{ready.fix && stages && <button type="button" className="wc-ready-fix" disabled={busy} onClick={fixIdentity}>{S.fixIt}</button>}</div>}
        <div className="commit"><button className="wst-button" disabled={busy} onClick={back}>{atRoot && payload.backLabel ? payload.backLabel : S.back}</button><button className="wst-button primary" disabled={busy || !payload.canSave || missing} onClick={() => setConfirm('save')}>{busy ? S.saving : payload.saveLabel}{price && <span dir={amountDir}>{money(price.total)}</span>}</button></div>
        <KeysRow strings={S}/>
      </footer>
      </div>
    </section>
    {/* 1.1.0: the kit's paper note (wf-note-plate, wf-note-q / -sub, wf-choice), the board dimmed behind it */}
    {modal && <div className="modal-shade"><div className={'wf-note' + (rtl ? ' is-rtl' : '')}><section className="wst-panel confirmation wf-note-plate" role="dialog" aria-modal="true" aria-labelledby="confirmation-title">
      <h2 id="confirmation-title" className="wf-note-q">{modal.title}</h2>
      <p className="wf-note-sub">{modal.body}</p>
      {modal.lines && <dl className="price-lines">{modal.lines.map((l, i) => <div key={i}><dt>{l.label}</dt><dd dir={amountDir}>{l.value}</dd></div>)}<div className="price-total"><dt>{S.total}</dt><dd dir={amountDir}>{modal.total}</dd></div></dl>}
      {outfitField && <label className="save-outfit">{payload.saveOutfit.label}<span className="wst-field input-plate"><input className="wst-input" autoComplete="off" maxLength={payload.saveOutfit.maxLength || undefined} placeholder={payload.saveOutfit.placeholder || undefined} disabled={busy} value={outfitName} onChange={e => setOutfitName(e.target.value)}/></span></label>}
      {confirm === 'leave'
        ? <div className="confirmation-actions wf-note-row">
            <button className="wst-button wf-choice" disabled={busy} onClick={() => setConfirm(null)}>{S.stay}</button>
            <button className="wst-button wf-choice destructive danger" disabled={busy} onClick={() => action({op: 'cancel', identity})}>{S.discard}</button>
            <button className="wst-button wf-choice primary" disabled={busy || !payload.canSave || missing} onClick={() => setConfirm(LEAVE_SAVE_NEXT)}>{payload.saveLabel}{price && <span dir={amountDir}>{money(price.total)}</span>}</button>
          </div>
        : <div className="confirmation-actions wf-note-row">
            <button className="wst-button wf-choice" disabled={busy} onClick={() => setConfirm(null)}>{S.stay}</button>
            <button className={`wst-button wf-choice primary ${confirm === 'save' ? '' : 'destructive danger'}`} disabled={busy} onClick={confirmAction}>{busy ? S.saving : (confirm === 'save' ? confirmCopy.confirmLabel : S.confirm)}</button>
          </div>}
    </section></div></div>}
  </div>;
}
