import React from 'react';

// The same eight-piece RDR frame and masked art used by w_inventory / w_crafting.
export function Frame() {
  return <span className="wc-frame wst-frame" aria-hidden="true">{['t','b','l','r','tl','tr','bl','br'].map(p=><span key={p} className={`wc-fr-${p} wst-fr-${p}`}/>)}</span>;
}

export function Glyph({tex, className=''}) {
  return <span aria-hidden="true" className={`wc-glyph ${className}`} style={{WebkitMaskImage:`var(--tex-${tex})`,maskImage:`var(--tex-${tex})`}}/>;
}

export function Choice({label,caption=label,value,options,onChange,disabled=false}) {
  const index=options.findIndex(o=>Number(o.value)===Number(value));
  return <div className="choice"><span className="choice-label">{caption}</span><div className="choice-control">
    <button type="button" className="wst-button choice-prev" disabled={disabled||index<=0} aria-label={`${label} −`} onClick={()=>onChange(options[index-1].value)}><Glyph tex="selection_arrow_left"/></button>
    <select className="wst-input" aria-label={label} value={value} disabled={disabled} onChange={e=>onChange(Number(e.target.value))}>{options.map(o=><option key={o.value} value={o.value}>{o.label}</option>)}</select>
    <button type="button" className="wst-button choice-next" disabled={disabled||index<0||index>=options.length-1} aria-label={`${label} +`} onClick={()=>onChange(options[index+1].value)}><Glyph tex="selection_arrow_right"/></button>
  </div></div>;
}
