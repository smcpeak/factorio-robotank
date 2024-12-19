#!/bin/sh
# command line unit tests for RoboTank

# $HOME/dist/games/factorio is where I put serpent.lua.

export LUA_PATH="/d/opt/Steam/steamapps/common/Factorio/data/core/lualib/?.lua;$HOME/dist/games/factorio/?.lua;?.lua"
lua -l stubs -l control -e 'unit_tests()' || exit

# EOF
