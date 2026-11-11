@moduledoc """
houshi's storage levels against real peers: `chozou/kiibariu` against a
valkey-server, and `chozou/sutoriimu` against a JetStream nats-server, with a
PostgreSQL for the outbox. Each test starts its own peer on a free loopback
port and stops it when the test ends, so no test sees another's data. A peer
that is not on PATH fails the test; it is never a skip.

    free_port > 0 #=> true
"""

use("houshi/chozou/kiibariu")
use("houshi/chozou/sutoriimu")
use("jisho", [:merge])
use("moji", [:trim])
use("shisutemu", [:run_capture])

@doc """
free_port: a loopback port nothing listens on: the one the system gave a
listener that is now closed.

    free_port > 0 #=> true
"""
def free_port()
  l = tcp_listen("127.0.0.1:0")
  p = tcp_port(l)
  tcp_close(l)
  p
end

@doc """
on_path: the absolute path of the executable `name` on PATH. A name PATH does
not hold raises :peer naming it, so a missing peer is a red test.

    raised(() -> on_path("no-such-peer-here")) #=> "no-such-peer-here is not on PATH"
"""
def on_path(name)
  hits = filter(
    (p) -> path_exists(p),
    map((d) -> path_join(d, name), split(getenv("PATH", ""), ":"))
  )
  if hits == []
    raise(:peer, "#{name} is not on PATH")
  else
    hits[0]
  end
end

@doc """
scratch: a fresh directory for one peer, named by its port, under TMPDIR.
"""
def scratch(name, port)
  dir = path_join(getenv("TMPDIR", "/tmp"), "houshi-#{name}-#{to_s(port)}")
  rm_rf(dir)
  mkdir_p(dir)
  dir
end

@doc """
listening: waits until something accepts on the loopback `port`, for at
most 15 seconds, then raises :peer naming the port.

    starts_with?(raised(() -> listening(free_port, 0)), "nothing listened on ") #=> true
"""
def listening(port, left_ms)
  if integer?(tcp_connect_ms("127.0.0.1", port, 200))
    port
  elsif left_ms <= 0
    raise(:peer, "nothing listened on #{to_s(port)}")
  else
    sleep_ms(20)
    listening(port, left_ms - 20)
  end
end

@doc """
started: runs `argv` to its end, and raises :peer with the reason when it
did not exit 0.

    raised(() -> started(["no-such-peer-here"])) #=> "no-such-peer-here could not be started"
"""
def started(argv)
  r = run_capture(argv)
  if not r[:ok]
    raise(:peer, r[:why])
  end
  r
end

@doc """
daemon: starts `cmd args` detached through daemonize, its pid in the peer's
directory, and answers the peer {port:, dir:} once its port accepts.
"""
def daemon(dir, port, cmd, args)
  pid = path_join(dir, "pid")
  started(
    append(
      [
        on_path("daemonize"),
        "-p",
        pid,
        "-o",
        path_join(dir, "out"),
        "-e",
        path_join(dir, "err"),
        "-c",
        dir,
        on_path(cmd)
      ],
      args
    )
  )
  ready({port:, dir:, pid:})
end

@doc """
ready: the peer once its port accepts; a peer that never listens is stopped
before the reason is raised again, so a failed start leaves no process behind.
"""
def ready(peer)
  listening(peer[:port], 15000)
  peer
rescue e
  stop(peer)
  raise(e)
end

@doc """
stop: ends a peer: its stop command when it has one, else a signal to the pid
it recorded, then removes its directory.
"""
def stop(peer)
  if peer[:stop] != nil
    run_capture(peer[:stop])
  elsif path_exists(peer[:pid])
    run_capture(["kill", trim(read_file(peer[:pid]))])
  end
  rm_rf(peer[:dir])
end

@doc """
with_peer: runs `body` on a started peer and stops the peer however the body
ends.
"""
def with_peer(peer, body)
  body(peer)
ensure
  stop(peer)
end

@doc """
valkey: a valkey-server on a free port, saving nothing, with `password`
required when it is not nil.
"""
def valkey(password)
  port = free_port
  dir = scratch("valkey", port)
  auth = if password.nil?
    []
  else
    ["--requirepass", password]
  end
  daemon(
    dir,
    port,
    "valkey-server",
    append(
      [
        "--port",
        to_s(port),
        "--bind",
        "127.0.0.1",
        "--save",
        "",
        "--appendonly",
        "no",
        "--dir",
        dir
      ],
      auth
    )
  )
