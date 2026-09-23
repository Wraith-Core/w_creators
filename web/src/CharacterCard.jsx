import React from 'react';
import { CURRENCY_ICONS } from './currencyIcons';
import { Frame } from './Chrome';
const money=n=>(Number(n)||0).toLocaleString('en-US');
const present=v=>v!==undefined&&v!==null&&String(v).trim()!=='';
export default function CharacterCard({ data, strings: L }) {
  // Chips of identical structure: a label on one side and a value on the other. The identity rows
  // are texts with no icon (a row without a value is left out), and the balances are numbers with
  // their currency's icon.
  const rows = [
    { key: 'name',         label: L.name || '',         value: data.name,         text: true },
    { key: 'age',          label: L.age || '',          value: data.age,          text: true, optional: true },
    { key: 'dob',          label: L.dob || '',          value: data.dob,          text: true, optional: true },
    { key: 'gender',       label: L.gender || '',       value: data.gender,       text: true, optional: true },
    { key: 'lastLocation', label: L.lastLocation || '', value: data.lastLocation, text: true, optional: true },
    { key: 'job',          label: L.job || '',          value: data.job || '',    text: true },
    { key: 'cash', label: L.cash || '', value: '$' + money(data.cash), icon: CURRENCY_ICONS.money },
    { key: 'bank', label: L.bank || '', value: '$' + money(data.bank), icon: CURRENCY_ICONS.money },
    { key: 'gold', label: L.gold || '', value: money(data.gold),       icon: CURRENCY_ICONS.gold },
  ].filter(r => !r.optional || present(r.value));
  return (
    <div className="wst-panel charcard">
      <Frame/>
      {rows.map((r, i) => (
        // --i delays each chip's animation behind the one before it so they cascade from the top down
        <div key={r.key} className={'wst-row cc-chip cc-row ' + r.key} style={{ '--i': i }}>
          <span className="cc-label">{r.label}</span>
          <span className="cc-amount">
            <span className={'cc-value' + (r.text ? ' cc-text' : '')}>{r.value}</span>
            {r.icon ? <img className="cc-icon" src={r.icon} alt="" /> : null}
          </span>
        </div>
      ))}
    </div>
  );
}
