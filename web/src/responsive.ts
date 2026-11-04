// ui-scale (2026-11-04): the whole page follows the screen in CSS now (web/ui-scale.cjs: every px is a
// multiple of --ws-px, 720p .. 8K, ultrawide by height). The old JS --ui-scale step (innerHeight / 1080,
// clamped 1..2) would scale twice, so this file sets nothing; it stays so main.jsx's import keeps working.
export {};
