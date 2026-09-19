import React from 'react';
import { CURRENCY_ICONS } from './currencyIcons';
import { Frame } from './Chrome';
const money=n=>(Number(n)||0).toLocaleString('en-US');
export default function CharacterCard({ data, strings: L }) {
  // Five chips of identical structure: a label on one side and a value on the other. The name
  // and the job are texts with no icon, and the balances are numbers with their currency's icon.
  const rows = [
    { key: 'name', label: L.name || '', value: data.name,               text: true },
    { key: 'job',  label: L.job || '',  value: data.job || '',           text: true },
    { key: 'cash', label: L.cash || '', value: '$' + money(data.cash), icon: CURRENCY_ICONS.money },
    { key: 'bank', label: L.bank || '', value: '$' + money(data.bank), icon: CURRENCY_ICONS.money },
    { key: 'gold', label: L.gold || '', value: money(data.gold),       icon: CURRENCY_ICONS.gold },
  ];
  return (
    <div className="charcard">
      <Frame/>
      {rows.map((r, i) => (
        // --i delays each chip's animation behind the one before it so they cascade from the top down
        <div key={r.key} className={'cc-chip cc-row ' + r.key} style={{ '--i': i }}>
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

