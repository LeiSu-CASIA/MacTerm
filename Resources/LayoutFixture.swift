import Cocoa
@main struct LayoutFixture {
 static func main(){let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=LayoutDelegate();app.delegate=delegate;app.run()}
}
final class LayoutDelegate:NSObject,NSApplicationDelegate {
 let real=AppDelegate()
 func applicationDidFinishLaunching(_ notification:Notification){
  real.applicationDidFinishLaunching(notification)
  for index in 1...2 {
   let session=Session(name:"布局测试 \(index)",host:"layout-test.invalid",user:"test",port:22,key:"")
   let pane=SSHWorkspace(session:session,args:["-V"],socket:NSTemporaryDirectory()+UUID().uuidString)
   pane.timer?.invalidate();pane.remotePath="/test-\(index)";pane.path.stringValue=pane.remotePath
   pane.entries=[RemoteFile(name:"目录 \(index)",size:0,directory:true),RemoteFile(name:"文件 \(index).txt",size:42,directory:false)];pane.files.reloadData()
   let item=NSTabViewItem(identifier:index);item.label=session.name;item.view=pane;real.tabs.addTabViewItem(item)
  }
  real.tabs.selectTabViewItem(at:1);real.updateTabStrip()
 }
 func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{real.applicationShouldTerminate(sender)}
}