end

@doc """
nats: a nats-server with JetStream on a free port, its store in the peer's
directory.
"""
def nats()
  port = free_port
  dir = scratch("nats", port)
  conf = path_join(dir, "nats.conf")
  write_file(
    conf,
    unlines(
      [
        "host: 127.0.0.1",
        "port: #{to_s(port)}",
        "jetstream { store_dir: \"#{path_join(dir, "js")}\" }"
      ]
    )
  )
  daemon(dir, port, "nats-server", ["-c", conf])
end

@doc """
postgres: a PostgreSQL cluster made by initdb for the role blue with trust
auth, started by pg_ctl on a free port, its socket in the peer's directory.
"""
def postgres()
  port = free_port
  dir = scratch("pg", port)
  data = path_join(dir, "data")
  started([on_path("initdb"), "-D", data, "-U", "blue", "--auth=trust"])
  ctl = on_path("pg_ctl")
  started(
    [
      ctl,
      "-D",
      data,
      "-o",
      "-p #{to_s(port)} -k #{dir} -c listen_addresses=127.0.0.1",
      "-w",
      "start",
      "-l",
      path_join(dir, "log")
    ]
  )
  {port:, dir:, stop: [ctl, "-D", data, "-m", "immediate", "stop"]}
end

@doc """
raised: the message of what `f` raises, or :answered when it answers.

    raised(() -> raise(:x, "boom")) #=> "boom"
"""
def raised(f)
  f()
  :answered
rescue e
  e.message
end

@doc """
conn: a plain loopback connection to the valkey peer, with `extra` options
merged in.
"""
def conn(v, extra)
  houshi::chozou::kiibariu::connect(
    merge({host: "127.0.0.1", port: v[:port], tls: false}, extra)
  )
end

@doc """
schema: the order schemas and the upgrade plan from version h1 to h2 the
kiibariu tests share.
"""
def schema()
  from = {fields: {"total" => :int}}
  to = {fields: {"total" => :int, "currency" => :text}}
  plan = {
    from:,
    to:,
    old: houshi::chozou::kiibariu::prefix("orders", "h1", :order),
    new: houshi::chozou::kiibariu::prefix("orders", "h2", :order),
    transform: (r) -> assoc(r, "currency", "BRL")
  }
  {from:, to:, plan:}
end

@doc """
stream: a JetStream connection to the nats peer with the stream orders over
orders.> declared, and the url it dialled.
"""
def stream(n)
  url = "nats://127.0.0.1:#{to_s(n[:port])}"
  c = nats_connect(url)
  houshi::chozou::sutoriimu::ensure_stream(c, "orders", ["orders.>"])
  {url:, c:}
end

test "get, set, a ttl and del round-trip behind a password file"
  with_peer(
    valkey("hunter2"),
    fn(v)
      pw = path_join(v[:dir], "pw")
      write_file(pw, unlines(["hunter2"]))
      c = conn(v, {password_file: pw})
      houshi::chozou::kiibariu::set_key(c, "a", "1", nil)
      houshi::chozou::kiibariu::set_key(c, "b", "2", 60000)
      t = houshi::chozou::kiibariu::pttl(c, "b")
      assert [
        houshi::chozou::kiibariu::get_key(c, "a"),
        houshi::chozou::kiibariu::get_key(c, "nope"),
        t > 0 and t <= 60000,
        houshi::chozou::kiibariu::pttl(c, "a"),
        houshi::chozou::kiibariu::del(c, %w[a b z]),
        houshi::chozou::kiibariu::get_key(c, "a")
      ] == ["1", nil, true, -1, 2, nil]
      wrong = path_join(v[:dir], "wrong")
      write_file(wrong, unlines(["nope"]))
      e = raised(() -> conn(v, {password_file: wrong}))
      assert contains?(e, "resp_connect")
    end
  )
end

test "TLS on is refused by name, and TLS off only on loopback"
  e = raised(
    () -> houshi::chozou::kiibariu::connect({host: "127.0.0.1", port: 1})
  )
  assert contains?(e, "no TLS transport")
  e = raised(() -> resp_connect("10.0.0.1", 6379, nil, false))
  assert contains?(e, "only for 127.0.0.1")
