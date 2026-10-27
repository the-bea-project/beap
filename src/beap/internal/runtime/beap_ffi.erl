-module(beap_ffi).
-export([
    app_version/1, halt/1, local_addresses/0, check_listen/2,
    read_directory/1, read_link/1, argument_bytes/1,
    open_exclusive/1, write/2, sync/1, close/1,
    watch/1, unwatch/1,
    discard_body_progress/0
]).

%% The version in the application's `.app` file (from `bea.toml`).
app_version(App) ->
    _ = application:load(App),
    case application:get_key(App, vsn) of
        {ok, Version} -> list_to_binary(Version);
        undefined -> <<"0.0.0">>
    end.

halt(Code) ->
    erlang:halt(Code, [{flush, true}]).

%% The IPv4 addresses of this machine's network interfaces, loopback
%% excluded: where other devices can reach a server bound to 0.0.0.0.
local_addresses() ->
    case inet:getifaddrs() of
        {ok, Interfaces} ->
            [list_to_binary(inet:ntoa(Address))
             || {_Name, Options} <- Interfaces,
                {addr, {A, _, _, _} = Address} <- Options,
                A =/= 127];
        {error, _} -> []
    end.

%% Whether a server could listen on `Host:Port`, tried before starting one:
%% when it can't, the server's own error is a long supervisor report.
check_listen(Host, Port) ->
    Interface = case {Host, inet:parse_address(binary_to_list(Host))} of
        {<<"localhost">>, _} -> [{ip, loopback}];
        {_, {ok, {_, _, _, _} = Address}} -> [{ip, Address}];
        {_, {ok, Address}} -> [inet6, {ip, Address}];
        {_, {error, _}} -> invalid
    end,
    case Interface of
        invalid -> {error, <<"not an IP address (or localhost)">>};
        _ ->
            case gen_tcp:listen(Port, [{reuseaddr, true} | Interface]) of
                {ok, Socket} ->
                    gen_tcp:close(Socket),
                    {ok, nil};
                {error, eaddrinuse} -> {error, <<"the port is already in use">>};
                {error, eacces} -> {error, <<"permission denied (ports below 1024 need privileges)">>};
                {error, eaddrnotavail} -> {error, <<"this machine has no such address">>};
                {error, Reason} -> {error, list_to_binary(inet:format_error(Reason))}
            end
    end.

%% --- File names ----------------------------------------------------------------
%%
%% Paths are passed to the `file` module as binaries, which it uses as the
%% bytes they are. What it returns as lists is decoded with the VM's file
%% name encoding, which follows the locale: without a UTF-8 one (`LANG`
%% unset, as in many services and containers) it is latin1, and a name like
%% `résumé.txt` comes back byte by byte. These two return the bytes as they
%% are on the disk, whatever the locale.

%% The names in a directory.
read_directory(Dir) ->
    case file:list_dir_all(Dir) of
        {ok, Names} -> {ok, [name_bytes(Name) || Name <- Names]};
        Error -> posix(Error)
    end.

%% The target of a symbolic link, or `einval` when the path isn't one.
read_link(Path) ->
    case file:read_link_all(Path) of
        {ok, Target} -> {ok, name_bytes(Target)};
        Error -> posix(Error)
    end.

%% A command-line argument as typed. `argv` reads the arguments as decoded
%% by the VM, with the same encoding: under latin1, each byte of a UTF-8
%% argument became a character of its own.
argument_bytes(Argument) ->
    case file:native_name_encoding() of
        utf8 -> Argument;
        latin1 ->
            case unicode:characters_to_binary(Argument, utf8, latin1) of
                Bytes when is_binary(Bytes) -> Bytes;
                _ -> Argument
            end
    end.

name_bytes(Name) when is_binary(Name) -> Name;
name_bytes(Name) ->
    case file:native_name_encoding() of
        latin1 -> list_to_binary(Name);
        utf8 -> unicode:characters_to_binary(Name)
    end.

%% --- Upload files --------------------------------------------------------------
%%
%% A file opened here is owned by the calling process: `raw` files can only
%% be used by the process that opened them, and are closed when it exits.
%% `exclusive` is O_CREAT|O_EXCL: the call fails if anything exists at the
%% path, a symbolic link included, so nothing is ever overwritten.

open_exclusive(Path) ->
    posix(file:open(Path, [write, exclusive, raw, binary])).

write(File, Data) ->
    posix(file:write(File, Data)).

sync(File) ->
    posix(file:datasync(File)).

close(File) ->
    posix(file:close(File)).

%% Deletes `Path` if the calling process exits before `unwatch` is called.
%% An upload deletes its partial file itself on every path it controls; this
%% covers the ones it doesn't: the connection process being killed (server
%% shutdown) or crashing.
watch(Path) ->
    Owner = self(),
    spawn(fun() ->
        Monitor = monitor(process, Owner),
        receive
            unwatch -> demonitor(Monitor, [flush]);
            {'DOWN', Monitor, process, Owner, _} -> file:delete(Path)
        end
    end).

unwatch(Watcher) ->
    Watcher ! unwatch,
    nil.

%% Works around ewe 9.0.0. Each `ewe.read_body_chunk` posts the body's
%% progress to the connection process, the one running the handler, to
%% read once the handler returns: `{Tag, {body_signal, {body_progress,
%% Buffer, Read, Remaining}}}`. Only the last one is used, but they all stay
%% in the mailbox until then, and each one's buffer holds on to the data it
%% was cut from: a long upload kept all of itself in memory. Discarding the
%% earlier ones before each read keeps one at most, and the next read
%% always posts a new one.
discard_body_progress() ->
    receive
        {_Tag, {body_signal, {body_progress, _, _, _}}} -> discard_body_progress()
    after 0 -> nil
    end.

%% Results in the shape of `simplifile.FileError`, whose constructors are
%% the POSIX error atoms.
posix(ok) -> {ok, nil};
posix({ok, Value}) -> {ok, Value};
posix({error, Reason}) when is_atom(Reason) ->
    case lists:member(Reason, known_errors()) of
        true -> {error, Reason};
        false -> {error, {unknown, string:uppercase(atom_to_binary(Reason))}}
    end;
posix({error, Reason}) ->
    {error, {unknown, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}}.

known_errors() ->
    [eacces, eagain, ebadf, ebusy, edquot, eexist, efbig, eintr, einval, eio,
     eisdir, eloop, emfile, emlink, enametoolong, enfile, enodev, enoent,
     enomem, enospc, enotdir, enotsup, eopnotsupp, eperm, erofs, espipe,
     estale, etxtbsy, exdev].
