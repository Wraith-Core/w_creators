import React, {useEffect, useRef, useState} from 'react';
import {nuiSend} from './nui';
import {Frame, Glyph, Choice} from './Chrome';
import SceneCamera from './SceneCamera';

const copy = {
  ar: {
    creator:'إنشاء الشخصية', store:'الخياط', wardrobe:'خزانة الملابس', barber:'الحلاق',
    appearance:'مظهر الشخصية', identity:'الهوية', base:'الهيئة', face:'الملامح', body:'الجسد', hair:'الشعر واللحية', overlays:'تفاصيل البشرة', clothes:'الملابس',
    firstname:'الاسم الأول', lastname:'اسم العائلة', age:'العمر', save:'إنهاء الشخصية', buy:'شراء وارتداء', wear:'ارتداء', cut:'تأكيد الحلاقة',
    cancel:'رجوع', reset:'استعادة الأصل', undo:'تراجع', random:'مظهر عشوائي', search:'بحث…', style:'النمط', color:'اللون', none:'بدون', owned:'مملوكة', total:'الإجمالي',
    saving:'جارٍ التطبيق…', height:'الطول', waist:'الوزن', opacity:'الكثافة', full:'كامل', head:'الوجه', torso:'الجسم', legs:'الساقان', feet:'الحذاء',
    review:'اعتماد المظهر؟', leave:'سيتم إلغاء التعديلات غير المحفوظة.', confirm:'تأكيد', stay:'متابعة التعديل',
    growth:'نمو الشعر', minutes:'دقيقة للمرحلة التالية', hairTime:'الشعر', beardTime:'اللحية', stage:'المرحلة',
    error:'تعذر إكمال الطلب، حاول مجددًا.', empty:'لا توجد نتائج مطابقة.', nameHint:'أكمل اسم الشخصية من قسم الهوية.',
    details:'اختر القسم الذي تريد تعديله.', camera:'الكاميرا',
    clickZoom:'اضغط على جزء لتقريبه', dragRotate:'اسحب للتدوير', rightReset:'زر يمين: الجسم كاملًا',
    eyes:'العينان', nose:'الأنف', mouth:'الفم والشفتان', jaw:'الفك والذقن', cheek:'الخدان', ear:'الأذنان', skull:'الرأس',
  },
  en: {
    creator:'Character creation', store:'Tailor', wardrobe:'Wardrobe', barber:'Barber',
    appearance:'Appearance', identity:'Identity', base:'Heritage', face:'Facial features', body:'Physique', hair:'Hair & beard', overlays:'Complexion', clothes:'Clothing',
    firstname:'First name', lastname:'Last name', age:'Age', save:'Finish character', buy:'Purchase & wear', wear:'Wear outfit', cut:'Confirm haircut',
    cancel:'Back', reset:'Restore original', undo:'Undo', random:'Random appearance', search:'Search…', style:'Style', color:'Colour', none:'None', owned:'Owned', total:'Total',
    saving:'Applying…', height:'Height', waist:'Weight', opacity:'Opacity', full:'Full', head:'Face', torso:'Body', legs:'Legs', feet:'Boots',
    review:'Confirm appearance?', leave:'Unsaved changes will be discarded.', confirm:'Confirm', stay:'Keep editing',
    growth:'Hair growth', minutes:'minutes to next stage', hairTime:'Hair', beardTime:'Beard', stage:'Stage',
    error:'Could not complete the request. Please try again.', empty:'No matching details.', nameHint:'Enter your character’s name under Identity.',
    details:'Choose a feature to change.', camera:'Camera',
    clickZoom:'Click a part to zoom', dragRotate:'Drag to rotate', rightReset:'Right-click: full body',
    eyes:'Eyes', nose:'Nose', mouth:'Mouth & lips', jaw:'Jaw & chin', cheek:'Cheeks', ear:'Ears', skull:'Head',
  },
};
const categoryArt={hats:'hat',shirts_full:'shirt',coats:'coat',coats_closed:'ccoat',vests:'vest',boots:'boots',gloves:'gloves',masks:'mask',gunbelts:'gunbelt'};
const array=v=>Array.isArray(v)?v:[];
const partOf=id=>/eye|brow/i.test(id)?'eyes':/nose|nostril/i.test(id)?'nose':/mouth|lip/i.test(id)?'mouth':/jaw|chin/i.test(id)?'jaw':/cheek/i.test(id)?'cheek':/ear/i.test(id)?'ear':'skull';
const cameraFor=id=>['eyes','eyewear','eyebrows'].includes(id)?'eyes':['heads','teeth','hair','mustache','hats','masks'].includes(id)?'head':['boots','boot_accessories'].includes(id)?'boot':['pants','skirts','chaps','gunbelts'].includes(id)?'pant':'body';

