import beap/internal/fs.{Directory, Entry, File}
import beap/internal/html
import beap/internal/share
import beap/support
import gleam/list
import gleam/string
import simplifile

pub fn empty_folder_test() {
  let root = support.directory("listing_empty")
  assert fs.entries(root) == Ok([])
  let page = render(["empty"], [])
  assert string.contains(page, "This folder is empty")
}

pub fn folders_first_then_by_name_test() {
  let root = support.directory("listing_sorted")
  support.write(root <> "/b.txt", "bb")
  support.write(root <> "/A.txt", "a")
  support.write(root <> "/c/inside.txt", "")
  support.write(root <> "/Docs/x", "")
  let assert Ok(_) = simplifile.create_symlink("b.txt", root <> "/link.txt")
  // Dangling links can't be opened, so they are left out.
  let assert Ok(_) = simplifile.create_symlink("nowhere", root <> "/broken")
  assert fs.entries(root)
    == Ok([
      Entry(name: "c", kind: Directory, size: 0, link: False),
      Entry(name: "Docs", kind: Directory, size: 0, link: False),
      Entry(name: "A.txt", kind: File, size: 1, link: False),
      Entry(name: "b.txt", kind: File, size: 2, link: False),
      Entry(name: "link.txt", kind: File, size: 2, link: True),
    ])
}

pub fn unreadable_folder_test() {
  assert fs.entries("/nonexistent/beap") == Error(simplifile.Enoent)
}

pub fn sizes_test() {
  assert fs.format_size(0) == "0 B"
  assert fs.format_size(1023) == "1023 B"
  assert fs.format_size(1024) == "1 KB"
  assert fs.format_size(3277) == "3.2 KB"
  assert fs.format_size(1_572_864) == "1.5 MB"
  assert fs.format_size(52_428_800) == "50 MB"
  assert fs.format_size(157_286_400) == "150 MB"
  assert fs.format_size(2_576_980_378) == "2.4 GB"
  assert fs.format_size(10_737_418_240) == "10 GB"
  assert fs.format_size(1_125_899_906_842_624 * 3) == "3 PB"
}

fn render(path: List(String), entries: List(fs.Entry)) -> String {
  html.page(html.Page(
    version: "1.0.0",
    path:,
    entries:,
    origin: "http://192.168.1.10:8000",
    uploads: True,
    max_upload: 1024,
  ))
}

pub fn page_test() {
  let entries = [
    Entry(name: "src", kind: Directory, size: 0, link: False),
    Entry(name: "archive.tar.gz", kind: File, size: 2_576_980_378, link: False),
  ]
  let page = render(["Development", "projects"], entries)
  // Breadcrumbs: each folder links to itself, the current one doesn't.
  assert string.contains(page, "<a href=\"/\">/</a>")
  assert string.contains(
    page,
    "<a href=\"/files/Development/\">Development</a>",
  )
  assert string.contains(page, "<span aria-current=\"page\">projects</span>")
  // Folders open, files download.
  assert string.contains(page, "href=\"/files/Development/projects/src/\"")
  assert string.contains(
    page,
    "href=\"/files/Development/projects/archive.tar.gz\" download=\"archive.tar.gz\"",
  )
  assert string.contains(page, "2.4 GB")
  // Uploads go to the folder shown.
  assert string.contains(page, "data-target=\"/upload/Development/projects/\"")
  // The parent folder
  assert string.contains(page, "<a href=\"/files/Development/\"><svg")
  assert string.contains(page, "v1.0.0")
}

pub fn names_are_escaped_test() {
  let name = "<script>alert('x')</script> & \"q\".txt"
  let page = render([], [Entry(name:, kind: File, size: 1, link: False)])
  assert !string.contains(page, "<script>alert")
  assert string.contains(
    page,
    "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; &quot;q&quot;.txt",
  )
  assert string.contains(
    page,
    "/files/%3Cscript%3Ealert%28%27x%27%29%3C%2Fscript%3E%20%26%20%22q%22.txt",
  )
}

pub fn read_only_page_test() {
  let page =
    html.page(html.Page(
      version: "1.0.0",
      path: [],
      entries: [Entry(name: "a.txt", kind: File, size: 1, link: False)],
      origin: "http://127.0.0.1:8000",
      uploads: False,
      max_upload: 1024,
    ))
  assert string.contains(page, "uploads are disabled")
  assert !string.contains(page, "id=\"drop\"")
  assert !string.contains(page, "curl upload")
}

pub fn share_links_test() {
  let origin = "http://192.168.1.10:8000"
  assert share.file_url(origin, ["Documents", "archive.tar.gz"])
    == "http://192.168.1.10:8000/files/Documents/archive.tar.gz"
  assert share.curl_download(origin, ["archive.tar.gz"])
    == "curl -fL -O 'http://192.168.1.10:8000/files/archive.tar.gz'"
  assert share.curl_upload(origin, [], "archive.tar.gz")
    == "curl -T 'archive.tar.gz' 'http://192.168.1.10:8000/upload/archive.tar.gz'"
  assert share.curl_upload_any(origin, ["a b"])
    == "curl -T FILE 'http://192.168.1.10:8000/upload/a%20b/'"
}

pub fn share_special_names_test() {
  let origin = "http://[fe80::1]:8000"
  let name = "it's my file #1.txt"
  // -O would name the file `it%27s%20my...`: the name is given instead.
  assert share.curl_download(origin, ["dir", name])
    == "curl -fL -o 'it'\\''s my file #1.txt' 'http://[fe80::1]:8000/files/dir/it%27s%20my%20file%20%231.txt'"
  assert share.curl_upload(origin, ["dir"], name)
    == "curl -T 'it'\\''s my file #1.txt' 'http://[fe80::1]:8000/upload/dir/it%27s%20my%20file%20%231.txt'"
}

pub fn origin_test() {
  // The address the visitor used, as they used it
  assert share.origin(Ok("192.168.1.10:8000"), "0.0.0.0", 8000)
    == "http://192.168.1.10:8000"
  assert share.origin(Ok("[::1]:9000"), "::", 9000) == "http://[::1]:9000"
  // No Host header: the address listened on
  assert share.origin(Error(Nil), "127.0.0.1", 8000) == "http://127.0.0.1:8000"
  assert share.origin(Error(Nil), "::1", 8000) == "http://[::1]:8000"
  assert share.authority("fe80::1", 80) == "[fe80::1]:80"
}

pub fn quote_test() {
  assert share.quote("plain") == "'plain'"
  assert share.quote("it's") == "'it'\\''s'"
  assert share.quote("$(rm -rf ~)") == "'$(rm -rf ~)'"
}

pub fn icons_by_type_test() {
  let page =
    render(
      [],
      list.map(["a.zip", "b.PNG", "c.mp4", "d.txt", ".bashrc"], fn(name) {
        Entry(name:, kind: File, size: 1, link: False)
      }),
    )
  assert string.contains(page, "#i-archive")
  assert string.contains(page, "#i-image")
  assert string.contains(page, "#i-media")
  assert string.contains(page, "#i-file")
}
