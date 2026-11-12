import React, {useEffect, useReducer, useRef, useState} from 'react';
import {nuiSend} from './nui';
import {brandOf} from './brand';
import {Frame, Glyph, KeysRow} from './Chrome';
import {NodeView} from './TreeView';
import {
  createMemory, filterChildren, hasArabic, headingFor, idleRequest, isPending, modalFor, openPath, popPath, recall, remember,
  requestReducer, resolvePath,
} from './treeState';

const memory = createMemory();
export const panelMemory = memory;

// WCPanel: the same atelier panel and node tree as the editor, without scene camera or stages
// (clothing actions). Back returns one level; at the root it closes the panel.
export default function Panel({payload, onPayload, onClose}) {
  const session = payload.session || {};
  const S = payload.strings || {};
  const sessionId = session.id;
  const saved = recall(memory, sessionId) || {};
  const [path, setPath] = useState(saved.path || []);
  const [search, setSearch] = useState(saved.search || '');
  const [request, dispatch] = useReducer(requestReducer, idleRequest);
  const [confirm, setConfirm] = useState(null);
  const lock = useRef(false), main = useRef(null);
  const busy = isPending(request);

  const {nodes, path: validPath} = resolvePath(payload.tree, path);
  const current = nodes[nodes.length - 1] || payload.tree || {};
  const children = filterChildren(current, search);
  useEffect(() => { remember(memory, sessionId, {path: validPath, search}); }, [sessionId, validPath.join('/'), search]);

  async function send(event, data) {
    if (lock.current) return;
    lock.current = true;
    dispatch({type: 'start'});
    try {
      const result = await nuiSend(event, {...data, id: sessionId});
      if (result?.payload) onPayload(result.payload);
      if (result?.ok) dispatch({type: 'success'});
      else dispatch({type: 'error', error: result?.message || S.error || ''});
      if (result?.closed) onClose();
    } catch {
      dispatch({type: 'error', error: S.error || ''});
    } finally {
      lock.current = false;
      setConfirm(null);
    }
  }

  const control = (id, value) => send('panel:action', {control: id, value});
  const handlers = {
    open: node => { setPath(openPath(validPath, node)); setSearch(''); },
    set: control, invoke: control,
    // a destructive action (node.danger) runs only after the confirmation modal
    confirm: node => setConfirm({node, where: current.label}),
    setMany: async values => { for (const [id, value] of Object.entries(values)) await control(id, value); },
  };
  const close = () => send('panel:close', {});
  const modal = modalFor(confirm ? {kind: 'invoke', ...confirm} : null, {strings: S});
  const back = () => {
    if (lock.current) return;
    if (confirm) setConfirm(null);
    else if (validPath.length) { setPath(popPath(validPath)); setSearch(''); }
    else close();
  };
  const backRef = useRef(back); backRef.current = back;
  useEffect(() => {
    const key = e => { if (e.key === 'Escape') { e.preventDefault(); backRef.current(); } };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, []);
  const brand = brandOf(S);
  const rtl = (session.dir || (session.locale === 'ar' ? 'rtl' : 'ltr')) === 'rtl';
  const viewKey = validPath.join('/') || 'root';
  useEffect(() => {
    const rows = main.current ? Array.from(main.current.querySelectorAll('.menu-row')) : [];
    (rows[0] || main.current)?.focus({preventScroll: true});
  }, [viewKey]);

  return <div className="editor-shell" dir={session.dir || (session.locale === 'ar' ? 'rtl' : 'ltr')}>
    <section className="wst-panel atelier" aria-label={session.title} aria-busy={busy}>
      <div className="wc-mast wf-mast">{brand && <span className="wc-mark wf-mark">{hasArabic(brand) ? <span className="wf-ar">{brand}</span> : brand}</span>}<span className="wc-mast-rule wf-mast-rule" aria-hidden="true"/></div>
      <div className="wc-card wc-head"><Frame/>
      <header className="wst-header"><h1>{session.title}</h1></header>
      </div>
      <div className="wc-card wc-work"><Frame/>
      <div className="wst-plate menu-heading">
        {validPath.length > 0 && <button className="wst-button menu-back" aria-label={S.back} disabled={busy} onClick={back}><Glyph tex="selection_arrow_left"/></button>}
        <h2>{headingFor(nodes)}</h2>
      </div>
      <main key={viewKey} ref={main} tabIndex={-1} className="editor-workspace">
        {current.searchable && <span className="wst-field input-plate search-plate"><input className="wst-input search" aria-label={S.search} placeholder={S.search} value={search} onChange={e => setSearch(e.target.value)}/></span>}
        <fieldset className="fields" disabled={busy}>
          <NodeView node={current} nodes={children} strings={S} disabled={busy} handlers={handlers}/>
          {current.kind === 'group' && children.length === 0 && <p className="empty-search" role="status">{S.empty}</p>}
        </fieldset>
      </main>
      </div>
      <div className="wc-card wc-foot"><Frame/>
      <footer>
        {request.status === 'error' && request.error && <p className="error" role="alert">{request.error}</p>}
        <div className="commit">{validPath.length > 0 && <button className="wst-button" disabled={busy} onClick={back}>{S.back}</button>}<button className="wst-button primary" disabled={busy} onClick={close}>{S.close}</button></div>
        <KeysRow strings={S}/>
      </footer>
      </div>
    </section>
    {/* 1.1.0: the kit's paper note, as the editor's */}
    {modal && <div className="modal-shade"><div className={'wf-note' + (rtl ? ' is-rtl' : '')}><section className="wst-panel confirmation wf-note-plate" role="dialog" aria-modal="true" aria-labelledby="confirmation-title">
      <h2 id="confirmation-title" className="wf-note-q">{modal.title}</h2>
      <p className="wf-note-sub">{modal.body}</p>
      <div className="confirmation-actions wf-note-row">
        <button className="wst-button wf-choice" disabled={busy} onClick={() => setConfirm(null)}>{S.stay}</button>
        <button className="wst-button wf-choice primary destructive danger" disabled={busy} onClick={() => control(confirm.node.control)}>{busy ? S.saving : S.confirm}</button>
      </div>
    </section></div></div>}
  </div>;
}
