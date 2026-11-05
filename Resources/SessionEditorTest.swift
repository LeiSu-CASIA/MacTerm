import Cocoa
@main struct SessionEditorTests {
 static func main()throws {
  _ = NSApplication.shared
  let editor=SessionEditor(session:Session(name:"test",host:"host.invalid",user:"demo",port:2222,key:"",group:"测试"),isNew:true)
  let form=editor.form
  for size in [NSSize(width:700,height:600),NSSize(width:620,height:412)] {form.setFrameSize(size);form.layoutSubtreeIfNeeded();form.body.layoutSubtreeIfNeeded()
   precondition(form.scroll.frame.minY>=form.save.frame.maxY && form.scroll.frame.maxY<form.subtitle.frame.minY)
   for field in form.body.fields {precondition(field.frame.width>180 && field.frame.minX>=0 && field.frame.maxX<=form.body.bounds.width+1 && field.frame.maxY<=form.body.bounds.height)}
   precondition(!form.scroll.drawsBackground && !form.body.fields[0].frame.intersects(form.body.fields[8].frame))
  }
  precondition(form.body.x11.state == .mixed && SessionEditor.option(form.body.compression)==nil && SessionEditor.option(form.body.agent)==nil)
  form.body.compression.selectItem(at:1);form.body.agent.selectItem(at:2);precondition(SessionEditor.option(form.body.compression)==true && SessionEditor.option(form.body.agent)==false)
  precondition(form.body.commandTTY.frame.maxY<form.body.commandHint.frame.minY && form.body.fields[9].frame.maxY<form.body.commandTTY.frame.minY)
  let configured=SessionEditor(session:Session(name:"configured",host:"host.invalid",user:"",port:0,key:"",compression:false,forwardAgent:true,remoteCommand:"tmux attach",commandTTY:false),isNew:false)
  configured.form.setFrameSize(NSSize(width:700,height:720));configured.form.layoutSubtreeIfNeeded();configured.form.body.layoutSubtreeIfNeeded();precondition(configured.form.body.fields[9].stringValue=="tmux attach" && configured.form.body.commandTTY.state == .off && SessionEditor.option(configured.form.body.compression)==false && SessionEditor.option(configured.form.body.agent)==true);configured.window?.delegate=nil;configured.close()
  let edited=try configured.editedSession();precondition(edited.compression==false && edited.forwardAgent==true && edited.remoteCommand=="tmux attach" && edited.commandTTY==false)
  configured.form.body.fields[9].stringValue="";let cleared=try configured.editedSession();precondition(cleared.remoteCommand==nil && cleared.commandTTY==nil && cleared.x11==nil)
  precondition(editor.window?.appearance?.name == .darkAqua && form.body.fields[1].stringValue=="host.invalid" && form.body.fields[3].stringValue=="2222")
  editor.window?.delegate=nil;editor.close()
  print("PASS: dark session panel, two-column field geometry, small-window scrolling area, no white scroll background, advanced option editing, inherited defaults and command/TTY clearing")
 }
}
