-module(beap_test_ffi).
-export([
    temp_dir/1, request/5, concurrent_puts/3, upload_stream/5,
    download_digest/2, send_partial/4, sha256_file/1, memory_peak_during/1,
    exit_after/2, silence_output/0
]).

%% A new, empty directory for one test, as a real path.
temp_dir(Name) ->
    Base = case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir -> Dir
    end,
    Path = filename:join([Base, "beap_test", unicode:characters_to_list(Name)]),
    _ = file:del_dir_r(Path),
    ok = filelib:ensure_path(Path),
    unicode:characters_to_binary(Path).

%% --- HTTP/1.1 client -----------------------------------------------------------
%% Requests ask for `connection: close`, so a response ends with the socket.

connect(Port) ->
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port,
                                   [binary, {active, false}, {packet, raw}]),
    Socket.

head(Port, Method, Path, Headers) ->
    [Method, " ", Path, " HTTP/1.1\r\n",
     "host: 127.0.0.1:", integer_to_list(Port), "\r\n",
     "connection: close\r\n",
     [[Name, ": ", Value, "\r\n"] || {Name, Value} <- Headers]].

%% {Status, Headers, Body}, header names in lowercase.
request(Port, Method, Path, Headers, Body) ->
    Socket = connect(Port),
    Length = case {Method, Body} of
        {<<"PUT">>, _} -> ["content-length: ", integer_to_list(byte_size(Body)), "\r\n"];
        {_, <<>>} -> [];
        _ -> ["content-length: ", integer_to_list(byte_size(Body)), "\r\n"]
    end,
    ok = gen_tcp:send(Socket, [head(Port, Method, Path, Headers), Length, "\r\n", Body]),
    Response = read_until_closed(Socket, []),
    parse_response(Response).

read_until_closed(Socket, Acc) when is_list(Acc) ->
    case gen_tcp:recv(Socket, 0, 30000) of
        {ok, Data} -> read_until_closed(Socket, Acc ++ [Data]);
        {error, _} ->
            gen_tcp:close(Socket),
            iolist_to_binary(Acc)
    end.

parse_response(<<>>) -> {0, [], <<>>};
parse_response(Response) ->
    [Head, Body] = binary:split(Response, <<"\r\n\r\n">>),
    [StatusLine | HeaderLines] = binary:split(Head, <<"\r\n">>, [global]),
    [_, Status | _] = binary:split(StatusLine, <<" ">>, [global]),
    Headers = [begin
                   [Name, Value] = binary:split(Line, <<":">>),
                   {string:lowercase(Name), string:trim(Value)}
               end || Line <- HeaderLines],
    {binary_to_integer(Status), Headers, Body}.

%% The same PUT of each body, all at once. Results in the bodies' order.
concurrent_puts(Port, Path, Bodies) ->
    Parent = self(),
    Pids = [spawn_link(fun() ->
                Parent ! {self(), request(Port, <<"PUT">>, Path, [], Body)}
            end) || Body <- Bodies],
    [receive {Pid, Result} -> Result end || Pid <- Pids].

%% PUTs `Size` bytes of generated data, 64 KiB at a time, chunked or with a
%% Content-Length, never holding more than one piece. Returns {Status,
%% Body, Sha256} of what was sent; status 0 when the server hung up without
%% a response that could be read.
%%
%% With a Content-Length, it waits for `100 Continue` before sending the
%% body, as curl does: a server refusing the upload answers at once.
upload_stream(Port, Path, Size, Chunked, Seed) ->
    Socket = connect(Port),
    Framing = case Chunked of
        true -> "transfer-encoding: chunked\r\n";
        false -> ["content-length: ", integer_to_list(Size), "\r\nexpect: 100-continue\r\n"]
    end,
    ok = gen_tcp:send(Socket, [head(Port, <<"PUT">>, Path, []), Framing, "\r\n"]),
    Continue = Chunked orelse continue(Socket),
    case Continue of
        {final, Response} ->
            {Status, _, Body} = parse_response(Response),
            {Status, Body, <<>>};
        _ ->
            Digest = send_pieces(Socket, Size, Chunked, Seed, crypto:hash_init(sha256)),
            case Chunked of
                true -> gen_tcp:send(Socket, <<"0\r\n\r\n">>);
                false -> ok
            end,
            {Status, _, Body} = parse_response(read_until_closed(Socket, [])),
            {Status, Body, crypto:hash_final(Digest)}
    end.

