CFLAGS = -O3 -ffast-math -fPIC -shared

ERL_INCLUDE = $(shell erl -eval 'io:format("~s", [code:root_dir()]).' -s init stop -noshell)/usr/include

all:
	gcc $(CFLAGS) -I$(ERL_INCLUDE) ./native/rinha_nif.c -o ./priv/rinha_nif.so
