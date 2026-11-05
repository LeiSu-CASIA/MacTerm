import Cocoa
@main struct TunnelFixture {static func main(){let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=TunnelFixtureDelegate();app.delegate=delegate;app.run()}}
final class TunnelFixtureDelegate:NSObject,NSApplicationDelegate {
 var controller:TunnelWindow!
 func applicationDidFinishLaunching(_ notification:Notification){let manager=TunnelManager(host:"ui-test.invalid",socket:"/tmp/no-tunnel-ui-connection",definitions:[TunnelDefinition(name:"数据库转发",kind:.local,listenPort:15432,targetHost:"db.example.invalid",targetPort:5432),TunnelDefinition(name:"远程调试",kind:.remote,listenPort:18080,targetPort:8080),TunnelDefinition(name:"SOCKS 代理",kind:.dynamic,listenPort:1080)],executor:{_,_,_,_ in throw SFTPError.message("仅界面验收，不建立监听")});controller=TunnelWindow(manager:manager,save:{_ in true});controller.window?.title="隧道界面验收 · 不连接服务器，不保存数据";controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
 func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
}
