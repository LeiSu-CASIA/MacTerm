import Cocoa
@main struct TerminalFixture {
 static func main(){let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=TerminalFixtureDelegate();app.delegate=delegate;app.run()}
}
final class TerminalFixtureDelegate:NSObject,NSApplicationDelegate {
 let real=AppDelegate()
 func applicationDidFinishLaunching(_ notification:Notification){real.applicationDidFinishLaunching(notification);real.window.title="MacTerm 终端验收 · 仅本地测试";real.window.setContentSize(NSSize(width:800,height:600));for index in 1...3 {real.addTab("中文长标签测试-\\/\(index)-example-long-session-name",path:"/usr/bin/printf",args:["SEARCH_TARGET 中文测试 \\(index)\\n"])}}
 func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {real.applicationShouldTerminate(sender)}
}
