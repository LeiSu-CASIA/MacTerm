import Foundation
@main struct ProtocolTests {
 static func main()throws {
  let executable=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("protocol-server").path
  for mode in ["bad-name","bad-length","bad-id"] {
   let client=try SFTPClient(command:executable,arguments:[mode]);defer{client.close()}
   do {_ = try client.list("/");fatalError("Malformed server response must be rejected: \(mode)")}catch{}
  }
  for mode in ["canonical-empty","canonical-nul","canonical-utf8","canonical-long"] {let client=try SFTPClient(command:executable,arguments:[mode]);defer{client.close()};do{_ = try client.canonical("/");fatalError("Malformed canonical path accepted")}catch{}}
  for mode in ["link-empty","link-nul","link-utf8","link-long","link-count","link-trailing"] {let client=try SFTPClient(command:executable,arguments:[mode]);defer{client.close()};do{_ = try client.readLink("/");fatalError("Malformed READLINK accepted: \(mode)")}catch{}}
  print("PASS: malicious path name, oversized packet and mismatched response ID and invalid / oversized canonical paths are rejected")
 }
}
