/* w_creators · board/i18n.tsx - the board's words. Every one of them comes from Lua (the `board` message's
   `strings`, w_creators' locales): the page carries no dictionary of its own. An id Lua has not sent reads as
   the id itself, so a missing word is seen at once. */

import { createContext, useContext } from 'react';

export type Lang = 'ar' | 'en';
export type Strings = Record<string, string>;

export interface I18n {
  lang: Lang;
  rtl: boolean;
  t: (key: string, ...args: (string | number)[]) => string;
  /** true when Lua sent words for that id */
  has: (key: string) => boolean;
}

/** %s / %d are filled in order, as Lua's string.format does; %% is a percent sign (only in words that take
    arguments: a word without arguments keeps a bare % as it is) */
export function translate(strings: Strings, key: string, args: (string | number)[]): string {
  const raw = typeof strings[key] === 'string' ? strings[key] : key;
  if (args.length === 0) return raw;
  let i = 0;
  return raw.replace(/%%|%[sd]/g, (m) => (m === '%%' ? '%' : String(args[i++] ?? '')));
}

export function makeI18n(strings: Strings, lang: Lang, rtl: boolean): I18n {
  return {
    lang,
    rtl,
    t: (key, ...args) => translate(strings, key, args),
    has: (key) => typeof strings[key] === 'string' && strings[key] !== '',
  };
}

export const I18nContext = createContext<I18n>(makeI18n({}, 'ar', true));

export const useI18n = () => useContext(I18nContext);

export const cls = (...parts: (string | false | null | undefined)[]) => parts.filter(Boolean).join(' ');

/* Text from the server (a place's name, a town) may be Arabic on an English screen or Latin on an Arabic one.
   It is isolated (<bdi>) so its punctuation and figures keep their own direction, and Arabic is marked (.wf-ar)
   so the Latin letter-spacing, small caps and italics of its box never reach Arabic letters. */
const AR_RE = /[؀-ۿݐ-ݿࡰ-ࣿﭐ-﷿ﹰ-﻿]/;
export function Txt({ s }: { s: string | undefined | null }) {
  if (!s) return null;
  return AR_RE.test(s) ? <bdi lang="ar" className="wf-ar">{s}</bdi> : <bdi>{s}</bdi>;
}
