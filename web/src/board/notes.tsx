/* ════════════════════════════════════════════════════════════════════════════
 * w_creators · board/notes.tsx - the paper notes over the panel (the board kit's kit/notes.tsx)
 *
 *   ConfirmNote   «حذف المكان؟» confirm / cancel
 *   InputNote     one line typed on paper (a new place's name), confirm / cancel
 * Every stop's id starts with 'n:': while a note is up only its stops take the cursor (cursor.ts layers).
 * ════════════════════════════════════════════════════════════════════════════ */

import { useEffect, useRef, useState } from 'react';
import type { Nav } from './cursor';
import { cls, Txt } from './i18n';

interface ConfirmProps {
  nav: Nav;
  question: string;
  sub?: string;
  yes: string;
  no: string;
  onYes: () => void;
  onNo: () => void;
}

export function ConfirmNote({ nav, question, sub, yes, no, onYes, onNo }: ConfirmProps) {
  return (
    <div className="wf-note" role="dialog" aria-modal="true">
      <div className="wf-note-plate">
        <p className="wf-note-q"><Txt s={question} /></p>
        {sub && <p className="wf-note-sub"><Txt s={sub} /></p>}
        <div className="wf-note-row">
          <button type="button" ref={nav.reg('n:yes')} className={cls('wf-choice', nav.here('n:yes') && 'is-here')}
            onMouseEnter={nav.hover('n:yes')} onClick={onYes}>{yes}</button>
          <button type="button" ref={nav.reg('n:no')} className={cls('wf-choice', nav.here('n:no') && 'is-here')}
            onMouseEnter={nav.hover('n:no')} onClick={onNo}>{no}</button>
        </div>
      </div>
    </div>
  );
}

interface InputProps {
  nav: Nav;
  title: string;
  hint?: string;
  initial: string;
  max: number;
  yes: string;
  no: string;
  valid: (v: string) => boolean;
  onSave: (v: string) => void;
  onCancel: () => void;
}

export function InputNote({ nav, title, hint, initial, max, yes, no, valid, onSave, onCancel }: InputProps) {
  const [value, setValue] = useState(initial);
  const ref = useRef<HTMLInputElement | null>(null);
  const ok = valid(value);
  useEffect(() => {
    const id = window.setTimeout(() => { ref.current?.focus(); ref.current?.select(); }, 60);
    return () => window.clearTimeout(id);
  }, []);
  return (
    <div className="wf-note" role="dialog" aria-modal="true">
      <div className="wf-note-plate">
        <p className="wf-note-q"><Txt s={title} /></p>
        <input
          ref={(el) => { ref.current = el; nav.reg('n:input')(el); }}
          className={cls('wf-note-input', nav.here('n:input') && 'is-here', !ok && value !== '' && 'is-invalid')}
          value={value} maxLength={max} spellCheck={false} autoComplete="off" dir="auto"
          onMouseEnter={nav.hover('n:input')}
          onFocus={() => nav.focusTo('n:input')}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => {
            // the note answers its own Enter and Escape (the board's cursor would only blur the box)
            if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); if (ok) onSave(value.trim()); }
            else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); onCancel(); }
          }}
        />
        {hint && <p className="wf-note-sub">{hint}</p>}
        <div className="wf-note-row">
          <button type="button" ref={nav.reg('n:save')} className={cls('wf-choice', nav.here('n:save') && 'is-here')}
            aria-disabled={!ok || undefined} onMouseEnter={nav.hover('n:save')} onClick={() => { if (ok) onSave(value.trim()); }}>{yes}</button>
          <button type="button" ref={nav.reg('n:cancel')} className={cls('wf-choice', nav.here('n:cancel') && 'is-here')}
            onMouseEnter={nav.hover('n:cancel')} onClick={onCancel}>{no}</button>
        </div>
      </div>
    </div>
  );
}
