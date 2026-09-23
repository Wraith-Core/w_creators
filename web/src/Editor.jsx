import React, {useEffect, useReducer, useRef, useState} from 'react';
import {nuiSend} from './nui';
import {BRAND} from './brand';
import {Frame, Glyph} from './Chrome';
import SceneCamera from './SceneCamera';
import {MenuRow, NodeView} from './TreeView';
import {
  backAction, cameraFor, createMemory, filterChildren, formatMoney, headingFor, identityDirty, idleRequest, initialIdentity,
  isPending, priceLines, LEAVE_SAVE_NEXT, missingIdentity, modalFor, confirmRequest, nextOpId, openPath, popPath, recall, remember, requestReducer, resolvePath, selectedStage,
} from './treeState';

// Navigation memory per editor session id (same id = same path/search/identity after an update).
const memory = createMemory();
export const editorMemory = memory;

// The appearance editor: renders the Lua node tree generically (§8). Visual identity is the
// original atelier panel; every text comes from payload.strings / the tree.
export default function Editor({payload, onPayload, onClose}) {
  const session = payload.session || {};
  const S = payload.strings || {};
  const sessionId = session.id;
  const saved = recall(memory, sessionId) || {};
  const [path, setPath] = useState(saved.path || []);
  const [search, setSearch] = useState(saved.search || '');
  const [identity, setIdentity] = useState(saved.identity || initialIdentity(payload.identity));
  const [request, dispatch] = useReducer(requestReducer, idleRequest);
  const [confirm, setConfirm] = useState(null);
  const [cameraPart, setCameraPart] = useState(payload.camera || 'fullBody');
  const lock = useRef(false), main = useRef(null), returnRow = useRef(null);
  const busy = isPending(request);

  const {nodes, path: validPath} = resolvePath(payload.tree, path);
  const current = nodes[nodes.length - 1] || payload.tree || {};
  const children = filterChildren(current, search);
  const stages = Array.isArray(payload.stages) && payload.stages.length ? payload.stages : null;
  const stage = selectedStage(validPath, stages);
  const missing = missingIdentity(payload.identity, identity);

  useEffect(() => { remember(memory, sessionId, {path: validPath, search, identity}); }, [sessionId, validPath.join('/'), search, identity]);
  useEffect(() => { if (validPath.length !== path.length) setPath(validPath); }, [validPath.join('/'), path.length]);

  const camera = async data => {
    try {
      const result = await nuiSend('editor:camera', {...data, id: sessionId});
      if (result?.ok && result.camera) setCameraPart(result.camera);
    } catch { /* a missed camera input never interrupts an appearance edit */ }
  };
  const focusCamera = list => { const preset = cameraFor(list); if (preset) camera({preset}); };

  async function action(data) {
    if (lock.current) return false;
    lock.current = true;
    dispatch({type: 'start'});
    try {
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
      setPath(next); setSearch('');
      focusCamera(resolvePath(payload.tree, next).nodes);
    },
    set: (control, value) => action({op: 'set', control, value}),
    setMany: values => action({op: 'setMany', values}),
    invoke: (control, value) => action({op: 'invoke', control, value}),
    // a destructive action (node.danger) runs only after the confirmation modal
    confirm: node => setConfirm({kind: 'invoke', node, where: current.label}),
  };

  const chooseStage = id => {
    returnRow.current = null;
    setPath([id]); setSearch('');
    focusCamera(resolvePath(payload.tree, [id]).nodes);
  };

  const save = () => action({op: 'save', identity});
  const back = () => {
    if (lock.current) return;
    // a typed creator identity is unsaved input too: leaving asks Save / Discard / Stay
    const dirty = !!payload.dirty || identityDirty(payload.identity, identity);
    const next = backAction({confirm, pathLength: validPath.length, dirty});
    if (next === 'dismiss') setConfirm(null);
    else if (next === 'pop') {
      returnRow.current = validPath[validPath.length - 1];
      const up = popPath(validPath);
      setPath(up); setSearch('');
      focusCamera(resolvePath(payload.tree, up).nodes);
    } else if (next === 'confirmLeave') setConfirm('leave');
    else action({op: 'cancel'});
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
  const confirmCopy = payload.confirm || {};
  const creatorName = session.mode === 'creator' && payload.identity;
  // what is charged, line by line (store items and dyes, barber services) above the total
  const lines = creatorName ? [] : priceLines(price);
  const total = price ? `${S.total || ''} · ${formatMoney(price.total)}` : '';
  const saveBody = creatorName
    ? `${identity.firstname} ${identity.lastname}`.trim()
    : [confirmCopy.body, lines.length ? '' : total].filter(Boolean).join(' — ');
  const modal = modalFor(confirm, {strings: S, copy: confirmCopy, saveBody, lines, total: price ? formatMoney(price.total) : ''});
  const confirmAction = () => {
    const next = confirmRequest(confirm);
    if (next?.op === 'save') save();
    else if (next) action(next);
  };

  return <div className="editor-shell" dir={session.dir || (session.locale === 'ar' ? 'rtl' : 'ltr')}>
    <SceneCamera camera={camera} part={cameraPart} text={S} disabled={busy || !!confirm}/>
    <section className="wst-panel atelier" aria-label={session.title} aria-busy={busy}>
      <Frame/>
      <header className="wst-header"><small className="wst-title atelier-brand">{BRAND}</small><h1>{session.title}</h1>{session.subtitle && <small className="wst-title atelier-brand">{session.subtitle}</small>}<span className="wst-rule header-rule" aria-hidden="true"/></header>
      {stages && <nav className="atelier-sections" aria-label={S.appearance}>{stages.map((s, i) => <button key={s.id} type="button" disabled={busy || s.disabled} className={`wst-tab ${stage === s.id ? 'selected' : ''}`} aria-current={stage === s.id ? 'page' : undefined} onClick={() => chooseStage(s.id)}><b>{String(i + 1).padStart(2, '0')}</b>{s.label}{s.id === 'identity' && missing && <i/>}</button>)}</nav>}
      <div className="wst-plate menu-heading">
        {!atRoot && <button className="wst-button menu-back" aria-label={S.back} disabled={busy} onClick={back}><Glyph tex="selection_arrow_left"/></button>}
        <h2>{headingFor(nodes)}</h2>
      </div>
      <main key={viewKey} ref={main} tabIndex={-1} className="editor-workspace" onKeyDown={menuKeys}>
        {current.searchable && <span className="wst-field input-plate search-plate"><input className="wst-input search" aria-label={S.search} placeholder={S.search} value={search} onChange={e => setSearch(e.target.value)}/></span>}
        <fieldset className="fields" disabled={busy}>
          <NodeView node={current} nodes={children} strings={S} disabled={busy} handlers={handlers}
            identity={payload.identity} identityForm={identity} onIdentity={setIdentity}/>
          {atRoot && payload.canRandom && <nav className="menu-list"><div className="wst-rule wc-hr"/><MenuRow id="random" label={S.random} action onClick={() => action({op: 'random'})}/></nav>}
          {current.kind === 'group' && children.length === 0 && <p className="empty-search" role="status">{S.empty}</p>}
        </fieldset>
      </main>
      <footer>
        {request.status === 'error' && request.error && <p className="error" role="alert">{request.error}</p>}
        {(!atRoot || !stages) && <div className="tools"><button className="wst-button" disabled={busy || !payload.canUndo} onClick={() => action({op: 'undo'})}>{S.undo}</button><button className="wst-button" disabled={busy || !payload.dirty} onClick={() => setConfirm('reset')}>{S.reset}</button></div>}
        {atRoot && stages && <p className="menu-help">{missing ? S.nameHint : S.details}</p>}
        <div className="commit"><button className="wst-button" disabled={busy} onClick={back}>{S.back}</button><button className="wst-button primary" disabled={busy || !payload.canSave || missing} onClick={() => setConfirm('save')}>{busy ? S.saving : payload.saveLabel}{price && <span dir="ltr">{formatMoney(price.total)}</span>}</button></div>
      </footer>
    </section>
    {modal && <div className="modal-shade"><section className="wst-panel confirmation" role="dialog" aria-modal="true" aria-labelledby="confirmation-title"><Frame/>
      <h2 id="confirmation-title">{modal.title}</h2><div className="wst-rule wc-hr"/>
      <p>{modal.body}</p>
      {modal.lines && <dl className="price-lines">{modal.lines.map((l, i) => <div key={i}><dt>{l.label}</dt><dd dir="ltr">{l.value}</dd></div>)}<div className="price-total"><dt>{S.total}</dt><dd dir="ltr">{modal.total}</dd></div></dl>}
      {confirm === 'leave'
        ? <div className="confirmation-actions">
            <button className="wst-button" disabled={busy} onClick={() => setConfirm(null)}>{S.stay}</button>
            <button className="wst-button destructive danger" disabled={busy} onClick={() => action({op: 'cancel'})}>{S.discard}</button>
            <button className="wst-button primary" disabled={busy || !payload.canSave || missing} onClick={() => setConfirm(LEAVE_SAVE_NEXT)}>{payload.saveLabel}{price && <span dir="ltr">{formatMoney(price.total)}</span>}</button>
          </div>
        : <div className="confirmation-actions">
            <button className="wst-button" disabled={busy} onClick={() => setConfirm(null)}>{S.stay}</button>
            <button className={`wst-button primary ${confirm === 'save' ? '' : 'destructive danger'}`} disabled={busy} onClick={confirmAction}>{busy ? S.saving : (confirm === 'save' ? confirmCopy.confirmLabel : S.confirm)}</button>
          </div>}
    </section></div>}
  </div>;
}
