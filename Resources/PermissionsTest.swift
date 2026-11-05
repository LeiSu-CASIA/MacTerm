import Cocoa
@main struct PermissionsTests {
 static func main()throws {
  for (value,expected) in [("644",UInt32(0o644)),("0755",0o755),("000",0),("7777",0o7777),(" 640 ",0o640)] {let mode=try RemotePermissions.parse(value);precondition(mode==expected)}
  for value in ["","64","00000","888","0x755","+644","6\n44","７５５","755;id"] {do{_ = try RemotePermissions.parse(value);fatalError("Invalid octal mode accepted")}catch{}}
  let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("macterm-permissions-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let file=root.appendingPathComponent("中文 ' ; file");try Data("unchanged contents".utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
  let socket=ProcessInfo.processInfo.environment["MACTERM_TEST_SOCKET"];let client=try socket.map{try SFTPClient(arguments:SSHWorkspace.fileChannelArguments(host:"permissions-fixture.invalid",socket:$0))} ?? SFTPClient(command:"/usr/libexec/sftp-server",arguments:[]);defer{client.close()};precondition(client.supportsExtension("lsetstat@openssh.com"))
  let before=try client.fileAttributes(file.path);try client.setPermissions(file.path,to:0o640,expected:before);let after=try client.fileAttributes(file.path);let contents=try Data(contentsOf:file);precondition(after.mode&0o7777==0o640 && after.uid==before.uid && after.gid==before.gid && after.modified==before.modified && contents==Data("unchanged contents".utf8))
  do{try client.setPermissions(file.path,to:0o777,expected:before);fatalError("Stale permissions must fail")}catch{};let still=try client.fileAttributes(file.path);precondition(still.mode&0o7777==0o640)
  let directory=root.appendingPathComponent("directory");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false);let child=directory.appendingPathComponent("child");try Data("child".utf8).write(to:child);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:child.path);let dirBefore=try client.fileAttributes(directory.path);try client.setPermissions(directory.path,to:0o1750,expected:dirBefore);let dirAfter=try client.fileAttributes(directory.path);precondition(dirAfter.mode&0o7777==0o1750);let childAfter=try client.fileAttributes(child.path);precondition(childAfter.mode&0o7777==0o600)
  let symbolic=root.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:symbolic,withDestinationURL:file);let symbolicAttrs=try client.fileAttributes(symbolic.path)
  do{try client.setPermissions(symbolic.path,to:0o777,expected:symbolicAttrs);fatalError("Symlink permissions must not affect target")}catch{}
  // Replace the selected file with a symlink after the properties snapshot.
  let selected=root.appendingPathComponent("selected");try Data("original".utf8).write(to:selected);let selectedBefore=try client.fileAttributes(selected.path);try FileManager.default.removeItem(at:selected);try FileManager.default.createSymbolicLink(at:selected,withDestinationURL:file)
  do{try client.setPermissions(selected.path,to:0o777,expected:selectedBefore);fatalError("Replaced symlink must fail")}catch{};let target=try client.fileAttributes(file.path);precondition(target.mode&0o7777==0o640)
  let versions=client.extensionVersions;client.extensionVersions["lsetstat@openssh.com"]=["99"];do{try client.setPermissions(file.path,to:0o777,expected:after);fatalError("Unsupported extension version must fail")}catch{};client.extensionVersions=[:];do{try client.setPermissions(file.path,to:0o777,expected:after);fatalError("Missing extension must fail")}catch{};client.extensionVersions=versions
  do{try client.setPermissions(file.path,to:0o10000,expected:after);fatalError("Out of range bits accepted")}catch{}
  let denied=try SFTPClient(command:"/usr/libexec/sftp-server",arguments:["-P","lsetstat"]);defer{denied.close()};denied.extensionVersions=versions;do{try denied.setPermissions(file.path,to:0o777,expected:after);fatalError("Server request policy must not be bypassed")}catch{}
  let final=try client.fileAttributes(file.path);precondition(final.mode&0o7777==0o640)
  let race=root.appendingPathComponent("race-selected");try Data("before".utf8).write(to:race)
  let racing=try SFTPClient(command:"/usr/bin/python3",arguments:[FileManager.default.currentDirectoryPath+"/Tests/PermissionRaceServer.py",race.path,file.path]);defer{racing.close()};let raceBefore=try racing.fileAttributes(race.path)
  do{try racing.setPermissions(race.path,to:0o777,expected:raceBefore);fatalError("A replacement at the actual mutation must not report success")}catch{}
  let protected=try client.fileAttributes(file.path);precondition(protected.mode&0o7777==0o640);let replaced=try client.fileAttributes(race.path);precondition(replaced.symbolicLink)
  _ = NSApplication.shared
  let panel=RemoteProperties(path:file.path,attributes:final,canEditPermissions:true);precondition(panel.canEditPermissions && !panel.alert.buttons[0].isEnabled)
  panel.permissionField.stringValue="0755";panel.updatePermissionState();precondition(panel.alert.buttons[0].isEnabled)
  panel.permissionField.stringValue="0899";panel.updatePermissionState();precondition(!panel.alert.buttons[0].isEnabled)
  let readonly=RemoteProperties(path:symbolic.path,attributes:symbolicAttrs,canEditPermissions:true);precondition(!readonly.canEditPermissions && readonly.alert.buttons.count==1)
  panel.alert.layout();precondition(panel.alert.accessoryView!.frame.width>300 && panel.alert.window.contentView!.bounds.contains(panel.alert.accessoryView!.frame))
  precondition(panel.alert.window.appearance?.name == .darkAqua)
  print("PASS: octal validation, real file/directory chmod with contents and metadata intact, stale snapshots, symlink and request-time replacement refusal, sticky directory without recursive changes, extension version checks, server policy refusal, property panel validation")
 }
}
