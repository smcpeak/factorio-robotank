#!/bin/sh
# command line unit tests for RoboTank

# /d/dist/factorio is where I put serpent.lua.

export LUA_PATH='/d/SteamLibrary/steamapps/common/Factorio/data/core/lualib/?.lua;/d/dist/factorio/?.lua;?.lua'
lua -l stubs -l control -e 'unit_tests()' || exit

# EOF
