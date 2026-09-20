import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App.jsx';
import './styles.css';

// ── The asset bridge (taken from w_crafting) ─────────────────────────────────────────
// Every asset in web/public (a texture/a font/a sound/a background) must resolve to an **absolute** path through
// ABS_BASE and then be exposed as a CSS variable.
//
// Why absolute: a relative url() stored inside a CSS variable **is not resolved** when it is substituted with var()
// inside mask-image / background - it shows empty in Chrome and in CEF inside the game, even though
// the same relative path works in <img src> or @font-face. And a root path "/tex/..." ignores
// the preview's base and gives a 404. ABS_BASE is correct in every context: the preview, the relative
// build, and inside the game (nui://).
const BASE = import.meta.env.BASE_URL;
const ABS_BASE = new URL(BASE, document.baseURI).href;
const tex = (p) => `url("${ABS_BASE}${p}")`;
const asset = (p) => ABS_BASE + p;

const root = document.documentElement.style;

// The cinematic scene's background (used in the browser only - inside the game the page stays transparent).
root.setProperty('--rsm-backdrop', tex('img/backdrop.jpg'));

// The RDR2 interface art: every texture is exposed as a CSS variable safely with ABS_BASE.
const UI_TEXTURES = [
  'crafting_highlight_t', 'crafting_highlight_b', 'crafting_highlight_l',
  'crafting_highlight_r', 'crafting_highlight_tl', 'crafting_highlight_tr',
  'crafting_highlight_bl', 'crafting_highlight_br', 'crafting_outline',
  'divider_line', 'title_divider', 'vertical_divider_line',
  'list_item_h_line_narrow', 'menu_header_1a', 'selection_box_bg_1a',
  'selection_box_bg_1c', 'toast_bg', 'help_text_bg', 'lock',
  'menu_icon_rank', 'star', 'rating_star', 'cross', 'tick',
  'selection_arrow_left', 'selection_arrow_right', 'weapon_stats_bar',
  'weapon_stats_bar_mask', 'menu_bar', 'swatch_bg_1a', 'counter_bg_1a',
  'satchel_nav_documents', 'shirt', 'hat', 'coat', 'ccoat', 'vest', 'boots',
  'gloves', 'mask', 'gunbelt', 'consumable_hair_tonic', 'consumable_hair_grease',
  'weapon_kit_camera',
];
for (const n of UI_TEXTURES) root.setProperty(`--tex-${n}`, tex(`tex/ui/${n}.png`));

// The official RDR fonts + the Arabic font (Tajawal). @font-face does not read CSS variables,
// so it is built as text with ABS_BASE paths directly.
const AR_RANGE =
  'U+0600-06FF,U+0750-077F,U+0870-089F,U+08A0-08FF,U+FB50-FDFF,U+FE70-FEFF,U+200C-200F,U+2010-2011,U+0660-0669';
const LAT_RANGE = 'U+0000-00FF,U+0131,U+0152-0153,U+2000-206F,U+2074,U+20AC,U+2122,U+2212';
const fontStyle = document.createElement('style');
fontStyle.textContent = `
  @font-face { font-family: "RDR Lino"; src: url("${ABS_BASE}fonts/RDRLino-Regular.woff2") format("woff2"); font-display: swap; }
  @font-face { font-family: "Hapna Slab"; src: url("${ABS_BASE}fonts/HapnaSlabSerif-DemiBold.woff2") format("woff2"); font-display: swap; }
  @font-face { font-family: "RDR Catalogue"; src: url("${ABS_BASE}fonts/RDRCatalogueBold-Bold.woff2") format("woff2"); font-display: swap; }
  @font-face { font-family: "Noto Sans Arabic"; src: url("${ABS_BASE}fonts/NotoSansArabic.woff2") format("woff2"); font-weight: 100 900; font-display: swap; }
  @font-face { font-family: "Tajawal"; font-weight: 400; src: url("${ABS_BASE}fonts/tajawal-arabic-400-normal.woff2") format("woff2"); unicode-range: ${AR_RANGE}; font-display: swap; }
  @font-face { font-family: "Tajawal"; font-weight: 500; src: url("${ABS_BASE}fonts/tajawal-arabic-500-normal.woff2") format("woff2"); unicode-range: ${AR_RANGE}; font-display: swap; }
  @font-face { font-family: "Tajawal"; font-weight: 700; src: url("${ABS_BASE}fonts/tajawal-arabic-700-normal.woff2") format("woff2"); unicode-range: ${AR_RANGE}; font-display: swap; }
  @font-face { font-family: "Tajawal"; font-weight: 400; src: url("${ABS_BASE}fonts/tajawal-latin-400-normal.woff2") format("woff2"); unicode-range: ${LAT_RANGE}; font-display: swap; }
  @font-face { font-family: "Tajawal"; font-weight: 700; src: url("${ABS_BASE}fonts/tajawal-latin-700-normal.woff2") format("woff2"); unicode-range: ${LAT_RANGE}; font-display: swap; }
`;
document.head.appendChild(fontStyle);

// ── The RDR menu sounds ──────────────────────────────────────────────────────
// They are preloaded and cloned when played so fast clicks overlap with no cutting out.
const SOUNDS = ['button', 'coins', 'menu_close', 'menu_open', 'selected'];
const audioPool = {};
for (const name of SOUNDS) {
  const a = new Audio(asset(`sounds/${name}.mp3`));
  a.preload = 'auto';
  a.volume = 0.45;
  audioPool[name] = a;
}
window.uiSound = (name) => {
  const base = audioPool[name];
  if (!base) return;
  try {
    const clip = base.cloneNode();
    clip.volume = base.volume;
    clip.play().catch(() => {});
  } catch (e) {
    /* Playing a sound is not critical - it never stops the interface */
  }
};

// Inside the game the NUI layer must stay transparent so the world shows behind it; the scene's background
// is for the browser preview only.
const IS_GAME =
  typeof window.GetParentResourceName === 'function' ||
  typeof window.invokeNative !== 'undefined' ||
  /CitizenFX/i.test(navigator.userAgent);
if (IS_GAME) document.documentElement.classList.add('rsm-ingame');

createRoot(document.getElementById('app')).render(<App />);

import './store-adapter.css';
import './responsive';
