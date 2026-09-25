import React,{useEffect,useRef,useState} from 'react';
import {clampDateParts,composeIsoDate,dateBounds,dateOptionAllowed,parseIsoDate,stepDatePart} from './treeState';

// The date of birth as three parts, day · month · year, in the reading order of the page (in Arabic
// the day stands at the right). It replaces the browser's <input type="date">, which CEF draws as an
// English mm/dd/yyyy with a system calendar whatever the page's language.
//  * Each part is a button: a click (or Enter / Space) opens its chooser inline under the parts,
//    Up / Down step it, PageUp / PageDown move the year by ten, digits type the day or the year.
//  * The chooser offers only the values that can still give a date inside the field's min..max;
//    Escape closes it without also leaving the view (the editor's Escape is Back).
//  * onChange gets 'YYYY-MM-DD' once the date is complete and allowed, else '' (still missing).
// Every word comes from the payload strings (day, month, year, month.1..12); the month names fall
// back to the browser's own locale data, never to copy written here. Figures are Western digits.

const pad2=n=>String(n).padStart(2,'0');
const PARTS=['d','m','y'];
const COLUMNS={d:7,m:3,y:5};
const WIDTH={d:2,m:2,y:4};

const pageLang=()=>(typeof document!=='undefined'&&document.documentElement.lang)||'en';

export function monthName(m,strings){
  const named=strings&&strings['month.'+m];
  if(named)return named;
  try{return new Intl.DateTimeFormat(pageLang(),{month:'long',timeZone:'UTC'}).format(new Date(Date.UTC(2000,m-1,1)));}
  catch{return pad2(m);}
}

export default function DateField({field,value,onChange,disabled,invalid,describedBy,labelledBy,strings}){
  const S=strings||{};
  const bounds=dateBounds(field?.min,field?.max);
  const [parts,setParts]=useState(()=>parseIsoDate(value)||{});
  const [open,setOpen]=useState(null);
  const root=useRef(null),typed=useRef({kind:null,text:'',at:0});
  // a value set from outside (a restored view) shows; a partial pick sends '' and must not wipe itself
  useEffect(()=>{
    const p=parseIsoDate(value);
    if(p&&composeIsoDate(parts,bounds)!==value)setParts(p);
  },[value]);
  useEffect(()=>{if(disabled)setOpen(null);},[disabled]);
  // the chooser opens on the chosen value (the year list is long: it is scrolled to it)
  useEffect(()=>{
    if(!open||!root.current)return;
    const grid=root.current.querySelector('.date-chooser');
    const cell=grid&&(grid.querySelector('.date-cell.is-on:not(:disabled)')||grid.querySelector('.date-cell:not(:disabled)'));
    if(cell){cell.focus({preventScroll:true});if(cell.scrollIntoView)cell.scrollIntoView({block:'nearest'});}
  },[open]);

  const commit=next=>{
    const p=clampDateParts(next);
    setParts(p);
    const iso=composeIsoDate(p,bounds);
    if(iso!==(value||''))onChange(iso);
  };
  const focusPart=k=>{const el=root.current&&root.current.querySelector('.date-'+k);if(el)el.focus({preventScroll:true});};
  const choose=(k,v)=>{commit({...parts,[k]:v});setOpen(null);focusPart(k);};
  const label=k=>k==='d'?S.day:k==='m'?S.month:S.year;
  const text=k=>{
    const v=parts[k];
    if(!Number.isInteger(v))return label(k)||'';
    return k==='m'?monthName(v,S):k==='y'?String(v):pad2(v);
  };

  const partKey=(e,k)=>{
    if(disabled)return;
    if(e.key==='Escape'&&open){e.preventDefault();e.stopPropagation();setOpen(null);return;}
    const step=e.key==='ArrowUp'?1:e.key==='ArrowDown'?-1:0;
    const page=k==='y'&&(e.key==='PageUp'?10:e.key==='PageDown'?-10:0);
    if(step||page){e.preventDefault();commit(stepDatePart(k,parts,step||page,bounds));return;}
    if(/^[0-9]$/.test(e.key)){
      e.preventDefault();
      const t=typed.current,now=Date.now();
      const text=(t.kind===k&&now-t.at<1200?t.text:'')+e.key;
      typed.current={kind:k,text:text.length>=WIDTH[k]?'':text,at:now};
      const n=Number(text);
      if(k==='y'?text.length===4:n>=1&&n<=(k==='m'?12:31))commit({...parts,[k]:n});
    }
  };
  // arrows walk the chooser's grid in its visual order (mirrored in Arabic)
  const gridKey=e=>{
    if(e.key==='Escape'){e.preventDefault();e.stopPropagation();const k=open;setOpen(null);focusPart(k);return;}
    const cells=Array.from(e.currentTarget.querySelectorAll('.date-cell:not(:disabled)'));
    const i=cells.indexOf(document.activeElement);
    if(i<0)return;
    const rtl=getComputedStyle(e.currentTarget).direction==='rtl';
    const all=Array.from(e.currentTarget.querySelectorAll('.date-cell'));
    const at=all.indexOf(cells[i]),cols=COLUMNS[open];
    const move={ArrowRight:rtl?-1:1,ArrowLeft:rtl?1:-1,ArrowDown:cols,ArrowUp:-cols}[e.key];
    let next=null;
    if(move){for(let j=at+move;j>=0&&j<all.length;j+=move){if(!all[j].disabled){next=all[j];break;}}}
    else if(e.key==='Home')next=cells[0];
    else if(e.key==='End')next=cells[cells.length-1];
    else return;
    e.preventDefault();
    if(next){next.focus({preventScroll:true});if(next.scrollIntoView)next.scrollIntoView({block:'nearest'});}
  };

  const values=k=>{
    if(k==='d')return Array.from({length:31},(_,i)=>i+1);
    if(k==='m')return Array.from({length:12},(_,i)=>i+1);
    const out=[];for(let y=bounds.max.y;y>=bounds.min.y;y--)out.push(y);return out;
  };
  const cellText=(k,v)=>k==='m'?monthName(v,S):k==='d'?pad2(v):String(v);

  return <div ref={root} className={'date-field'+(open?' is-open':'')} data-key="dob" role="group"
    aria-labelledby={labelledBy} aria-invalid={invalid?'true':undefined} aria-describedby={describedBy}
    onBlur={e=>{if(open&&root.current&&!root.current.contains(e.relatedTarget))setOpen(null);}}>
    <div className="date-parts">
      {PARTS.map(k=><button key={k} type="button" disabled={disabled}
        className={'date-seg date-'+k+(open===k?' is-open':'')+(Number.isInteger(parts[k])?'':' is-empty')}
        aria-label={label(k)||undefined} aria-haspopup="listbox" aria-expanded={open===k}
        onClick={()=>setOpen(open===k?null:k)} onKeyDown={e=>partKey(e,k)}>{text(k)}</button>)}
    </div>
    {open&&<div className={'date-chooser is-'+open} role="listbox" aria-label={label(open)||undefined} onKeyDown={gridKey}>
      {values(open).map(v=>{
        const on=parts[open]===v;
        return <button key={v} type="button" role="option" aria-selected={on}
          className={'date-cell'+(on?' is-on':'')+(open==='y'&&v%10===0?' is-decade':'')}
          disabled={!dateOptionAllowed(open,v,parts,bounds)} onClick={()=>choose(open,v)}>{cellText(open,v)}</button>;
      })}
    </div>}
  </div>;
}
