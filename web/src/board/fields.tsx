/* ════════════════════════════════════════════════════════════════════════════
 * w_creators · board/fields.tsx - the form parts (the board kit's kit/fields.tsx), every one a stop for the
 * cursor.
 *
 *   Field      a text box: the cursor rests on it, Enter (or a click) types into it
 *   NumField   a number box: what is typed stays as typed, the form gets the number whenever it reads as one
 *   Stepper    one of a few (◀ value ▶): Left / Right turn it where the cursor rests
 *   Switch     the pause menu's on / off row
 *   Btn        an inline action on the band («ضع البوت», «إزالة» ...)
 *   Add        "a new one" on the band
 *   Msg        the line under a field: an error (the red mark) or a warning (no red)
 * ════════════════════════════════════════════════════════════════════════════ */

import { useEffect, useState, type ReactNode } from 'react';
import type { Nav } from './cursor';
import { GlyphNext, GlyphPlus, GlyphPrev } from './icons';
import { cls, useI18n } from './i18n';
import { parseNumber } from './model';
import { cue } from './sound';

export interface Message { text: string; level: 'error' | 'warn' }

export function Msg({ m }: { m?: Message }) {
  if (!m) return null;
  return <span className={m.level === 'error' ? 'wf-error' : 'wf-warn'}>{m.text}</span>;
}

interface FieldProps {
  id: string;
  nav: Nav;
  label?: string;
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
  wide?: boolean;
  msg?: Message;
  maxLength?: number;
  /** a Latin name (a ped model): typed left to right in the figures' face */
  latin?: boolean;
}

export function Field({ id, nav, label, value, onChange, placeholder, wide, msg, maxLength, latin }: FieldProps) {
  return (
    <label className={cls('wf-field', wide && 'is-wide')} onMouseEnter={nav.hover(id)}>
      {label && <span className="wf-label">{label}</span>}
      <input
        ref={nav.reg(id) as (el: HTMLInputElement | null) => void}
        className={cls('wf-input', latin && 'is-latin', nav.here(id) && 'is-here', msg?.level === 'error' && 'is-invalid')}
        value={value}
        placeholder={placeholder}
        maxLength={maxLength ?? 100}
        spellCheck={false}
        autoComplete="off"
        dir={latin ? 'ltr' : 'auto'}
        onFocus={() => nav.focusTo(id)}
        onChange={(e) => onChange(e.target.value)}
      />
      <Msg m={msg} />
    </label>
  );
}

interface NumFieldProps {
  id: string;
  nav: Nav;
  label?: string;
  value: number | null;
  onChange: (n: number | null) => void;
  msg?: Message;
  wide?: boolean;
  maxLength?: number;
}

/** What is typed stays as typed while the box holds the keyboard; the form gets the number at once (null while
 *  the box holds no number) */
export function NumField({ id, nav, label, value, onChange, msg, wide, maxLength }: NumFieldProps) {
  const [text, setText] = useState<string | null>(null);
  const shown = value === null ? '' : String(value);
  return (
    <label className={cls('wf-field', wide && 'is-wide')} onMouseEnter={nav.hover(id)}>
      {label && <span className="wf-label">{label}</span>}
      <input
        ref={nav.reg(id) as (el: HTMLInputElement | null) => void}
        className={cls('wf-input is-num', nav.here(id) && 'is-here', msg?.level === 'error' && 'is-invalid')}
        value={text ?? shown}
        maxLength={maxLength ?? 8}
        inputMode="decimal"
        spellCheck={false}
        autoComplete="off"
        onFocus={() => nav.focusTo(id)}
        onBlur={() => setText(null)}
        onChange={(e) => {
          const v = e.target.value;
          setText(v);
          onChange(parseNumber(v));
        }}
      />
      <Msg m={msg} />
    </label>
  );
}

interface StepperProps {
  id: string;
  nav: Nav;
  label?: string;
  options: { value: string; label: string }[];
  value: string;
  onChange: (value: string) => void;
  wide?: boolean;
  msg?: Message;
  locked?: boolean;
  /** the value is a Latin name (a ped model, a profile id) */
  latin?: boolean;
}