%% `true` after `100 Continue`, or the final response the server sent
%% instead.
continue(Socket) ->
    {ok, Data} = gen_tcp:recv(Socket, 0, 30000),
    case Data of
        <<"HTTP/1.1 100", _/binary>> -> true;
        _ -> {final, read_until_closed(Socket, [Data])}
    end.

send_pieces(_Socket, 0, _Chunked, _Seed, Digest) -> Digest;
send_pieces(Socket, Left, Chunked, Seed, Digest) ->
    Size = min(Left, 65536),
    Piece = piece(Seed, Left, Size),
    Framed = case Chunked of
        true -> [integer_to_list(Size, 16), "\r\n", Piece, "\r\n"];
        false -> Piece
    end,
    case gen_tcp:send(Socket, Framed) of
        ok -> send_pieces(Socket, Left - Size, Chunked, Seed, crypto:hash_update(Digest, Piece));
        {error, _} -> Digest
    end.

%% Deterministic bytes, different for every piece.
piece(Seed, Left, Size) ->
    Block = crypto:hash(sha512, <<Seed:32, Left:64>>),
    binary:part(binary:copy(Block, Size div 64 + 1), 0, Size).

%% GETs a file, hashing it as it arrives: {Status, Size, Sha256}.
download_digest(Port, Path) ->
    Socket = connect(Port),
    ok = gen_tcp:send(Socket, [head(Port, <<"GET">>, Path, []), "\r\n"]),
    {Status, Rest} = read_head(Socket, <<>>),
    hash_body(Socket, Status, byte_size(Rest), crypto:hash_update(crypto:hash_init(sha256), Rest)).

read_head(Socket, Acc) ->
    {ok, Data} = gen_tcp:recv(Socket, 0, 30000),
    Buffer = <<Acc/binary, Data/binary>>,
    case binary:split(Buffer, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            <<"HTTP/1.1 ", Status:3/binary, _/binary>> = Head,
            {binary_to_integer(Status), Rest};
        [_] -> read_head(Socket, Buffer)
    end.

hash_body(Socket, Status, Size, Digest) ->
    case gen_tcp:recv(Socket, 0, 30000) of
        {ok, Data} -> hash_body(Socket, Status, Size + byte_size(Data), crypto:hash_update(Digest, Data));
        {error, _} ->
            gen_tcp:close(Socket),
            {Status, Size, crypto:hash_final(Digest)}
    end.

%% Announces `Declared` bytes, sends `Sent` of them, and hangs up.
send_partial(Port, Path, Declared, Sent) ->
    Socket = connect(Port),
    ok = gen_tcp:send(Socket, [head(Port, <<"PUT">>, Path, []),
                               "content-length: ", integer_to_list(Declared), "\r\n\r\n",
                               binary:copy(<<"x">>, Sent)]),
    timer:sleep(100),
    gen_tcp:close(Socket),
    nil.

sha256_file(Path) ->
    {ok, File} = file:open(Path, [read, raw, binary]),
    Digest = hash_file(File, crypto:hash_init(sha256)),
    file:close(File),
    Digest.

hash_file(File, Digest) ->
    case file:read(File, 1048576) of
        {ok, Data} -> hash_file(File, crypto:hash_update(Digest, Data));
        eof -> crypto:hash_final(Digest)
    end.

%% Runs `Fun` while sampling the VM's memory every 20 ms: {Result, Peak
%% growth over the start, in bytes}.
memory_peak_during(Fun) ->
    erlang:garbage_collect(),
    Start = erlang:memory(total),
    Parent = self(),
    Sampler = spawn_link(fun() -> sample(Parent, Start) end),
    Result = Fun(),
    Sampler ! stop,
    Peak = receive {peak, P} -> P end,
    {Result, Peak - Start}.

sample(Parent, Peak) ->
    receive
        stop -> Parent ! {peak, Peak}
    after 20 ->
        sample(Parent, max(Peak, erlang:memory(total)))
    end.

%% Runs `Fun` in a process that exits right after, as a killed connection
%% would.
exit_after(Fun, Delay) ->
    Pid = spawn(fun() -> Fun(), timer:sleep(infinity) end),
    timer:sleep(Delay),
    exit(Pid, kill),
    timer:sleep(100),
    nil.

%% Sends the output of this process, and of the processes it starts (the
%% server's), nowhere: keeps the access log out of the test report.
silence_output() ->
    group_leader(spawn(fun null_io/0), self()),
    nil.

null_io() ->
    receive
        {io_request, From, ReplyAs, _} -> From ! {io_reply, ReplyAs, ok}
    end,
    null_io().
