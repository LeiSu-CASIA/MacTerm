import Cocoa
@main struct FileBrowserTests {
 static func main(){
  let time=Date(timeIntervalSince1970:1000)
  let fixtures=[RemoteFile(name:"file10.txt",size:10,directory:false,mode:0o100640,modified:time),RemoteFile(name:".secret",size:5,directory:false),RemoteFile(name:"file2.txt",size:200,directory:false,modified:time.addingTimeInterval(20)),RemoteFile(name:"中文目录",size:0,directory:true),RemoteFile(name:"Résumé.TXT",size:30,directory:false)]
  let names:([RemoteFile])->[String]={$0.map{$0.name}}
  let visible=RemoteFileBrowser.visible(fixtures,query:"",showHidden:false,sort:.name)
  precondition(names(visible)==["中文目录","file2.txt","file10.txt","Résumé.TXT"])
  precondition(names(RemoteFileBrowser.visible(fixtures,query:"RESUME",showHidden:true,sort:.name))==["Résumé.TXT"])
  precondition(RemoteFileBrowser.visible(fixtures,query:"不存在",showHidden:true,sort:.size).isEmpty)
  precondition(RemoteFileBrowser.visible(fixtures,query:"",showHidden:true,sort:.size)[1].name=="file2.txt")
  precondition(RemoteFileBrowser.visible(fixtures,query:"",showHidden:true,sort:.modified)[1].name=="file2.txt")
  precondition(names(RemoteFileBrowser.visible(fixtures,query:"file",showHidden:true,sort:.reverseName))==["file10.txt","file2.txt"])
  let app=NSApplication.shared;let properties=RemoteProperties(path:"/home/中文/长路径/file.txt",attributes:RemoteAttributes(size:200,mode:0o100640,uid:501,gid:20,modified:time));precondition(properties.alert.window.appearance?.name == .darkAqua && properties.alert.accessoryView!.fittingSize.width>300)
  let longTarget="../"+String(repeating:"很长的目标目录/",count:1000)+"目标.txt";let linked=RemoteProperties(path:"/test/link",attributes:RemoteAttributes(mode:0o120777),canEditPermissions:true,linkTarget:longTarget);precondition(!linked.canEditPermissions && linked.alert.accessoryView!.fittingSize.height<500)
  let selectedSession=Session(name:"file browser fixture",host:"fixture.invalid",user:"test",port:22,key:"")
  let testBrowser=SSHWorkspace(session:selectedSession,args:["-V"],socket:NSTemporaryDirectory()+UUID().uuidString);testBrowser.timer?.invalidate();defer{testBrowser.stop()}
  testBrowser.allEntries=fixtures;testBrowser.renderFiles();testBrowser.fileFilter.stringValue="file";testBrowser.renderFiles();testBrowser.files.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false);precondition(testBrowser.chosen()?.name=="file10.txt");testBrowser.fileSort.selectItem(at:1);testBrowser.renderFiles();precondition(testBrowser.chosen()?.name=="file10.txt");testBrowser.fileFilter.stringValue="missing";testBrowser.renderFiles();precondition(testBrowser.chosen()==nil)
  testBrowser.fileSidebar.setFrameSize(NSSize(width:260,height:310));testBrowser.fileSidebar.layoutSubtreeIfNeeded();let listFrame=testBrowser.files.enclosingScrollView!.frame
  precondition(listFrame.height>=80 && listFrame.minY>=testBrowser.status.frame.maxY && testBrowser.fileSidebar.fittingSize.height<=310)
  if CommandLine.arguments.contains("--preview") || Bundle.main.bundleIdentifier == "local.macterm.browser-preview" {
   app.setActivationPolicy(.regular)
   let session=Session(name:"本机文件栏预览",host:"fixture.invalid",user:"test",port:22,key:"")
   let pane=SSHWorkspace(session:session,args:["-V"],socket:NSTemporaryDirectory()+UUID().uuidString);pane.timer?.invalidate();pane.remotePath="/home/demo";pane.path.stringValue=pane.remotePath;pane.allEntries=fixtures;pane.renderFiles();pane.fileFilter.stringValue="file";pane.renderFiles();pane.files.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false);precondition(pane.chosen()?.name=="file10.txt");pane.fileSort.selectItem(at:1);pane.renderFiles();precondition(pane.chosen()?.name=="file10.txt");pane.fileFilter.stringValue="missing";pane.renderFiles();precondition(pane.chosen()==nil);pane.fileFilter.stringValue="";pane.fileSort.selectItem(at:0);pane.renderFiles()
   let window=NSWindow(contentRect:NSRect(x:0,y:0,width:270,height:640),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);window.title="文件栏预览 · 无远程连接";window.appearance=NSAppearance(named:.aqua);window.contentView=pane.fileSidebar;window.center();window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true);app.run();pane.stop()
  }
  print("PASS: hidden-file filtering, Unicode case/diacritic matching, natural sorting, size/date sorting with directories first, readonly dark properties, filtered selection identity and compact geometry")
 }
}
