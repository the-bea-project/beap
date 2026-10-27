import beap/internal/runtime/runtime
import beap/internal/upload
import beap/support
import gleam/string
import simplifile

pub fn names_test() {
  assert upload.valid_name("report.pdf")
  assert upload.valid_name("it's \"q\" #1 ü.txt")
  assert upload.valid_name(".hidden")
  assert !upload.valid_name("")
  assert !upload.valid_name(".")
  assert !upload.valid_name("..")
  assert !upload.valid_name("a/b")
  assert !upload.valid_name("nul\u{0}")
  assert !upload.valid_name(".beap-uploads")
  assert upload.valid_name(string.repeat("a", 250))
  assert !upload.valid_name(string.repeat("a", 251))
  // 250 bytes is not 250 characters
  assert !upload.valid_name(string.repeat("é", 126))
}

pub fn numbered_names_test() {
  assert upload.numbered("notes.txt", 0) == "notes.txt"
  assert upload.numbered("notes.txt", 1) == "notes (1).txt"
  assert upload.numbered("archive.tar.gz", 2) == "archive (2).tar.gz"
  assert upload.numbered("README", 3) == "README (3)"
  assert upload.numbered(".bashrc", 1) == ".bashrc (1)"
  assert upload.numbered(".config.json", 1) == ".config (1).json"
}

pub fn prepare_empties_the_staging_directory_test() {
  let root = support.directory("upload_prepare")
  support.write(root <> "/.beap-uploads/left-over.part", "partial")
  let assert Ok(staging) = upload.prepare(root)
  assert staging == root <> "/.beap-uploads"
  assert simplifile.read_directory(staging) == Ok([])
}

pub fn exclusive_open_never_replaces_test() {
  let root = support.directory("upload_exclusive")
  support.write(root <> "/taken", "keep")
  let assert Ok(_) =
    simplifile.create_symlink(root <> "/taken", root <> "/link")
  assert runtime.open_exclusive(root <> "/taken") == Error(simplifile.Eexist)
  // Not even through a link
  assert runtime.open_exclusive(root <> "/link") == Error(simplifile.Eexist)
  assert support.read(root <> "/taken") == "keep"
}

pub fn a_dying_upload_leaves_no_partial_file_test() {
  let root = support.directory("upload_watch")
  let partial = root <> "/x.part"
  // The process that opened the file is killed mid-write, as a connection
  // process would be when the server stops.
  support.exit_after(
    fn() {
      let assert Ok(file) = runtime.open_exclusive(partial)
      let _ = runtime.watch(partial)
      runtime.write(file, <<"half an upload">>)
    },
    50,
  )
  assert simplifile.is_file(partial) == Ok(False)
}

pub fn a_finished_upload_is_not_deleted_test() {
  let root = support.directory("upload_unwatch")
  let path = root <> "/kept"
  support.exit_after(
    fn() {
      let assert Ok(file) = runtime.open_exclusive(path)
      let watcher = runtime.watch(path)
      let assert Ok(_) = runtime.write(file, <<"done">>)
      let assert Ok(_) = runtime.close(file)
      runtime.unwatch(watcher)
    },
    50,
  )
  assert support.read(path) == "done"
}
