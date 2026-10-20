/* ════════════════════════════════════════════════════════════════════════════
 * w_creators · board/parts.tsx - the pieces the board shares (the board kit's common/parts.tsx)
 *
 *   StateLine     loading / empty / failed
 *   ActionStrip   the actions strip under the cards
 *   useFlash      the short line under the masthead after an answer
 *   useErrorText  an error code in words: err.<code>, else err.generic
 * ════════════════════════════════════════════════════════════════════════════ */

import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import type { Nav } from './cursor';
import { cls, Txt, useI18n } from './i18n';
import { cue } from './sound';

/** loading / empty / failed */
export function StateLine({ kind, text, children }: { kind: 'loading' | 'empty' | 'error'; text: string; children?: ReactNode }) {
  return (
    <div className={cls('wf-state', kind === 'error' && 'is-error')} role={kind === 'error' ? 'alert' : undefined}>
      <span>{text}</span>
      {children}
    </div>
  );
}

export interface Action { id: string; label: string; run: () => void; primary?: boolean; disabled?: boolean }

export function ActionStrip({ actions, nav, focused, busy, i = 4 }: { actions: Action[]; nav: Nav; focused: boolean; busy?: boolean; i?: number }) {
  return (
    <nav className={cls('wf-wrap wf-actions-wrap wf-in', focused && 'is-focus')} style={{ ['--i' as string]: i }}>
      <div className="wf-card wf-actions">
        {actions.map((a) => (
          <button key={a.id} type="button" ref={nav.reg(a.id)} onMouseEnter={nav.hover(a.id)}
            className={cls('wf-act', nav.here(a.id) && 'is-here', a.primary && 'is-primary')}
            aria-disabled={a.disabled || busy || undefined}
            onClick={() => {
              if (busy) return;
              if (a.disabled) { cue('locked'); return; }
              a.run();
            }}>
            {a.label}
          </button>
        ))}
      </div>
    </nav>
  );
}

export interface FlashLine { text: string; error: boolean }

/** The flash line under the masthead: [line, say] - a line stays 2.6 s, an error 4.2 s */
export function useFlash(): [FlashLine | null, (text: string, error?: boolean) => void] {
  const [flash, setFlash] = useState<FlashLine | null>(null);
  const timer = useRef(0);
  useEffect(() => () => window.clearTimeout(timer.current), []);
  const say = useCallback((text: string, error = false) => {
    setFlash({ text, error });
    window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => setFlash(null), error ? 4200 : 2600);
  }, []);
  return [flash, say];
}

export function Flash({ flash }: { flash: FlashLine | null }) {
  if (!flash) return null;
  return <p className={cls('wf-flash', flash.error && 'is-error')} role="status"><Txt s={flash.text} /></p>;
}

/** The words for an error code (the contract: err.<code>); a missing or unknown code reads err.generic */
export function useErrorText() {
  const { t, has } = useI18n();
  return useCallback((code: string | undefined | null) => {
    const key = code ? `err.${code}` : '';
    return key && has(key) ? t(key) : t('err.generic');
  }, [t, has]);
}
