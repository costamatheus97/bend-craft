# Bend 2.0.29 (upstream main 574b6d39); also pr/gpu-profile.
# Not a bug: our own mistake, kept because the message could say more.
# The annotation sugar is (e : T), with the parentheses around the whole
# thing. Written as f((e) : T), the ':' has no term before it in f's
# argument list:
#
#   bun bend2/main.ts repros/annotation_outside_parens.bend --check-only
#   Error:
#   - expected : a term
#   - observed : ':'
#   >|   mix((c * 3 + mix(d)) : U32)
#     |                        ^
#
# It surfaced deep inside a nested hash combiner, where it read like a
# problem with nesting. Wanted: a hint such as "a type annotation goes
# inside the parentheses: (e : T)". The fix: mix((c * 3 + mix(d) : U32)).
import Base

def mix(x: U32) -> U32:
  (x * 3 : U32)

def cmb(+c: U32, +d: U32) -> U32:
  mix((c * 3 + mix(d)) : U32)

def main() -> U32:
  cmb(3, 4)
