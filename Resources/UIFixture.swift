import Cocoa
@main struct UIFixture {
 static func main(){let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=FixtureDelegate();app.delegate=delegate;app.run()}
}
final class FixtureDelegate:NSObject,NSApplicationDelegate {
 let real=AppDelegate()
 func applicationDidFinishLaunching(_ notification:Notification){real.applicationDidFinishLaunching(notification)
  let root=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ssh-fixture");let session=Session(name:"SSH 测试连接",host:"127.0.0.1",user:NSUserName(),port:22489,key:root.appendingPathComponent("client").path)
  let socket=root.appendingPathComponent("ui-socket").path;let args=["-F","/dev/null","-o","UserKnownHostsFile="+root.appendingPathComponent("known_hosts").path,"-o","StrictHostKeyChecking=yes"]+real.arguments(session,sftp:false)
  let item=NSTabViewItem(identifier:"fixture");item.label="SSH 测试连接";item.view=SSHWorkspace(session:session,args:args,socket:socket);real.tabs.addTabViewItem(item);real.tabs.selectTabViewItem(item);real.updateTabStrip()
 }
 func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{real.applicationShouldTerminate(sender)}
}
