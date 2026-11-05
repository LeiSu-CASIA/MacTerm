import Cocoa
@main struct CredentialsTests {
 static func main()throws {
  _ = NSApplication.shared
  let session=Session(name:"FTP",host:"localhost",user:"demo",port:21,key:"",id:UUID(),kind:.ftp,ftp:FTPSettings())
  let first=FTPPassword.makePrompt(session)
  precondition(first.field.stringValue.isEmpty && first.alert.buttons.map{$0.title} == ["连接","取消"])
  precondition(first.alert.accessoryView === first.field && first.field.cell is NSSecureTextFieldCell)
  first.field.stringValue="current-connection-only"
  let second=FTPPassword.makePrompt(session)
  precondition(second.field.stringValue.isEmpty && !second.alert.informativeText.contains("钥匙串"))
  let encoded=try JSONEncoder().encode(session),object=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
  precondition(object["password"]==nil && !String(decoding:encoded,as:UTF8.self).contains(first.field.stringValue))
  first.field.stringValue=""
  first.alert.window.orderOut(nil);second.alert.window.orderOut(nil)
  print("PASS: connection password prompt is empty, has only Connect/Cancel, never prefills another prompt or exports passwords")
 }
}
