/* ════════════════════════════════════════════════════════════════════════════
 * w_creators · board/Root.tsx - the services board's own React root (#board), beside the editor's (#app)
 *
 * It listens ONLY for the board's three window messages (ops/local/plans/creators-board-contract.md):
 *   board       { data, strings, dir, lang }  open, or replace the data (the board keeps its section / selection)
 *   boardHide   {}                            step aside while a world editor runs: keep the state, show nothing
 *   boardClose  {}                            closed
 * and draws nothing otherwise. The editor's messages (editor, panel, close ...) are never read here.
 * Closing from the page posts nuiSend('board:close', {}) and hides at once.
 * ════════════════════════════════════════════════════════════════════════════ */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { nuiSend } from '../nui';
import Board from './Board';
import { I18nContext, makeI18n, type Lang, type Strings } from './i18n';
import { obj } from './model';
import { cue } from './sound';

interface View { open: boolean; hidden: boolean; session: number; rev: number; data: unknown }

export default function BoardRoot() {
  const [view, setView] = useState<View>({ open: false, hidden: false, session: 0, rev: 0, data: null });
  const [strings, setStrings] = useState<Strings>({});
  const [lang, setLang] = useState<Lang>('ar');
  const [rtl, setRtl] = useState(true);
  const live = useRef({ open: false, session: 0, rev: 0 });

  useEffect(() => {
    const receive = (e: MessageEvent) => {
      const m = obj(e.data);
      if (!m) return;
      const now = live.current;
      if (m.type === 'board') {
        const words = obj(m.strings);
        if (words) {
          const next: Strings = {};
          for (const [k, v] of Object.entries(words)) if (typeof v === 'string') next[k] = v;
          setStrings((s) => ({ ...s, ...next }));
        }
        if (m.lang === 'en' || m.lang === 'ar') setLang(m.lang);
        if (m.dir === 'rtl' || m.dir === 'ltr') setRtl(m.dir === 'rtl');
        else if (m.lang === 'en' || m.lang === 'ar') setRtl(m.lang === 'ar');
        if (!now.open) { now.session += 1; cue('open'); }
        now.open = true;
        now.rev += 1;
        setView({ open: true, hidden: false, session: now.session, rev: now.rev, data: m.data });
      } else if (m.type === 'boardHide') {
        if (now.open) setView((v) => ({ ...v, hidden: true }));
      } else if (m.type === 'boardClose') {
        now.open = false;
        setView((v) => ({ ...v, open: false, hidden: false, data: null }));
      }
    };
    window.addEventListener('message', receive);
    return () => window.removeEventListener('message', receive);
  }, []);

  const close = useCallback(() => {
    live.current.open = false;
    setView((v) => ({ ...v, open: false, hidden: false, data: null }));
    nuiSend('board:close', {}).catch(() => undefined);
  }, []);

  const i18n = useMemo(() => makeI18n(strings, lang, rtl), [strings, lang, rtl]);

  if (!view.open) return null;
  return (
    <I18nContext.Provider value={i18n}>
      <Board key={view.session} data={view.data} rev={view.rev} hidden={view.hidden} close={close} />
    </I18nContext.Provider>
  );
}
