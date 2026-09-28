# Bend 2.0.29 (upstream main 574b6d39); also pr/gpu-profile.
# A module's defs are reached through its import alias, so a def that
# mod.bend names M.f is M.M.f to a file that imports it as M. Calling
# M.f with a ~ argument then fails as a parse error at the ~, not as an
# unknown name:
#
#   bun bend2/main.ts repros/alias_prefix/main.bend --check-only
#   Error:
#   - expected : a term
#   - observed : '~'
#   Location:
#   >|   M.f(~inc, 1)
#     |       ^
#
# Without the ~ argument (M.g(1) for a missing g) the error is good:
# "expected : a defined name, observed : mod.g". M.M.f(~inc, 1) works.
# Wanted: the same "not a defined name" error here, ideally noting that
# mod.bend defines M.f, which this file reaches as M.M.f.
# (Hit in bend-craft: world.bend's W.gen was W.W.gen to its importers.)
import Base
import ./mod.bend as M

def inc(x: U32) -> U32:
  (x + 1 : U32)

def main() -> U32:
  M.f(~inc, 1)
