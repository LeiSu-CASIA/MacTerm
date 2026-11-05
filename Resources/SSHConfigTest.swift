import Foundation
@main struct SSHConfigTests {
 static func main()throws {
  let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("macterm-config-"+UUID().uuidString);try FileManager.default.createDirectory(at:root.appendingPathComponent("parts"),withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let config=root.appendingPathComponent("config"),marker=root.appendingPathComponent("must-not-execute")
  let contents="""
  # comment
  Host alpha beta
   User ignored-at-import
  Host="quoted-host" # trailing comment
  Host * !excluded prefix-* bad?name
  Match exec "touch \(marker.path)"
   Include parts/*.conf
  Include missing/*.conf ${UNSUPPORTED}/config
  """
  try Data(contents.utf8).write(to:config)
  try Data("hOsT gamma alpha\nInclude config\n".utf8).write(to:root.appendingPathComponent("parts/one.conf"))
  let report=try SSHConfigImporter.scan(config,sshDirectory:root);precondition(Set(report.sessions.map{$0.host})==Set(["alpha","beta","gamma","quoted-host"]));precondition(report.skippedPatterns==4 && report.skippedIncludes==2);precondition(report.sessions.allSatisfy{$0.port==0 && $0.user.isEmpty && $0.key.isEmpty && $0.group=="SSH Config"});precondition(!FileManager.default.fileExists(atPath:marker.path))
  let again=try SSHConfigImporter.scan(config,sshDirectory:root);let merge=try SessionStore.merge(again.sessions,into:report.sessions);precondition(merge.added==0)
  try Data("Host \"unclosed\n".utf8).write(to:config);do {_ = try SSHConfigImporter.scan(config,sshDirectory:root);fatalError("Malformed config must fail")}catch{}
  print("PASS: static aliases, quotes/comments/equals syntax, Include glob and cycle handling, wildcard/negated patterns skipped, no Match exec execution, duplicate import and malformed config rejection")
 }
}
