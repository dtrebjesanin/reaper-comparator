import sys, pathlib
from lupa import LuaRuntime

HERE = pathlib.Path(__file__).resolve().parent
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(f'package.path = [[{(HERE.parent / "?.lua").as_posix()}]] .. ";" .. package.path')
result = lua.eval('pcall(dofile, [[' + (HERE / 'test_bridge.lua').as_posix() + ']])')
# pcall returns a single `true` (no second value) when the chunk succeeds
# without returning anything, so only unpack a tuple when there is one.
if isinstance(result, tuple):
    ok, err = result
else:
    ok, err = result, None
if not ok:
    print('FAIL:', err); sys.exit(1)
print('ALL BRIDGE TESTS PASSED')