function Slider({name,value,min=-1,max=1,step=.02,onChange}) {
  const [draft,setDraft]=useState(value);
  useEffect(()=>setDraft(value),[value]);
  const commit=()=>{if(Number(draft)!==Number(value))onChange(Number(draft))};
  return <label className="slider-field"><span>{name}<output>{Number(draft).toFixed(step<1?2:0)}</output></span>
    <span className="range-track" style={{'--range-fill':`${(Number(draft)-min)/(max-min)*100}%`}}>
      <input aria-label={name} type="range" min={min} max={max} step={step} value={draft} onChange={e=>setDraft(e.target.value)} onPointerUp={commit} onKeyUp={commit} onBlur={commit}/>
    </span>
  </label>;
}

function MenuRow({id,label,value,art,onClick}) {
  return <button className="menu-row" data-navkey={id} onClick={onClick}>
    {art&&<Glyph tex={art} className="row-art"/>}<span className="row-label">{label}</span>
    {value!=null&&<span className="row-value">{value}</span>}<Glyph tex="selection_arrow_right" className="row-arrow"/>
  </button>;
}

export default function Editor({payload,onPayload,onClose}) {
  const t=copy[payload.locale]||copy.en, isCreator=payload.mode==='creator';
  const rootSection=isCreator?null:payload.mode==='barber'?'hair':'clothes';
  const [tab,setTab]=useState(rootSection),[entry,setEntry]=useState(null),[search,setSearch]=useState('');
  const [busy,setBusy]=useState(false),[error,setError]=useState(''),[confirm,setConfirm]=useState(null);
  const [identity,setIdentity]=useState({firstname:'',lastname:'',age:28});
  const [cameraPart,setCameraPart]=useState(payload.mode==='barber'?'head':'default');
  const lock=useRef(false),latest=useRef(payload),main=useRef(null),returnRow=useRef(null);
  latest.current=payload;
  const app=payload.app||{}, components=app.components||{};
  const tabs=['identity','base','face','body','hair','overlays','clothes'];
  const missingName=isCreator&&(!identity.firstname.trim()||!identity.lastname.trim());
  const saveText=isCreator?t.save:payload.mode==='store'?t.buy:payload.mode==='barber'?t.cut:t.wear;
  const camera=async data=>{
    try {
      const result=await nuiSend('editor:camera',{...data,id:latest.current.id});
      if(result?.ok&&result.part)setCameraPart(result.part);
    } catch { /* A missed camera input must not interrupt an appearance edit. */ }
  };
  async function action(data) {
    if(lock.current)return;
    lock.current=true;setBusy(true);setError('');
    try {
      const result=await nuiSend('editor:action',{...data,id:latest.current.id});
      if(!result?.ok)throw new Error(result?.error||t.error);
      if(result.payload)onPayload(result.payload);
      if(result.closed)onClose();
    } catch(e){setError(e.message==='busy'?t.saving:e.message)}
    finally{lock.current=false;setBusy(false);setConfirm(null)}
  }
  const chooseTab=key=>{
    returnRow.current=null;setTab(key);setEntry(null);setSearch('');
    camera({part:key==='identity'||key==='clothes'?'default':key==='body'?'body':'head'});
  };
  const chooseEntry=(kind,id,part)=>{
    returnRow.current=null;setEntry({kind,id});camera({part});
  };
  const back=()=>{
    if(lock.current)return;
    if(confirm){setConfirm(null);return;}
    if(entry){returnRow.current=entry.id;setEntry(null);return;}
    if(tab&&isCreator){returnRow.current=tab;setTab(null);setSearch('');camera({part:'default'});return;}
    setConfirm('cancel');
  };
  const backRef=useRef(back);backRef.current=back;
  useEffect(()=>{
    const key=e=>{if(e.key==='Escape'){e.preventDefault();backRef.current()}};
    window.addEventListener('keydown',key);return()=>window.removeEventListener('keydown',key);
  },[]);
  const viewKey=`${tab||'root'}/${entry?.kind||''}/${entry?.id||''}`;
  useEffect(()=>{
    if(!main.current)return;
    main.current.scrollTop=0;
    const rows=Array.from(main.current.querySelectorAll('.menu-row'));
    const focus=rows.find(el=>el.dataset.navkey===returnRow.current)||rows[0]||main.current;
    focus.focus({preventScroll:true});focus.scrollIntoView({block:'nearest'});
  },[viewKey]);
  const menuKeys=e=>{
    if(!e.target.classList.contains('menu-row'))return;
    const rows=Array.from(e.currentTarget.querySelectorAll('.menu-row:not(:disabled)'));
    const i=rows.indexOf(e.target);
    const next=e.key==='ArrowDown'?(i+1)%rows.length:e.key==='ArrowUp'?(i+rows.length-1)%rows.length:e.key==='Home'?0:e.key==='End'?rows.length-1:null;
    if(next!==null){e.preventDefault();rows[next]?.focus();}
  };

  const cats=array(payload.categories).filter(c=>c.section===tab&&c.name.toLowerCase().includes(search.toLowerCase()));
  const overlays=array(payload.overlays).filter(o=>o.name.toLowerCase().includes(search.toLowerCase()));
  const features=array(payload.features).filter(f=>f.section===tab&&(!entry||entry.kind!=='face'||partOf(f.id)===entry.id));
  const cat=entry?.kind==='component'?array(payload.categories).find(c=>c.id===entry.id):null;
  const overlay=entry?.kind==='overlay'?array(payload.overlays).find(o=>o.id===entry.id):null;
  const models=array(cat?.models),model=models.find(m=>m.index===cat?.model),variants=array(model?.variants);
  const title=cat?.name||overlay?.name||(entry?.kind==='face'?t[entry.id]:tab?t[tab]:t.appearance);
  const showSearch=!entry&&(tab==='clothes'||tab==='overlays');
  const showList=!entry&&tab!=='identity'&&tab!=='body';
  const showGrowth=payload.growth&&tab==='hair'&&!entry;

  return <div className="editor-shell" dir={payload.locale==='ar'?'rtl':'ltr'}>
    <SceneCamera camera={camera} part={cameraPart} text={t} disabled={busy||!!confirm}/>
    <section className="atelier" aria-label={t[payload.mode]} aria-busy={busy}>
      <header><h1>{t[payload.mode]}</h1><span className="header-rule" aria-hidden="true"/></header>
      <div className="menu-heading">
        {(tab||entry)&&<button className="menu-back" aria-label={t.cancel} disabled={busy} onClick={back}><Glyph tex="selection_arrow_left"/></button>}
        <h2>{title}</h2>
      </div>
      <main key={viewKey} ref={main} tabIndex={-1} className="editor-workspace" onKeyDown={menuKeys}>
        {showSearch&&<span className="input-plate search-plate"><input className="search" aria-label={t.search} placeholder={t.search} value={search} onChange={e=>setSearch(e.target.value)}/></span>}
        <fieldset className="fields" disabled={busy}>
          {!tab&&<nav className="menu-list" aria-label={t.appearance}>
            {tabs.map(key=><MenuRow key={key} id={key} label={t[key]} onClick={()=>chooseTab(key)}/>)}
            <div className="wc-hr"/><MenuRow id="random" label={t.random} onClick={()=>action({action:'random'})}/>
          </nav>}
          {tab==='identity'&&<div className="identity">
            {['firstname','lastname'].map(key=><label key={key}>{t[key]}<span className="input-plate"><input required maxLength={25} autoComplete="off" value={identity[key]} onChange={e=>setIdentity({...identity,[key]:e.target.value})}/></span></label>)}
            <label>{t.age}<span className="input-plate"><input type="number" min={18} max={100} value={identity.age} onChange={e=>setIdentity({...identity,age:e.target.value})}/></span></label>
          </div>}
          {showList&&tab==='face'&&<nav className="menu-list" aria-label={t.face}>
            {['skull','eyes','nose','mouth','jaw','cheek','ear'].filter(id=>features.some(f=>partOf(f.id)===id)).map(id=><MenuRow key={id} id={id} label={t[id]} onClick={()=>chooseEntry('face',id,id==='eyes'?'eyes':'head')}/>)}
          </nav>}
          {showList&&['base','clothes','hair'].includes(tab)&&<nav className="menu-list" aria-label={t[tab]}>
            {cats.map(c=><MenuRow key={c.id} id={c.id} label={c.name} art={categoryArt[c.id]} value={c.section==='clothes'&&!isCreator?(c.owned?t.owned:`$${Number(c.price||0).toFixed(2)}`):null} onClick={()=>chooseEntry('component',c.id,cameraFor(c.id))}/>)}
          </nav>}
          {showList&&tab==='overlays'&&<nav className="menu-list" aria-label={t.overlays}>
            {overlays.map(o=><MenuRow key={o.id} id={o.id} label={o.name} onClick={()=>chooseEntry('overlay',o.id,/eye|shadow/.test(o.id)?'eyes':'head')}/>)}
          </nav>}
          {cat&&<article className="component">
            <Choice caption={t.style} label={`${cat.name} ${t.style}`} value={cat.model} options={[...(!cat.essential?[{value:0,label:t.none}]:[]),...models.map(m=>({value:m.index,label:String(m.index).padStart(2,'0')}))]} onChange={value=>action({action:'component',category:cat.id,model:value,variant:cat.variant})}/>
            <Choice caption={t.color} label={`${cat.name} ${t.color}`} value={cat.variant} disabled={!cat.model} options={variants.map(v=>({value:v.index,label:String(v.index).padStart(2,'0')}))} onChange={value=>action({action:'component',category:cat.id,model:cat.model,variant:value})}/>
          </article>}
          {tab==='body'&&<>
            <Slider name={t.height} value={components.__scale??1} min={.9} max={1.1} step={.005} onChange={value=>action({action:'body',field:'scale',value})}/>
            <Slider name={t.waist} value={components.__waist??11} min={1} max={21} step={1} onChange={value=>action({action:'body',field:'waist',value})}/>
          </>}
          {(tab==='body'||entry?.kind==='face')&&features.map(f=><Slider key={f.hash} name={f.name} value={f.expression?(components.__expressions?.[f.expression]||0):(array(app.faceFeatures).find(v=>v.hash===f.hash)?.index||0)} onChange={value=>action({action:'feature',field:f.id,value})}/>)}
          {overlay&&<article className="component">
            <Choice caption={t.style} label={overlay.name} value={overlay.value.offsetModel} options={[{value:0,label:t.none},...overlay.models.map((m,i)=>({value:m,label:i+1}))]} onChange={value=>action({action:'overlay',category:overlay.id,model:value,color:overlay.value.offsetVariation,opacity:overlay.value.opacity})}/>
            <Choice caption={t.color} label={`${overlay.name} ${t.color}`} value={overlay.value.offsetVariation} disabled={!overlay.value.offsetModel} options={Array.from({length:64},(_,i)=>({value:i+1,label:String(i+1).padStart(2,'0')}))} onChange={value=>action({action:'overlay',category:overlay.id,model:overlay.value.offsetModel,color:value,opacity:overlay.value.opacity})}/>
            <Slider name={t.opacity} min={0} max={1} value={overlay.value.opacity} onChange={value=>action({action:'overlay',category:overlay.id,model:overlay.value.offsetModel,color:overlay.value.offsetVariation,opacity:value})}/>
          </article>}
          {showSearch&&(tab==='overlays'?overlays:cats).length===0&&<p className="empty-search" role="status">{t.empty}</p>}
        </fieldset>
        {showGrowth&&<aside className="growth"><strong>{t.growth}</strong>{['hair','beard'].filter(k=>k!=='beard'||app.isMale).map(k=><p key={k}>{k==='hair'?t.hairTime:t.beardTime} · {t.stage} {payload.growth[k]?.stage||0}<span>{Math.ceil(payload.growth[k]?.remainingMinutes||0)} {t.minutes}</span></p>)}</aside>}
      </main>
      <footer>
        {error&&<p className="error" role="alert">{error}</p>}
        {(tab||!isCreator)&&<div className="tools"><button disabled={busy} onClick={()=>action({action:'undo'})}>{t.undo}</button><button disabled={busy} onClick={()=>setConfirm('reset')}>{t.reset}</button></div>}
        {!tab&&<p className="menu-help">{missingName?t.nameHint:t.details}</p>}
        <div className="commit"><button disabled={busy} onClick={back}>{t.cancel}</button><button className="primary" disabled={busy||missingName} onClick={()=>setConfirm('save')}>{busy?t.saving:saveText}{!isCreator&&<span dir="ltr">${Number(payload.price||0).toFixed(2)}</span>}</button></div>
      </footer>
    </section>
    {confirm&&<div className="modal-shade"><section className="confirmation" role="dialog" aria-modal="true" aria-labelledby="confirmation-title"><Frame/>
      <h2 id="confirmation-title">{confirm==='save'?t.review:confirm==='reset'?t.reset:t.cancel}</h2><div className="wc-hr"/>
      <p>{confirm==='save'?(isCreator?`${identity.firstname} ${identity.lastname}`:`${t.total} · $${Number(payload.price||0).toFixed(2)}`):t.leave}</p>
      <div className="confirmation-actions"><button disabled={busy} onClick={()=>setConfirm(null)}>{t.stay}</button><button className={`primary ${confirm==='save'?'':'destructive'}`} disabled={busy} onClick={()=>action({action:confirm,identity})}>{busy?t.saving:t.confirm}</button></div>
    </section></div>}
  </div>;
}
