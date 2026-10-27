import beap/internal/paths.{BadPath, Forbidden, NotFound}
import beap/support
import simplifile

pub fn decode_test() {
  assert paths.decode(["a%20b", "%C3%BC.txt"]) == Ok(["a b", "ü.txt"])
  assert paths.decode(["it's", "(1)"]) == Ok(["it's", "(1)"])
}

pub fn traversal_is_refused_test() {
  assert paths.decode([".."]) == Error(BadPath)
  assert paths.decode(["a", "."]) == Error(BadPath)
  assert paths.decode(["%2e%2e"]) == Error(BadPath)
  assert paths.decode(["%2E%2E", "etc"]) == Error(BadPath)
  assert paths.decode(["a%2Fb"]) == Error(BadPath)
  assert paths.decode(["..%2F..%2Fetc"]) == Error(BadPath)
  assert paths.decode(["nul%00"]) == Error(BadPath)
  assert paths.decode(["%ZZ"]) == Error(BadPath)
  assert paths.decode(["%C3"]) == Error(BadPath)
}

pub fn split_keeps_dot_segments_test() {
  // They must reach `decode`, which refuses them, not vanish.
  assert paths.split("/files/../etc/") == ["files", "..", "etc"]
  assert paths.split("/") == []
}

pub fn encode_test() {
  assert paths.encode([]) == ""
  assert paths.encode(["a b", "ü.txt"]) == "/a%20b/%C3%BC.txt"
  assert paths.encode_segment("it's \"q\" #1 (2)&<x>.tar.gz")
    == "it%27s%20%22q%22%20%231%20%282%29%26%3Cx%3E.tar.gz"
  assert paths.encode_segment("A-z_0.9~") == "A-z_0.9~"
}

pub fn encode_and_decode_agree_test() {
  let names = ["plain.txt", "spaces and ü", "%41", "a+b=c?d#e", "日本語"]
  assert paths.decode(paths.split(paths.encode(names))) == Ok(names)
}

pub fn nested_folders_test() {
  let root = support.directory("paths_nested")
  support.write(root <> "/a/b/c.txt", "c")
  assert paths.resolve(root, []) == Ok(root)
  assert paths.resolve(root, ["a", "b"]) == Ok(root <> "/a/b")
  assert paths.resolve(root, ["a", "b", "c.txt"]) == Ok(root <> "/a/b/c.txt")
  assert paths.resolve(root, ["a", "missing"]) == Error(NotFound)
  // A file used as a folder
  assert paths.resolve(root, ["a", "b", "c.txt", "d"]) == Error(NotFound)
}

pub fn symlink_escape_is_refused_test() {
  let root = support.directory("paths_symlinks/root")
  let outside = support.directory("paths_symlinks/outside")
  support.write(outside <> "/secret.txt", "secret")
  support.write(root <> "/inside/file.txt", "ok")
  let assert Ok(_) = simplifile.create_symlink(outside, root <> "/out")
  let assert Ok(_) =
    simplifile.create_symlink(outside <> "/secret.txt", root <> "/secret")
  let assert Ok(_) = simplifile.create_symlink("../outside", root <> "/rel")
  let assert Ok(_) = simplifile.create_symlink("inside", root <> "/alias")
  let assert Ok(_) = simplifile.create_symlink("/", root <> "/top")
  assert paths.resolve(root, ["out"]) == Error(Forbidden)
  assert paths.resolve(root, ["out", "secret.txt"]) == Error(Forbidden)
  assert paths.resolve(root, ["secret"]) == Error(Forbidden)
  assert paths.resolve(root, ["rel", "secret.txt"]) == Error(Forbidden)
  assert paths.resolve(root, ["top", "etc"]) == Error(Forbidden)
  // A link to somewhere in the root is fine.
  assert paths.resolve(root, ["alias", "file.txt"])
    == Ok(root <> "/inside/file.txt")
}

pub fn the_staging_directory_is_off_limits_test() {
  let root = support.directory("paths_staging")
  support.write(root <> "/.beap-uploads/x.part", "partial")
  let assert Ok(_) =
    simplifile.create_symlink(root <> "/.beap-uploads", root <> "/staging")
  assert paths.resolve(root, [".beap-uploads"]) == Error(Forbidden)
  assert paths.resolve(root, [".beap-uploads", "x.part"]) == Error(Forbidden)
  assert paths.resolve(root, ["staging", "x.part"]) == Error(Forbidden)
}

pub fn link_loops_end_test() {
  let root = support.directory("paths_loop")
  let assert Ok(_) = simplifile.create_symlink("b", root <> "/a")
  let assert Ok(_) = simplifile.create_symlink("a", root <> "/b")
  assert paths.resolve(root, ["a"]) == Error(paths.Unreadable(simplifile.Eloop))
}

pub fn inside_compares_whole_components_test() {
  assert paths.inside("/srv/share", "/srv/share")
  assert paths.inside("/srv/share", "/srv/share/a")
  assert !paths.inside("/srv/share", "/srv/shared")
  assert !paths.inside("/srv/share", "/srv")
  assert paths.inside("/", "/anything")
}
