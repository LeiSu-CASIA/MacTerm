/* Native review happens before any pasted data reaches the PTY. Keep xterm's
   own paste encoder: intercept its synchronous onData result for preparation. */
(function(root){
  function connect(terminal, bridge) {
    const host=document.getElementById('terminal');
    let enabled=false,canPaste=false,capturing=null,noticeTimer;
    const supported=MacTermRecording.connect(terminal,message=>{
      if(capturing && message.type==='input'){capturing.push(message);return;}
      bridge(message);
    });
    function selection(){const text=terminal.getSelection();return text.length>1048576 || new TextEncoder().encode(text).length>1048576 ? {error:'选区超过 1 MiB，请缩小选区或导出终端文本。'} : {text};}
    const menu=document.createElement('div');menu.id='terminal-menu';menu.setAttribute('role','menu');menu.hidden=true;
    const entries=[['copy','复制选区','⌘C'],['paste','粘贴','⌘V'],['selectAll','全选终端记录','⌘A'],['clearSelection','取消选择',''],['search','搜索记录','⌘F'],['export','导出文本…',''],['clear','清除滚动记录','⌘K'],['reconnect','重新连接 / 启动','⌘R']];
    for(const [action,title,key] of entries){const button=document.createElement('button');button.type='button';button.dataset.action=action;button.setAttribute('role','menuitem');const caption=document.createElement('span'),shortcut=document.createElement('span');caption.textContent=title;shortcut.textContent=key;button.append(caption,shortcut);button.onclick=()=>{hide();if(action==='selectAll'){terminal.selectAll();terminal.focus()}else if(action==='clearSelection'){terminal.clearSelection();terminal.focus()}else{terminal.focus();bridge({type:'terminalAction',action})}};menu.appendChild(button)}
    document.body.appendChild(menu);
    const notice=document.createElement('div');notice.id='terminal-notice';notice.hidden=true;notice.setAttribute('role','status');notice.setAttribute('aria-live','polite');document.body.appendChild(notice);
    function hide(){menu.hidden=true}
    function terminalTarget(target){return target instanceof Node && host.contains(target)}
    function refresh(){for(const button of menu.querySelectorAll('button')){button.disabled=button.dataset.action==='paste' ? !canPaste : ['copy','clearSelection'].includes(button.dataset.action) && !terminal.hasSelection()}}
    document.addEventListener('contextmenu',event=>{
      if(!enabled || (!terminalTarget(event.target) && event.target!==document.body))return;
      event.preventDefault();
      if(terminal.modes.mouseTrackingMode!=='none' && !event.shiftKey)return;
      event.stopImmediatePropagation();refresh();menu.hidden=false;
      menu.style.left=Math.max(4,Math.min(event.clientX,innerWidth-menu.offsetWidth-4))+'px';
      menu.style.top=Math.max(4,Math.min(event.clientY,innerHeight-menu.offsetHeight-4))+'px';
      menu.querySelector('button:not(:disabled)')?.focus();
    },true);
    document.addEventListener('mousedown',event=>{if(!menu.contains(event.target))hide()},true);
    document.addEventListener('keydown',event=>{
      if(!menu.hidden){if(event.key==='Escape'){event.preventDefault();event.stopImmediatePropagation();hide();terminal.focus();return}if(event.key==='Tab'){hide();return}if(event.key==='ArrowDown'||event.key==='ArrowUp'){event.preventDefault();event.stopImmediatePropagation();const buttons=Array.from(menu.querySelectorAll('button:not(:disabled)')),index=buttons.indexOf(document.activeElement);buttons[(index+(event.key==='ArrowDown'?1:-1)+buttons.length)%buttons.length]?.focus();return}}
      if(enabled && terminalTarget(event.target) && event.metaKey && !event.altKey && !event.ctrlKey && event.key.toLowerCase()==='a'){event.preventDefault();event.stopImmediatePropagation();terminal.selectAll()}
    },true);
    document.addEventListener('paste',event=>{
      if(!enabled || !terminalTarget(event.target))return;
      event.preventDefault();event.stopImmediatePropagation();
      if(canPaste && event.clipboardData){const text=event.clipboardData.getData('text/plain');if(text.length>1048576 || new TextEncoder().encode(text).length>1048576 || text.includes('\0')){root.terminalInteractionNotice('粘贴最多 1 MiB，不能包含 NUL 字符。');return}if(text)bridge({type:'pasteRequest',text})}
    },true);
    root.addEventListener('blur',hide);root.addEventListener('resize',hide);
    root.updateTerminalActions=value=>{enabled=value.enabled===true;canPaste=enabled && value.canPaste===true;if(!enabled)hide();refresh()};
    root.selectAllTerminalOrInput=()=>{const element=document.activeElement;if(element && !terminalTarget(element) && ['INPUT','TEXTAREA'].includes(element.tagName)){element.select();return 'field'}terminal.selectAll();return 'terminal'};
    root.terminalSelectionSnapshot=selection;
    root.terminalInteractionNotice=text=>{notice.textContent=String(text).slice(0,512);notice.hidden=false;clearTimeout(noticeTimer);noticeTimer=setTimeout(()=>{notice.hidden=true},5000)};
    root.prepareTerminalPaste=text=>{
      if(!enabled || !canPaste || typeof text!=='string' || text.length>1048576 || new TextEncoder().encode(text).length>1048576 || text.includes('\0'))return null;
      capturing=[];try{terminal.paste(text);const packets=capturing;return packets.length===1 ? packets[0] : null}finally{capturing=null}
    };
    return supported;
  }
  root.MacTermInteraction={connect};
})(globalThis);
