/* xterm 5.5 adapter: onUserInput fires synchronously before the corresponding
   onData event. Protocol replies omit that flag. Fail closed if it disappears. */
(function(root){
  function connect(terminal,bridge){
    const service=terminal._core&&terminal._core.coreService;
    let userInput=false;
    const supported=root.MacTermXtermVersion==='5.5.0'&&!!service&&typeof service.onUserInput==='function';
    if(supported)service.onUserInput(()=>{userInput=true});
    terminal.onData(data=>{const recordable=supported&&userInput;userInput=false;bridge({type:'input',data,recordable})});
    terminal.onBinary(()=>bridge({type:'recordingUnsupportedInput'}));
    return supported;
  }
  root.MacTermRecording={connect};
})(globalThis);
