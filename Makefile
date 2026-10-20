CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra
SO       = cs_lowspeed.so

all: $(SO)

$(SO): cs_lowspeed.c
	$(CC) $(CFLAGS) -fPIC -shared -Wl,-z,defs -o $@ $< -ldl

test: $(SO)
	bash tests/run_tests.sh

clean:
	rm -f $(SO) tests/caller tests/libfakecurl.so

.PHONY: all test clean
