import Cocoa
@main struct EditorTests {
 static func main()throws {
  _ = NSApplication.shared
  for (encoding,bom) in [(String.Encoding.utf8,Data()),(.utf8,Data([0xef,0xbb,0xbf])),(.utf16LittleEndian,Data([0xff,0xfe])),(.utf16BigEndian,Data([0xfe,0xff]))] {
   let string="中文 👩‍💻\r\nsecond\n";let bytes=bom+string.data(using:encoding)!;let decoded=try RemoteText(data:bytes);precondition(decoded.text==string);let encoded=try decoded.encode(decoded.text);precondition(encoded==bytes)
  }
  for bad in [Data([0,1,2]),Data([0xff,0x80,0x80]),Data(repeating:65,count:RemoteText.maximumBytes+1)] {do {_ = try RemoteText(data:bad);fatalError("Invalid text must fail")}catch{}}
  let model=try RemoteText(data:Data("original\r\n".utf8));var completion:((Result<Void,Error>)->Void)?;var baseline=Data()
  let editor=RemoteEditor(path:"/test/editor",text:model,save:{_,expected,done in baseline=expected;completion=done})
  precondition(editor.textView.string==model.text && editor.window?.appearance?.name == .darkAqua)
  editor.textView.string="first";editor.saveDocument();precondition(editor.saving && !editor.saveButton.isEnabled && baseline==model.original)
  editor.textView.string="second";completion?(.success(()));precondition(editor.dirty && editor.saveButton.isEnabled && editor.savedText=="first")
  editor.saveDocument();precondition(baseline==Data("first".utf8));completion?(.success(()));precondition(!editor.dirty && editor.savedText=="second");editor.close()
  let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("macterm-editor-test-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let file=root.appendingPathComponent("中文.txt");let original=Data("before\r\n".utf8);try original.write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o640],ofItemAtPath:file.path)
  let client=try SFTPClient(command:"/usr/libexec/sftp-server",arguments:[]);defer{client.close()};let loaded=try client.readFile(file.path,limit:RemoteText.maximumBytes);precondition(loaded==original)
  let updated=Data("after 中文\r\n".utf8);try client.saveText(updated,to:file.path,expected:original);let saved=try Data(contentsOf:file);precondition(saved==updated);let attrs=try client.attributes(file.path);precondition(attrs.1&0o777==0o640)
  do {try client.saveText(original,to:file.path,expected:original);fatalError("Stale revision must fail")}catch{};let notChanged=try Data(contentsOf:file);precondition(notChanged==updated)
  let symlink=root.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:symlink,withDestinationURL:file)
  do {try client.saveText(original,to:symlink.path,expected:updated);fatalError("Symlink replacement must fail")}catch{};let resolved=try client.canonical(symlink.path);let target=try client.canonical(file.path);precondition(resolved==target)
  let files=try client.list(root.path);precondition(!files.contains{$0.name.hasPrefix(".macterm-upload-")})
  print("PASS: UTF-8/UTF-16 BOM and CRLF roundtrip, binary/invalid/oversize rejection, atomic save, permission preservation, stale revision rejection, symlink protection, temporary cleanup")
 }
}
