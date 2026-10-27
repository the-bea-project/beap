//// End to end: a server on a free port, real sockets.

import beap/internal/config.{Config}
import beap/support.{get, header, put, text}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string
import simplifile

fn shared(name: String) -> #(String, Int) {
  let root = support.directory(name)
  #(root, support.serve(support.config(root)))
}

pub fn page_test() {
  let #(root, port) = shared("server_page")
  support.write(root <> "/Documents/notes.md", "# notes")
  let response = get(port, "/")
  assert response.status == 200
  assert header(response, "content-type") == Ok("text/html; charset=utf-8")
  let assert Ok(policy) = header(response, "content-security-policy")
  assert string.contains(policy, "default-src 'none'")
  assert header(response, "x-content-type-options") == Ok("nosniff")
  assert header(response, "x-frame-options") == Ok("DENY")
  let page = text(response)
  assert string.contains(page, "href=\"/files/Documents/\"")
  // Links are built for the address the client used.
  assert string.contains(page, "http://127.0.0.1:" <> int.to_string(port))
  // The staging directory isn't listed.
  assert !string.contains(page, ".beap-uploads")
  assert get(port, "/_beap/style.css").status == 200
  assert get(port, "/_beap/app.js").status == 200
}

pub fn nested_folders_test() {
  let #(root, port) = shared("server_nested")
  support.write(root <> "/a/b/c.txt", "c")
  let page = text(get(port, "/files/a/b/"))
  assert string.contains(page, "href=\"/files/a/b/c.txt\"")
  assert string.contains(page, "<a href=\"/files/a/\">a</a>")
  // Without the slash, a folder redirects to its canonical URL.
  let response = get(port, "/files/a/b")
  assert response.status == 301
  assert header(response, "location") == Ok("/files/a/b/")
  assert text(get(port, "/files/empty-name/")) == "Not found\n"
}

pub fn download_test() {
  let #(root, port) = shared("server_download")
  support.write(root <> "/report.txt", "the report")
  let response = get(port, "/files/report.txt")
  assert response.status == 200
  assert response.body == <<"the report">>
  assert header(response, "content-type") == Ok("application/octet-stream")
  assert header(response, "content-disposition")
    == Ok("attachment; filename=\"report.txt\"; filename*=UTF-8''report.txt")
  assert header(response, "content-length") == Ok("10")
  assert header(response, "content-security-policy") == Ok("sandbox")
  assert header(response, "accept-ranges") == Ok("bytes")
  let head = support.request(port, "HEAD", "/files/report.txt", [], <<>>)
  assert head.status == 200
  assert head.body == <<>>
}

