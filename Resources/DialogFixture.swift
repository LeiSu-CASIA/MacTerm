import Cocoa
@main struct DialogFixture {static func main(){let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=DialogDelegate();app.delegate=delegate;app.run()}}
final class DialogDelegate:NSObject,NSApplicationDelegate {
 var editor:SessionEditor!
 func applicationDidFinishLaunching(_ notification:Notification){editor=SessionEditor(session:Session(name:"",host:"",user:NSUserName(),port:22,key:""),isNew:true);editor.window?.title="表单配色验收 · 不保存数据";editor.form.subtitle.stringValue="仅界面检查：此窗口不保存会话数据。";NSApp.activate(ignoringOtherApps:true);_ = editor.run();NSApp.terminate(nil)}
}