export function Stepper({ id, nav, label, options, value, onChange, wide, msg, locked, latin }: StepperProps) {
  const found = options.findIndex((o) => o.value === value);
  const index = Math.max(0, found);
  const step = (delta: number) => {
    if (locked || options.length < 2) { cue('locked'); return; }
    const next = options[(index + delta + options.length) % options.length];
    cue(delta > 0 ? 'navDown' : 'navUp');
    onChange(next.value);
  };

  useEffect(() => {
    nav.regStep(id, step);
    return () => nav.regStep(id, null);
  });

  // The row mirrors with the language: in Arabic the "previous" arrow stands on the right and points right
  // (board.css flips the glyph), the "next" one on the left.
  const text = found >= 0 ? options[found].label : value || '-';
  return (
    <div className={cls('wf-field', wide && 'is-wide')} onMouseEnter={nav.hover(id)}>
      {label && <span className="wf-label">{label}</span>}
      <div ref={nav.reg(id)} className={cls('wf-stepper', nav.here(id) && 'is-here', msg?.level === 'error' && 'is-invalid', locked && 'is-locked')}
        data-kind="stepper" onClick={() => step(1)}>
        <button type="button" className="wf-stepper-arrow" tabIndex={-1}
          onClick={(e) => { e.stopPropagation(); step(-1); }} aria-label="previous">
          <GlyphPrev />
        </button>
        <span className="wf-stepper-value" dir={latin ? 'ltr' : undefined}>{text}</span>
        <button type="button" className="wf-stepper-arrow" tabIndex={-1}
          onClick={(e) => { e.stopPropagation(); step(1); }} aria-label="next">
          <GlyphNext />
        </button>
      </div>
      <Msg m={msg} />
    </div>
  );
}

interface SwitchProps {
  id: string;
  nav: Nav;
  label: string;
  on: boolean;
  onToggle: () => void;
  locked?: boolean;
}

export function Switch({ id, nav, label, on, onToggle, locked }: SwitchProps) {
  const { t } = useI18n();
  return (
    <button
      type="button"
      ref={nav.reg(id)}
      className={cls('wf-switch-row', nav.here(id) && 'is-here', locked && 'is-locked')}
      onMouseEnter={nav.hover(id)}
      onClick={() => {
        if (locked) { cue('locked'); return; }
        cue(on ? 'toggleOff' : 'toggleOn');
        onToggle();
      }}
    >
      <span>{label}</span>
      <span className="wf-switch" data-on={on}>{on ? t('state.on') : t('state.off')}</span>
    </button>
  );
}

interface BtnProps {
  id: string;
  nav: Nav;
  label: string;
  onClick: () => void;
  disabled?: boolean;
  icon?: ReactNode;
  quiet?: boolean;
}

/** An inline action on the band texture (the pause menu's small buttons) */
export function Btn({ id, nav, label, onClick, disabled, icon, quiet }: BtnProps) {
  return (
    <button type="button" ref={nav.reg(id)} className={cls('wf-btn', nav.here(id) && 'is-here', quiet && 'is-quiet')}
      aria-disabled={disabled || undefined} onMouseEnter={nav.hover(id)}
      onClick={() => {
        if (disabled) { cue('locked'); return; }
        cue('select');
        onClick();
      }}>
      {icon}
      <span>{label}</span>
    </button>
  );
}

export function Add({ id, nav, label, onClick, disabled }: { id: string; nav: Nav; label: string; onClick: () => void; disabled?: boolean }) {
  return (
    <button type="button" ref={nav.reg(id)} className={cls('wf-add', nav.here(id) && 'is-here')}
      aria-disabled={disabled || undefined} onMouseEnter={nav.hover(id)}
      onClick={() => {
        if (disabled) { cue('locked'); return; }
        cue('select');
        onClick();
      }}>
      <GlyphPlus />
      <span>{label}</span>
    </button>
  );
}
