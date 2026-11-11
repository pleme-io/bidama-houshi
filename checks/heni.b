@moduledoc """
The heni gate over houshi's levels: each file under `heni/mutations/` names a
level by its path below `bidamas/` (`houshi/chozou/teeburu.json` mutates
`bidamas/houshi/chozou/teeburu`), heni runs every mutation in it, and the
caught ratio must not fall below its row in `heni/ratio.baseline`. A
mutation the level's tests survive is a behaviour nothing checks, so it turns
this check red and names itself.

`blue run checks/heni.b record` rewrites the baseline from a fresh run; a fall
needs `--receipt "<why>"`.

    key_of("heni/mutations/houshi/shinchoku.json") #=> "houshi/shinchoku"
"""

use("hadome", %i[measurement orphans parse recorded render])

use("heni", %i[fell? mutations report_text run score sound? survivors])

use("retsu", %i[flat_map is_empty last size])
use("shisutemu", [:read_or])

CAUGHT = "heni-caught"

TOTAL = "heni-total"

RECORD = "blue run checks/heni.b record"

@doc """
root: the directory holding `heni/` and `bidamas/`: GEN_ROOT in a nix check,
else the current directory.

    string?(root) #=> true
"""
def root()
  getenv("GEN_ROOT", ".")
end

@doc """
specs: every mutation file under heni/mutations, in path order.
"""
def specs()
  filter(
    (p) -> ends_with?(p, ".json"),
    sort_keyed((p) -> p, walk_dir(path_join(root, "heni/mutations")))
  )
end

@doc """
key_of: the level a mutation file names, its path below heni/mutations
without `.json`.

    key_of("x/heni/mutations/houshi/mitoshi/keisoku.json") #=> "houshi/mitoshi/keisoku"
"""
def key_of(spec_path)
  replace(last(split(spec_path, "heni/mutations/")), ".json", "")
end

@doc """
baseline_path: where the recorded caught ratios live.
"""
def baseline_path()
  path_join(root, "heni/ratio.baseline")
end

@doc """
report: heni's run of one mutation file against the level it names.
"""
def report(spec_path)
  run(
    {
      package: path_join(path_join(root, "bidamas"), key_of(spec_path)),
      mutations: mutations(json_parse(read_file(spec_path))),
      blue: self_exe,
      test: nil,
      tmp: getenv("TMPDIR", "/tmp")
    }
  )
end

def ratio_text(q)
  "#{to_s(q[:caught])}/#{to_s(q[:total])}"
end

@doc """
recorded_ratio: a level's recorded {caught, total}, or nil when the baseline
has no row for it.

    recorded_ratio(parse(unlines(["heni-caught: k 1", "heni-total: k 2"])), "k") #=> {caught: 1, total: 2}
"""
def recorded_ratio(rows, key)
  c = recorded(rows, CAUGHT, key)
  t = recorded(rows, TOTAL, key)
  if c.nil? or t.nil?
    nil
  else
    {caught: c, total: t}
  end
end

def survived_text(r)
  names = survivors(r)
  if is_empty(names)
    "no survivor, so a caught mutation was removed"
  else
    "survived: #{join(names, ", ")}"
  end
end

@doc """
problems: what is wrong with one level's run against the baseline: an unsound
run, a level with no row, or a caught ratio below its row, which names each
survivor.
"""
def problems(rows, key, r)
  if not sound?(r)
    ["#{key}: #{report_text(r)}"]
  else
    was = recorded_ratio(rows, key)
    now = score(r)
    if was.nil?
      [
        "#{key}: caught #{ratio_text(now)} and the baseline has no row for it; record it: #{RECORD}"
      ]
    elsif fell?(was, now)
      [
        "#{key}: caught #{ratio_text(now)}, below its recorded #{ratio_text(was)}; #{survived_text(r)}"
      ]
    else
      []
    end
  end
end

def measure(paths)
  map((s) -> {key: key_of(s), r: report(s)}, paths)
end

def judge(rows, measured)
  flat_map(measured, (m) -> problems(rows, m[:key], m[:r]))
end

def rendered(measured)
  join(
    map(
      fn(m)
        q = score(m[:r])
        concat(
          render(CAUGHT, [measurement(m[:key], q[:caught])]),
          render(TOTAL, [measurement(m[:key], q[:total])])
        )
      end,
      sort_keyed((m) -> m[:key], measured)
    ),
    ""
  )
end

def baseline_text(old, receipt, measured)
  notes = append(
    filter((l) -> starts_with?(l, "#"), split(old, line_break)),
    if receipt.nil?
      []
    else
      ["# receipt: #{receipt}"]
    end
  )
  if is_empty(notes)
    rendered(measured)
  else
    concat(unlines(notes), rendered(measured))
  end
end

def receipt_of(args)
  at = position("--receipt", args)
  if at < 0
    nil
  else
    args[at + 1] rescue nil
  end
end

def record(receipt)
  path = baseline_path
  old = read_or(path, "")
  rows = parse(old)
  measured = measure(specs)
  unsound = filter((m) -> not sound?(m[:r]), measured)
  fell = filter(
    fn(m)
      was = recorded_ratio(rows, m[:key])
      was != nil and fell?(was, score(m[:r]))
    end,
    measured
  )
  if not is_empty(unsound)
    write_stderr(unlines(judge([], unsound)))
    write_stderr(unlines(["refused: a run that is not sound records nothing"]))
    exit_with(1)
  elsif not is_empty(fell) and receipt.nil?
    write_stderr(unlines(judge(rows, fell)))
    write_stderr(
      unlines(["refused: a fall needs a reason: #{RECORD} --receipt \"<why>\""])
    )
    exit_with(1)
  else
    write_file(path, baseline_text(old, receipt, measured))
    write_stdout(
      unlines(["recorded #{to_s(size(measured))} level(s) to #{path}"])
    )
  end
end

def main()
  if argv_get(0) == "record"
    record(receipt_of(drop(1, argv)))
  else
    write_stderr(unlines(["usage: #{RECORD} [--receipt WHY]"]))
    exit_with(64)
  end
end

test "every level holds its recorded caught ratio"
  all = specs
  assert size(all) >= 4
  rows = parse(read_or(baseline_path, ""))
  measured = measure(all)
  map(
    fn(k)
      write_stderr(
        unlines(
          ["#{k}: recorded, and no mutation file names it; drop it: #{RECORD}"]
        )
      )
    end,
    orphans(rows, CAUGHT, map(key_of, all))
  )
  bad = judge(rows, measured)
  if not is_empty(bad)
    write_stderr(unlines(bad))
  end
  assert is_empty(bad)
end
