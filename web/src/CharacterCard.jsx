import React from 'react';
import { Frame } from './Chrome';
import { cardMoney, hasArabic } from './treeState';
const present=v=>v!==undefined&&v!==null&&String(v).trim()!=='';
// The selection card is the pause menu's player card standing upright: a torn sheet with the
// character (citizen id, the name in the title face, the job, then age / date of birth / sex / last
// location on hairlines) and under it the money bar (cash, bank, gold divided by hairlines, figures
// written as the pause menu writes them). Every row keeps its chip markup (wst-row cc-chip cc-row
// <key>) and its place in the DOM; the sheet orders them visually.
export default function CharacterCard({ data, strings: L }) {
  const rows = [
    { key: 'citizenId',    label: L.citizenId || '',    value: data.citizenId,    text: true, optional: true },
    { key: 'name',         label: L.name || '',         value: data.name,         text: true },
    { key: 'age',          label: L.age || '',          value: data.age,          text: true, optional: true },
    { key: 'dob',          label: L.dob || '',          value: data.dob,          text: true, optional: true },
    { key: 'gender',       label: L.gender || '',       value: data.gender,       text: true, optional: true },
    { key: 'lastLocation', label: L.lastLocation || '', value: data.lastLocation, text: true, optional: true },
    { key: 'job',          label: L.job || '',          value: data.job || '',    text: true },
    // a character staff blocked: the reason, or just the notice
    ...(data.blocked ? [{ key: 'blocked', label: L.blocked || '', value: data.blocked === true ? '' : String(data.blocked), text: true }] : []),
    { key: 'cash', label: L.cash || '', value: cardMoney(data.cash, true),  money: true },
    { key: 'bank', label: L.bank || '', value: cardMoney(data.bank, true),  money: true },
    { key: 'gold', label: L.gold || '', value: cardMoney(data.gold, false), money: true },
  ].filter(r => !r.optional || present(r.value)).map((r, i) => ({ ...r, i }));
  const chip = r => (
    // --i delays each chip's rise behind the one before it so they cascade from the top down
    <div key={r.key} className={'wst-row cc-chip cc-row ' + r.key} style={{ '--i': r.i }}>
      <span className="cc-label">{r.label}</span>
      <span className="cc-amount">
        <span className={'cc-value' + (r.text ? ' cc-text' : ' cc-fig') + (hasArabic(r.value) ? ' is-ar' : '')}>{r.value}</span>
      </span>
    </div>
  );
  return (
    <div className="wst-panel charcard">
      <div className="cc-sheet"><Frame/>{rows.filter(r => !r.money).map(chip)}</div>
      <div className="cc-bar"><Frame/>{rows.filter(r => r.money).map(chip)}</div>
    </div>
  );
}