pub fn ranges_test() {
  let #(root, port) = shared("server_ranges")
  support.write(root <> "/digits", "0123456789")
  let range = fn(value) {
    support.request(port, "GET", "/files/digits", [#("range", value)], <<>>)
  }
  let partial = range("bytes=2-5")
  assert partial.status == 206
  assert partial.body == <<"2345">>
  assert header(partial, "content-range") == Ok("bytes 2-5/10")
  assert range("bytes=7-").body == <<"789">>
  assert range("bytes=-3").body == <<"789">>
  assert range("bytes=8-100").body == <<"89">>
  let outside = range("bytes=20-")
  assert outside.status == 416
  assert header(outside, "content-range") == Ok("bytes */10")
  // Several ranges: the whole file
  assert range("bytes=0-1,4-5").status == 200
}

pub fn missing_files_test() {
  let #(_, port) = shared("server_missing")
  assert get(port, "/files/nope.txt").status == 404
  assert get(port, "/nope").status == 404
  assert get(port, "/files/a/b/c").status == 404
}

pub fn traversal_test() {
  let #(_, port) = shared("server_traversal")
  // Sent as is: the client doesn't resolve them.
  assert get(port, "/files/../../etc/passwd").status == 400
  assert get(port, "/files/%2e%2e/%2e%2e/etc/passwd").status == 400
  assert get(port, "/files/..%2F..%2Fetc%2Fpasswd").status == 400
  assert get(port, "/files//etc/passwd").status == 404
  assert put(port, "/upload/../x", <<"x">>).status == 400
  assert put(port, "/upload/%2e%2e/x", <<"x">>).status == 400
}

pub fn symlink_escape_test() {
  let root = support.directory("server_symlinks/root")
  let outside = support.directory("server_symlinks/outside")
  support.write(outside <> "/secret.txt", "secret")
  let assert Ok(_) = simplifile.create_symlink(outside, root <> "/out")
  let assert Ok(_) = simplifile.create_symlink("/etc", root <> "/etc")
  let port = support.serve(support.config(root))
  assert get(port, "/files/out/secret.txt").status == 403
  assert get(port, "/files/out/").status == 403
  assert get(port, "/files/etc/passwd").status == 403
  assert put(port, "/upload/out/planted.txt", <<"x">>).status == 403
  assert simplifile.is_file(outside <> "/planted.txt") == Ok(False)
  // Links that lead out of the root aren't listed either.
  assert !string.contains(text(get(port, "/")), "out/")
  assert get(port, "/files/.beap-uploads/").status == 403
}

pub fn small_upload_test() {
  let #(root, port) = shared("server_small_upload")
  support.write(root <> "/docs/.keep", "")
  let response = put(port, "/upload/docs/hello.txt", <<"hello">>)
  assert response.status == 201
  assert header(response, "location") == Ok("/files/docs/hello.txt")
  assert string.starts_with(text(response), "Saved hello.txt (5 B)\n")
  assert support.read(root <> "/docs/hello.txt") == "hello"
  assert get(port, "/files/docs/hello.txt").body == <<"hello">>
  // Staging leaves nothing behind.
  assert simplifile.read_directory(root <> "/.beap-uploads") == Ok([])
}

pub fn existing_files_are_never_replaced_test() {
  let #(root, port) = shared("server_no_overwrite")
  support.write(root <> "/notes.txt", "original")
  let response = put(port, "/upload/notes.txt", <<"new">>)
  assert response.status == 201
  assert header(response, "location") == Ok("/files/notes%20%281%29.txt")
  assert support.read(root <> "/notes.txt") == "original"
  assert support.read(root <> "/notes (1).txt") == "new"
}

pub fn concurrent_uploads_to_one_name_test() {
  let #(root, port) = shared("server_concurrent")
  let numbers = int.range(from: 8, to: 0, with: [], run: list.prepend)
  let bodies = list.map(numbers, fn(i) { <<"upload ", int.to_string(i):utf8>> })
  let results = support.concurrent_puts(port, "/upload/same.txt", bodies)
  assert list.all(results, fn(result) { result.0 == 201 })
  // Every upload is complete, under its own name.
  let assert Ok(names) = simplifile.read_directory(root)
  let saved =
    names
    |> list.filter(fn(name) { name != ".beap-uploads" })
    |> list.map(fn(name) { support.read(root <> "/" <> name) })
    |> list.sort(string.compare)
  let expected =
    numbers
    |> list.map(fn(i) { "upload " <> int.to_string(i) })
    |> list.sort(string.compare)
  assert saved == expected
}

pub fn special_names_test() {
  let #(root, port) = shared("server_names")
  let name = "it's \"q\" #1 (ü) ✓.txt"
  let path = "/upload/it%27s%20%22q%22%20%231%20%28%C3%BC%29%20%E2%9C%93.txt"
  assert put(port, path, <<"special">>).status == 201
  assert support.read(root <> "/" <> name) == "special"
  // Listed under its name, linked percent-encoded
  let page = text(get(port, "/"))
  assert string.contains(page, "it&#39;s &quot;q&quot; #1 (ü) ✓.txt")
  let url = "/files/it%27s%20%22q%22%20%231%20%28%C3%BC%29%20%E2%9C%93.txt"
  assert string.contains(page, "href=\"" <> url <> "\"")
  let download = get(port, url)
  assert download.body == <<"special">>
  assert header(download, "content-disposition")
    == Ok(
      "attachment; filename=\"it's _q_ #1 (_) _.txt\"; filename*=UTF-8''it%27s%20%22q%22%20%231%20%28%C3%BC%29%20%E2%9C%93.txt",
    )
  assert put(port, "/upload/.beap-uploads", <<"x">>).status == 400
  assert put(port, "/upload/", <<"x">>).status == 400
}

pub fn binary_content_is_preserved_test() {
  let #(root, port) = shared("server_binary")
  let bytes =
    int.range(from: 0, to: 256, with: <<>>, run: fn(acc, b) { <<acc:bits, b>> })
  let body = bit_array.concat([bytes, <<0, 13, 10, 13, 10>>, bytes])
  assert put(port, "/upload/all-bytes.bin", body).status == 201
  assert simplifile.read_bits(root <> "/all-bytes.bin") == Ok(body)
  assert get(port, "/files/all-bytes.bin").body == body
}

const mib = 1_048_576

/// 256 MiB through the server, both framings, without the memory following:
/// the body goes to the disk 64 KiB at a time.
pub fn large_streamed_upload_test() {
  let #(root, port) = shared("server_large")
  let size = 256 * mib
  let #(#(status, _, sent), growth) =
    support.memory_peak_during(fn() {
      support.upload_stream(port, "/upload/chunked.bin", size, True, 1)
    })
  assert status == 201
  assert growth < 48 * mib
  assert support.sha256_file(root <> "/chunked.bin") == sent
  let #(status, _, sent) =
    support.upload_stream(port, "/upload/sized.bin", size, False, 2)
  assert status == 201
  assert support.sha256_file(root <> "/sized.bin") == sent
  // And back
  let #(#(status, received, digest), growth) =
    support.memory_peak_during(fn() {
      support.download_digest(port, "/files/sized.bin")
    })
  assert status == 200
  assert received == size
  assert digest == sent
  assert growth < 48 * mib
}

pub fn interrupted_upload_test() {
  let #(root, port) = shared("server_interrupted")
  support.send_partial(port, "/upload/partial.bin", 10 * mib, 3 * mib)
  wait_until_empty(root <> "/.beap-uploads", 50)
  assert simplifile.read_directory(root <> "/.beap-uploads") == Ok([])
  assert simplifile.is_file(root <> "/partial.bin") == Ok(False)
  // The server carries on.
  assert put(port, "/upload/after.txt", <<"fine">>).status == 201
}

fn wait_until_empty(dir: String, tries: Int) -> Nil {
  case simplifile.read_directory(dir), tries {
    Ok([]), _ | _, 0 -> Nil
    _, _ -> {
      support.sleep(100)
      wait_until_empty(dir, tries - 1)
    }
  }
}

pub fn upload_limit_test() {
  let root = support.directory("server_limit")
  let port = support.serve(Config(..support.config(root), max_upload: mib))
  // Announced too large: refused before the body is read
  let #(status, body, _) =
    support.upload_stream(port, "/upload/big.bin", 2 * mib, False, 3)
  assert status == 413
  assert body == <<"Larger than the 1 MB upload limit\n">>
  // Chunked: refused once it goes past the limit. The client is still
  // sending when the server answers and hangs up, so it may only see the
  // connection reset.
  let #(status, _, _) =
    support.upload_stream(port, "/upload/big.bin", 2 * mib, True, 4)
  assert status == 413 || status == 0
  assert simplifile.is_file(root <> "/big.bin") == Ok(False)
  assert simplifile.read_directory(root <> "/.beap-uploads") == Ok([])
  // Right at the limit
  let #(status, _, _) =
    support.upload_stream(port, "/upload/fits.bin", mib, True, 5)
  assert status == 201
}

pub fn uploads_disabled_test() {
  let root = support.directory("server_read_only")
  let port = support.serve(Config(..support.config(root), uploads: False))
  let response = put(port, "/upload/x.txt", <<"x">>)
  assert response.status == 403
  assert text(response) == "Uploads are disabled on this server\n"
  assert simplifile.is_directory(root <> "/.beap-uploads") == Ok(False)
  assert !string.contains(text(get(port, "/")), "id=\"drop\"")
}

pub fn invalid_uploads_test() {
  let #(_, port) = shared("server_invalid_uploads")
  assert put(port, "/upload/missing/x.txt", <<"x">>).status == 404
  let response = support.request(port, "POST", "/upload/x.txt", [], <<"x">>)
  assert response.status == 405
  assert header(response, "allow") == Ok("PUT")
  assert support.request(port, "DELETE", "/files/x", [], <<>>).status == 405
}
