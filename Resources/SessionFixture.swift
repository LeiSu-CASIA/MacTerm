import Cocoa
@main struct SessionFixture {
 static func main(){let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=SessionFixtureDelegate();app.delegate=delegate;app.run()}
}
final class SessionFixtureDelegate:NSObject,NSApplicationDelegate {
 var real:AppDelegate!
 let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("macterm-session-review-"+UUID().uuidString)
 func applicationDidFinishLaunching(_ notification:Notification){
  let storage=root.appendingPathComponent("sessions.json")
  try! SessionStore(url:storage).save([Session(name:"生产数据库",host:"production.example.invalid",user:"demo",port:22,key:"",group:"生产",favorite:true),Session(name:"测试节点",host:"staging.example.invalid",user:"demo",port:2222,key:"",group:"测试",lastUsed:Date()),Session(name:"本地别名",host:"example-alias.invalid",user:"",port:0,key:"")])
  real=AppDelegate(storage:storage);real.applicationDidFinishLaunching(notification);real.window.title="MacTerm 会话验收 · 仅测试数据";real.sidebarSplit.setPosition(360,ofDividerAt:0)
 }
 func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {real.applicationShouldTerminate(sender)}
 func applicationWillTerminate(_ notification:Notification){try? FileManager.default.removeItem(at:root)}
}