end

test "a subscriber receives what another connection publishes"
  with_peer(
    valkey(nil),
    fn(v)
      c = conn(v, {})
      s = conn(v, {})
      houshi::chozou::kiibariu::subscribe(s, %w[orders other])
      n = houshi::chozou::kiibariu::publish(c, "orders", "created 7")
      m = houshi::chozou::kiibariu::next_message(s, 2000)
      assert [
        n,
        m[:channel],
        m[:payload],
        houshi::chozou::kiibariu::next_message(s, 50)
      ] == [1, "orders", "created 7", nil]
    end
  )
end

test "scan walks every key of a pattern in batches"
  with_peer(
    valkey(nil),
    fn(v)
      c = conn(v, {})
      resp_pipeline(c, map((i) -> ["SET", "k:#{to_s(i)}", "x"], range(25)))
      houshi::chozou::kiibariu::set_key(c, "other", "y", nil)
      assert length(houshi::chozou::kiibariu::scan(c, "k:*", 4)) == 25
    end
  )
end

test "a strict put and fetch check the schema both ways"
  with_peer(
    valkey(nil),
    fn(v)
      c = conn(v, {})
      s = schema
      houshi::chozou::kiibariu::put(
        c,
        s[:from],
        "orders:vh1:order:1",
        {"total" => 5},
        nil
      )
      assert get(
        houshi::chozou::kiibariu::fetch(c, s[:from], "orders:vh1:order:1"),
        "total"
      ) == 5
      e = raised(
        fn()
          houshi::chozou::kiibariu::put(c, s[:from], "k", {"total" => "5"}, nil)
        end
      )
      assert contains?(e, "field total")
      houshi::chozou::kiibariu::set_key(c, "k", "{\"t\":1}", nil)
      e = raised(() -> houshi::chozou::kiibariu::fetch(c, s[:from], "k"))
      assert contains?(e, "no field total")
    end
  )
end

test "upgrade on read moves one entry and keeps its ttl"
  with_peer(
    valkey(nil),
    fn(v)
      c = conn(v, {})
      s = schema
      houshi::chozou::kiibariu::put(
        c,
        s[:from],
        "orders:vh1:order:7",
        {"total" => 3},
        90000
      )
      r = houshi::chozou::kiibariu::read_upgrading(c, s[:plan], 7)
      t = houshi::chozou::kiibariu::pttl(c, "orders:vh2:order:7")
      assert [
        r["currency"],
        houshi::chozou::kiibariu::get_key(c, "orders:vh1:order:7"),
        t > 80000 and t <= 90000,
        houshi::chozou::kiibariu::read_upgrading(c, s[:plan], 7)["currency"],
        houshi::chozou::kiibariu::read_upgrading(c, s[:plan], 8)
      ] == ["BRL", nil, true, "BRL", nil]
    end
  )
end

test "an eager upgrade rewrites every old key in batches, keeping ttls"
  with_peer(
    valkey(nil),
    fn(v)
      c = conn(v, {})
      s = schema
      houshi::chozou::kiibariu::put(
        c,
        s[:from],
        "orders:vh1:order:0",
        {"total" => 0},
        nil
      )
      map(
        fn(i)
          houshi::chozou::kiibariu::put(
            c,
            s[:from],
            "orders:vh1:order:#{to_s(i)}",
            {"total" => i},
            90000
          )
        end,
        drop(1, range(23))
      )
      moved = houshi::chozou::kiibariu::upgrade_eager(c, s[:plan], 5)
      assert [
        moved,
        length(houshi::chozou::kiibariu::scan(c, "orders:vh1:*", 10)),
        length(houshi::chozou::kiibariu::scan(c, "orders:vh2:*", 10)),
        houshi::chozou::kiibariu::pttl(c, "orders:vh2:order:0"),
        houshi::chozou::kiibariu::pttl(c, "orders:vh2:order:9") > 80000,
        get(
          houshi::chozou::kiibariu::fetch(c, s[:to], "orders:vh2:order:9"),
          "total"
        )
      ] == [23, 0, 23, -1, true, 9]
    end
  )
end

