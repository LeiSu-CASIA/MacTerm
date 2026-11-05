/* Rendering preferences only. Applying these keeps the existing terminal and PTY. */
(function(root){
  const requiredColors=['background','foreground','cursor','cursorAccent','selectionBackground','selectionForeground','black','red','green','yellow','blue','magenta','cyan','white','brightBlack','brightRed','brightGreen','brightYellow','brightBlue','brightMagenta','brightCyan','brightWhite'];
  const uiColors=['panelBackground','panelBorder','muted','fieldBackground','scrollThumb'];
  function valid(p){
    const hex=v=>typeof v==='string'&&/^#[0-9a-f]{6}$/i.test(v);
    return p&&Number.isInteger(p.fontSize)&&p.fontSize>=9&&p.fontSize<=32&&Number.isFinite(p.lineHeight)&&p.lineHeight>=1&&p.lineHeight<=2&&Number.isInteger(p.scrollback)&&p.scrollback>=0&&p.scrollback<=100000&&typeof p.cursorBlink==='boolean'&&['block','bar','underline'].includes(p.cursorStyle)&&['light','dark'].includes(p.colorScheme)&&typeof p.fontFamily==='string'&&p.fontFamily.length>0&&p.fontFamily.length<=128&&!/[\x00-\x1f\x7f]/.test(p.fontFamily)&&p.theme&&requiredColors.every(key=>hex(p.theme[key]))&&Object.values(p.theme).every(hex)&&p.ui&&uiColors.every(key=>hex(p.ui[key]));
  }
  function apply(terminal,fit,p){
    if(!valid(p))return false;
    terminal.options={theme:{...p.theme},fontFamily:p.fontFamily,fontSize:p.fontSize,lineHeight:p.lineHeight,scrollback:p.scrollback,cursorStyle:p.cursorStyle,cursorBlink:p.cursorBlink};
    const style=document.documentElement.style;style.colorScheme=p.colorScheme;
    const values={'--terminal-bg':p.theme.background,'--terminal-fg':p.theme.foreground,'--accent':p.theme.cursor,'--panel-bg':p.ui.panelBackground,'--panel-border':p.ui.panelBorder,'--muted':p.ui.muted,'--field-bg':p.ui.fieldBackground,'--scroll-thumb':p.ui.scrollThumb};
    Object.entries(values).forEach(([key,value])=>style.setProperty(key,value));
    fit.fit();if(document.fonts&&document.fonts.ready)document.fonts.ready.then(()=>fit.fit());return true;
  }
  root.MacTermPreferences={valid,apply};
})(globalThis);
