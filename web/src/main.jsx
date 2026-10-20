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
// The game's own clothing icons (inventory_items, white sketch art): drawn as images in a round disc.
const CLOTH_ICONS = ['bandolier', 'belt', 'boots', 'bracelet', 'bracers', 'chaps', 'cloak', 'coat', 'dress', 'glasses', 'glove', 'gunbelt', 'hair_accs', 'hat', 'holster', 'm_sweater', 'mask', 'neckerchief', 'outfit', 'pants', 'poncho', 'ring', 'satchel', 'scarf', 'shirt', 'skirt', 'socks', 'spats', 'spurs', 'suspenders', 'vest'];
for (const n of CLOTH_ICONS) root.setProperty(`--cloth-${n}`, tex(`tex/cloth/${n}.png`));

// The faces are not declared here: index.html links the server's one theme at run time
// (https://cfx-nui-w_lib/nui/assets/wraith-theme.css = w_lib/nui/theme tokens.css + fonts.css +
// base.css), the same Lalezar / Amiri / Tajawal / EB Garamond / RDR Lino files the loading screen and
// the pause menu use, with their licences. It is linked from index.html and not imported here because
// Vite would rewrite its absolute URL; the torn edge and the paper grain come from it too
// (--w-tex-tear, --w-tex-grain).

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
