import Cocoa
@main struct FormFixture {static func main(){let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=FormDelegate();app.delegate=delegate;app.run()}}
final class FormDelegate:NSObject,NSApplicationDelegate {
 let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("macterm-form-"+UUID().uuidString);var real:AppDelegate!
 func applicationDidFinishLaunching(_ notification:Notification){real=AppDelegate(storage:root.appendingPathComponent("sessions.json"));real.applicationDidFinishLaunching(notification);real.window.title="表单修复验证 · 仅测试";real.newSession()}
 func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{real.applicationShouldTerminate(sender)}
 func applicationWillTerminate(_ notification:Notification){try? FileManager.default.removeItem(at:root)}
}