test "a publish is acked with its sequence, and a stream redeclares"
  with_peer(
    nats,
    fn(n)
      c = stream(n)[:c]
      a = houshi::chozou::sutoriimu::publish(c, "orders.created", "1", 2000)
      b = houshi::chozou::sutoriimu::publish(c, "orders.created", "2", 2000)
      houshi::chozou::sutoriimu::ensure_stream(c, "orders", ["orders.>"])
      assert [a[:stream], a[:seq], b[:seq]] == ["orders", 1, 2]
    end
  )
end

test "a durable consumer redelivers a nak and not an ack"
  with_peer(
    nats,
    fn(n)
      c = stream(n)[:c]
      houshi::chozou::sutoriimu::durable(
        c,
        "orders",
        "billing",
        "orders.>",
        30000
      )
      houshi::chozou::sutoriimu::publish(c, "orders.created", "a", 2000)
      houshi::chozou::sutoriimu::publish(c, "orders.created", "b", 2000)
      first_batch = houshi::chozou::sutoriimu::fetch(
        c,
        "orders",
        "billing",
        10,
        500
      )
      houshi::chozou::sutoriimu::ack(c, first_batch[0])
      houshi::chozou::sutoriimu::nak(c, first_batch[1], nil)
      again = houshi::chozou::sutoriimu::fetch(c, "orders", "billing", 10, 500)
      houshi::chozou::sutoriimu::ack(c, again[0])
      empty = houshi::chozou::sutoriimu::fetch(c, "orders", "billing", 10, 300)
      assert [
        map((m) -> m[:payload], first_batch),
        map((m) -> m[:payload], again),
        again[0][:deliveries],
        length(empty)
      ] == [%w[a b], ["b"], 2, 0]
    end
  )
end

test "the outbox commits with the change and drains to the stream"
  with_peer(
    nats,
    fn(n)
      with_peer(
        postgres,
        fn(p)
          c = stream(n)[:c]
          pg = pg_connect(
            "postgres://blue@127.0.0.1:#{to_s(p[:port])}/postgres"
          )
          pg_execute(pg, houshi::chozou::sutoriimu::outbox_ddl("outbox"))
          pg_execute(pg, "CREATE TABLE orders (id int PRIMARY KEY, total int)")
          houshi::chozou::sutoriimu::write_with_outbox(
            pg,
            "outbox",
            ["INSERT INTO orders VALUES ($1, $2)", [1, 10]],
            [%w[orders.created 1]]
          )
          failed = begin
            houshi::chozou::sutoriimu::write_with_outbox(
              pg,
              "outbox",
              ["INSERT INTO orders VALUES ($1, $2)", [1, 20]],
              [%w[orders.created dup]]
            )
          rescue e
            e.kind
          end
          rows = length(pg_query(pg, "SELECT * FROM outbox", [])[:rows])
          houshi::chozou::sutoriimu::durable(
            c,
            "orders",
            "audit",
            "orders.>",
            30000
          )
          moved = houshi::chozou::sutoriimu::drain(pg, c, "outbox", 10, 2000)
          left = length(pg_query(pg, "SELECT * FROM outbox", [])[:rows])
          got = houshi::chozou::sutoriimu::fetch(c, "orders", "audit", 10, 500)
          assert [
            rows,
            failed != nil,
            moved,
            left,
            map((m) -> m[:payload], got)
          ] == [1, true, 1, 0, ["1"]]
        end
      )
    end
  )
end

test "a supervised consumer restarts after its handler raises and gets the message again"
  with_peer(
    nats,
    fn(n)
      s = stream(n)
      c = s[:c]
      houshi::chozou::sutoriimu::durable(c, "orders", "ship", "orders.>", 30000)
      map(
        (p) -> houshi::chozou::sutoriimu::publish(c, "orders.created", p, 2000),
        %w[a boom b]
      )
      parent = self
      handler = fn(m)
        if m[:payload] == "boom" and m[:deliveries] == 1
          raise(:poison, "first delivery")
        end
        send(parent, [m[:payload], m[:deliveries]])
      end
      houshi::chozou::sutoriimu::consumer(
        s[:url],
        "orders",
        "ship",
        handler,
        {batch: 1, wait_ms: 200}
      )
      take = fn(acc)
        if length(acc) == 3
          acc
        else
          take(append(acc, [receive(:_, 10000, :none)]))
        end
      end
      assert take([]) == [["a", 1], ["boom", 2], ["b", 1]]
    end
  )
end
