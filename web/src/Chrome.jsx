import React from 'react';

// The sheet a card stands on: the pause menu's torn-paper card (ink, a paper grain, the torn edge of
// the theme's tear.png as a 9-slice mask, the drop shadow on the outer span because a mask clips its
// own element's shadow). It is a background layer under the card's content, never a wrapper around
// it: a scrolling list inside the card is not re-masked on every scroll step, and nothing in it (a
// focus band, the date chooser) is cut by the torn edge. The confirm dialog's is the paper note.
export function Frame() {
  return <span className="wc-frame wst-frame" aria-hidden="true"><span className="wc-sheet"/></span>;
}

export function Glyph({tex, className=''}) {
  return <span aria-hidden="true" className={`wc-glyph ${className}`} style={{WebkitMaskImage:`var(--tex-${tex})`,maskImage:`var(--tex-${tex})`}}/>;
}

// The keys row at the column's foot: the keys this page answers (arrows move between rows, Enter
// picks, Esc goes back), words from the payload strings.
export function KeysRow({strings: S = {}}) {
  return <p className="wc-keys" aria-hidden="true">
    <span><kbd className="wc-key">↑ ↓</kbd>{S.keyMove}</span>
    <span><kbd className="wc-key">Enter</kbd>{S.keyPick}</span>
    <span><kbd className="wc-key">Esc</kbd>{S.back}</span>
  </p>;
}

export function Choice({label,caption=label,value,options,onChange,disabled=false}) {
  const index=options.findIndex(o=>Number(o.value)===Number(value));
  // a colour choice (skin tone, hair colour) shows the chosen colour as a chip beside its name
  const swatch=index>=0?options[index].swatch:null;
  return <div className={'choice'+(options.some(o=>o.swatch)?' has-swatch':'')}><span className="choice-label">{caption}{swatch&&<i className="choice-swatch" aria-hidden="true" style={{'--swatch':swatch}}/>}</span><div className="choice-control">
    <button type="button" className="wst-button choice-prev" disabled={disabled||index<=0} aria-label={`${label} −`} onClick={()=>onChange(options[index-1].value)}><Glyph tex="selection_arrow_left"/></button>
    {/* The value box (.choice-value) is the pause menu's switch box: a hairline frame around the
        chosen name, cut with an ellipsis when it is long (the full name is its title). */}
    <span className="wst-field choice-value"><select className="wst-input" aria-label={label} title={index>=0?options[index].label:undefined} value={value} disabled={disabled} onChange={e=>onChange(Number(e.target.value))}>{options.map(o=><option key={o.value} value={o.value}>{o.label}</option>)}</select></span>
    <button type="button" className="wst-button choice-next" disabled={disabled||index<0||index>=options.length-1} aria-label={`${label} +`} onClick={()=>onChange(options[index+1].value)}><Glyph tex="selection_arrow_right"/></button>
  </div></div>;
}
