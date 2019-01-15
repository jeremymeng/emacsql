#!/usr/bin/bash

git clone https://github.com/dlfcn-win32/dlfcn-win32.git
cd dlfcn-win32/
./configure
env CC=gcc make
make install
ln -s /mingw/lib/libdl.a /mingw64/lib/libdl.a
