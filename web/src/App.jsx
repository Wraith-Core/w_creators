import React,{useEffect,useState} from 'react';
import Editor from './Editor';
import Panel from './Panel';
import CharacterCard from './CharacterCard';

// The messages of §8.1: editor / editorClose, panel / panelClose, charCard.
export default function App(){
 const [editor,setEditor]=useState(null),[panel,setPanel]=useState(null),[card,setCard]=useState(null),[strings,setStrings]=useState({});
 useEffect(()=>{const receive=({data})=>{
  if(!data||typeof data!=='object')return;
  const locale=data.session?.locale||data.locale;
  if(locale){
   document.documentElement.lang=locale;
   document.documentElement.dir=data.session?.dir||data.dir||(locale==='ar'?'rtl':'ltr');
  }
  if(data.type==='editor'){setEditor(data);setCard(null)}
  if(data.type==='editorClose'||data.type==='close')setEditor(null);
  if(data.type==='panel')setPanel(data);
  if(data.type==='panelClose')setPanel(null);
  if(data.type==='charCard'){
   if(data.strings)setStrings(v=>({...v,...data.strings}));
   setCard(data.show===false||data.visible===false||data.isVisible===false?null:(data.data||data));
  }
 };window.addEventListener('message',receive);return()=>window.removeEventListener('message',receive)},[]);
 if(editor)return <Editor key={'e'+editor.session?.id} payload={editor} onPayload={setEditor} onClose={()=>setEditor(null)}/>;
 if(panel)return <Panel key={'p'+panel.session?.id} payload={panel} onPayload={setPanel} onClose={()=>setPanel(null)}/>;
 return card?<CharacterCard data={card} strings={strings}/>:null;
}
