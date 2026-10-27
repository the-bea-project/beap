import beap/internal/config.{Config, Help, Serve}

fn defaults() -> config.Config {
  config.defaults("1.0.0")
}

fn parse(args: List(String)) -> Result(config.Command, String) {
  config.parse(args, defaults())
}

pub fn defaults_test() {
  assert parse([])
    == Ok(
      Serve(Config(
        app_version: "1.0.0",
        host: "127.0.0.1",
        port: 8000,
        root: ".",
        uploads: True,
        max_upload: 10_737_418_240,
      )),
    )
}

pub fn host_and_port_as_arguments_test() {
  assert parse(["0.0.0.0", "9000"])
    == Ok(Serve(Config(..defaults(), host: "0.0.0.0", port: 9000)))
  // `bea run -- 127.0.0.1 8000`
  assert parse(["--", "127.0.0.1", "8001"])
    == Ok(Serve(Config(..defaults(), port: 8001)))
}

pub fn options_test() {
  let args = [
    "--host", "::", "--port", "0", "--dir", "/srv/share", "--no-upload",
    "--max-upload", "500M",
  ]
  assert parse(args)
    == Ok(Serve(
      Config(
        ..defaults(),
        host: "::",
        port: 0,
        root: "/srv/share",
        uploads: False,
        max_upload: 524_288_000,
      ),
    ))
  assert parse(["--port=9000", "--host=0.0.0.0"])
    == Ok(Serve(Config(..defaults(), host: "0.0.0.0", port: 9000)))
}

pub fn help_test() {
  assert parse(["--help"]) == Ok(Help)
  assert parse(["--port", "9000", "-h"]) == Ok(Help)
}

pub fn invalid_arguments_test() {
  assert parse(["--port", "http"]) == Error("invalid port: http")
  assert parse(["--port", "70000"]) == Error("invalid port: 70000")
  assert parse(["--port", "-1"]) == Error("invalid port: -1")
  assert parse(["--port"]) == Error("--port needs a value")
  assert parse(["--dir"]) == Error("--dir needs a value")
  assert parse(["--verbose"]) == Error("unknown option --verbose")
  assert parse(["localhost"]) == Error("expected <host> <port>, or options")
  assert parse(["localhost", "80", "extra"])
    == Error("expected <host> <port>, or options")
  assert parse(["localhost", "eighty"]) == Error("invalid port: eighty")
  assert parse(["--max-upload", "lots"])
    == Error("invalid size: lots (try 500M or 4G)")
  assert parse(["--max-upload", "0"])
    == Error("invalid size: 0 (try 500M or 4G)")
}

pub fn sizes_test() {
  assert config.parse_size("4096") == Ok(4096)
  assert config.parse_size("1K") == Ok(1024)
  assert config.parse_size("2GB") == Ok(2_147_483_648)
  assert config.parse_size("1GiB") == Ok(1_073_741_824)
  assert config.parse_size("3t") == Ok(3_298_534_883_328)
  assert config.parse_size("1.5G") |> is_error
  assert config.parse_size("G") |> is_error
}

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}
