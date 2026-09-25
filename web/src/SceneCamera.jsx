import React,{useEffect,useRef} from 'react';
import {Glyph} from './Chrome';

// hide = { hidden, onToggle }: the creator's "hide clothes" toggle (a view of the look, never a change
// of it) sits in the camera plate with the other view tools; absent in every other mode.
export default function SceneCamera({camera,part,text,disabled,hide}) {
  const drag=useRef(null),frame=useRef(null),rotation=useRef(0),send=useRef(camera);
  send.current=camera;
  const flush=()=>{
    if(frame.current!==null)cancelAnimationFrame(frame.current);
    frame.current=null;
    const value=rotation.current;rotation.current=0;
    if(value)send.current({rotate:value});
  };
  const cancel=()=>{drag.current=null;rotation.current=0;if(frame.current!==null)cancelAnimationFrame(frame.current);frame.current=null;};
  useEffect(()=>cancel,[]);
  useEffect(()=>{if(disabled)cancel();},[disabled]);
  const down=e=>{
    if(disabled||e.button!==0)return;
    drag.current={id:e.pointerId,x:e.clientX,y:e.clientY,lastX:e.clientX,moved:false};
    e.currentTarget.setPointerCapture(e.pointerId);
  };
  const move=e=>{
    const d=drag.current;if(!d||d.id!==e.pointerId||disabled)return;
    if(!d.moved&&Math.hypot(e.clientX-d.x,e.clientY-d.y)<6)return;
    d.moved=true;
    rotation.current+=(e.clientX-d.lastX)*.35;d.lastX=e.clientX;
    if(frame.current===null)frame.current=requestAnimationFrame(flush);
  };
  const up=e=>{
    const d=drag.current;if(!d||d.id!==e.pointerId||e.button!==0)return;
    drag.current=null;flush();
    if(e.currentTarget.hasPointerCapture(e.pointerId))e.currentTarget.releasePointerCapture(e.pointerId);
    if(!disabled&&!d.moved)send.current({pick:{x:e.clientX/window.innerWidth,y:e.clientY/window.innerHeight,aspect:window.innerWidth/window.innerHeight}});
  };
  const reset=e=>{e.preventDefault();cancel();if(!disabled)send.current({reset:true});};
  // The camera preset's name comes from the payload strings (view.<preset>).
  return <>
    <div className="scene-touch" aria-label={text.clickZoom} onPointerDown={down} onPointerMove={move}
      onPointerUp={up} onPointerCancel={cancel} onLostPointerCapture={cancel} onContextMenu={reset}
      onWheel={e=>{if(!disabled&&e.deltaY)send.current({zoom:e.deltaY>0?-2:2});}}/>
    <aside className="scene-tools" aria-label={text.camera}>
      <div className="wst-plate camera-help"><span className="camera-view"><Glyph tex="weapon_kit_camera"/><span aria-live="polite">{text['view.'+part]||text['view.fullBody']}</span></span>
        <span>{text.clickZoom}</span><span>{text.dragRotate}</span><span>{text.rightReset}</span>
        {hide&&<button type="button" className={'wst-button camera-toggle'+(hide.hidden?' selected':'')} aria-pressed={!!hide.hidden}
          disabled={disabled} onClick={()=>hide.onToggle(!hide.hidden)}>{hide.hidden?text.showClothes:text.hideClothes}</button>}
      </div>
    </aside>
  </>;
}
