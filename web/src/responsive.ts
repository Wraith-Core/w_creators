// Scale fixed-pixel controls by screen height; ultrawide width must not enlarge them.
function updateInterfaceScale() {
  const scale = Math.max(1, Math.min(2, window.innerHeight / 1080));
  document.documentElement.style.setProperty('--ui-scale', String(scale));
}
updateInterfaceScale();
window.addEventListener('resize', updateInterfaceScale);
