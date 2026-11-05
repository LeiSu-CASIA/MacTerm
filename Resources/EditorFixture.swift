import Cocoa
@main struct EditorFixture {
 static func main(){let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=EditorFixtureDelegate();app.delegate=delegate;app.run()}
}
final class EditorFixtureDelegate:NSObject,NSApplicationDelegate {
 var editor:RemoteEditor!
 func applicationDidFinishLaunching(_ notification:Notification){let text=try! RemoteText(data:Data("# 远程编辑器界面验证（仅内存，不连接服务器）\nserver=example\n标题=中文测试\n".utf8));editor=RemoteEditor(path:"/界面验证/example.conf",text:text,save:{_,_,done in done(.success(()))});editor.window?.title="MacTerm 编辑器界面验证 · 无服务器连接";editor.showWindow(nil);editor.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
 func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
}
