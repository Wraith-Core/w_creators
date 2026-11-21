import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App.jsx';
// 1.1.0: the board kit first (byte-identical to w_train's kit.css), the page's own sheet after it wins the ties
import './kit.css';
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
// The game's own clothing icons (inventory_items, white sketch art): drawn as images in a round disc.
const CLOTH_ICONS = ['bandolier', 'belt', 'boots', 'bracelet', 'bracers', 'chaps', 'cloak', 'coat', 'dress', 'glasses', 'glove', 'gunbelt', 'hair_accs', 'hat', 'holster', 'm_sweater', 'mask', 'neckerchief', 'outfit', 'pants', 'poncho', 'ring', 'satchel', 'scarf', 'shirt', 'skirt', 'socks', 'spats', 'spurs', 'suspenders', 'vest'];
for (const n of CLOTH_ICONS) root.setProperty(`--cloth-${n}`, tex(`tex/cloth/${n}.png`));

// ── The board kit's faces and textures (1.1.0) ──────────────────────────────────────────
// The page no longer links w_lib's theme: the kit's own files (web/public, byte-identical to w_train's)
// are declared here, with ABS_BASE as everything above.
//   EB Garamond    Latin text, titles, labels in small caps   (SIL OFL 1.1, fonts/OFL-EBGaramond.txt)
//   Lalezar        every Arabic face                          (SIL OFL 1.1, fonts/OFL-Lalezar.txt)
//   RDR Lino       the wordmark only
//   RDR Catalogue  the big figures (the character card's money)
// One Arabic face server-wide (owner, 2026-10-22): the role names the kit's stacks use for Arabic
// (Amiri, Tajawal, Noto Sans Arabic, Aref Ruqaa) draw Lalezar's file, so every stack keeps working.
// The torn edge, the grain and the brushed bands are the game's own art (the kit's --tex-* names).
try {
  const FONTS = asset('fonts/');
  const AR = 'U+0600-06FF,U+0750-077F,U+0870-088E,U+0890-0891,U+0897-08E1,U+08E3-08FF,U+FB50-FDFF,U+FE70-FE74,U+FE76-FEFC,U+200C-200E,U+2010-2011,U+0660-0669';
  const lalezar = name => `@font-face { font-family: "${name}"; font-weight: 100 900; src: url("${FONTS}Lalezar-400-arabic.woff2") format("woff2"); unicode-range: ${AR}; font-display: swap; }`;
  const digits = name => `@font-face { font-family: "${name}"; font-weight: 100 900; src: url("${FONTS}RDRCatalogueBold-Bold.woff2") format("woff2"); unicode-range: U+0030-0039; font-display: swap; }`;
  const style = document.createElement('style');
  style.textContent = `
    @font-face { font-family: "EB Garamond"; font-style: normal; font-weight: 400 800; src: url("${FONTS}EBGaramond-latin.woff2") format("woff2"); font-display: swap; }
    @font-face { font-family: "EB Garamond"; font-style: italic; font-weight: 400 800; src: url("${FONTS}EBGaramond-Italic-latin.woff2") format("woff2"); font-display: swap; }
    @font-face { font-family: "RDR Lino"; font-weight: 100 900; src: url("${FONTS}RDRLino-Regular.woff2") format("woff2"); font-display: swap; }
    @font-face { font-family: "RDR Catalogue"; font-weight: 100 900; src: url("${FONTS}RDRCatalogueBold-Bold.woff2") format("woff2"); font-display: swap; }
    ${['Lalezar', 'Amiri', 'Tajawal', 'Noto Sans Arabic', 'Aref Ruqaa'].map(lalezar).join(' ')}
    @font-face { font-family: "EB Garamond"; font-style: normal; font-weight: 400 800; src: url("${FONTS}RDRCatalogueBold-Bold.woff2") format("woff2"); unicode-range: U+0030-0039; font-display: swap; }
    @font-face { font-family: "EB Garamond"; font-style: italic; font-weight: 400 800; src: url("${FONTS}RDRCatalogueBold-Bold.woff2") format("woff2"); unicode-range: U+0030-0039; font-display: swap; }
    ${['RDR Lino', 'Lalezar', 'Amiri', 'Tajawal', 'Noto Sans Arabic', 'Aref Ruqaa'].map(digits).join(' ')}
  `;
  document.head.appendChild(style);
} catch (e) {
  /* a fallback face is enough: the page is never dropped for a font */
}
for (const n of ['tear', 'grain', 'band', 'band-sm']) root.setProperty(`--tex-${n}`, tex(`tex/${n}.png`));

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

import './responsive';
// The services board: its own React root on #board, its own scoped styles (src/board/main.tsx)
import './board/main';
