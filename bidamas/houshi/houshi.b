@moduledoc """
houshi (奉仕, service): the blue bidamas a running service is built from: what it keeps, retries, runs on and shows of itself. Each is a level of this tree, reached as `houshi::<level>::<word>` after `use("houshi/<level>")`.

    length(members) #=> 5
"""

@doc """
members: the levels of houshi, in the order they joined it.

    nth(0, members) #=> "chozou"
"""
def members()
  %w[chozou saishikou kurasuta mitoshi shinchoku]
end

test "members names each level once"
  assert length(members) == 5
  assert members[0] == "chozou"
end
