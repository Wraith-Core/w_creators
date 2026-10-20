/* w_creators · board/main.tsx - mounts the services board as the page's SECOND React root, on
   index.html's <div id="board">, beside the editor's #app (main.jsx imports this file and nothing else from
   board/). Its styles are all scoped under .wcb-root (board.css): the editor's look is never touched. */

import { createRoot } from 'react-dom/client';
import BoardRoot from './Root';
import './board.css';

function host(): HTMLElement {
  const found = document.getElementById('board');
  if (found) return found;
  const el = document.createElement('div');
  el.id = 'board';
  document.body.appendChild(el);
  return el;
}

createRoot(host()).render(<BoardRoot />);
