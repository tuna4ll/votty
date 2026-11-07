ODIN ?= odin
TESTS ?= /tmp/votty-tests

release:
	$(ODIN) build . -out:votty -o:speed -vet -strict-style

debug:
	$(ODIN) build . -out:votty-debug -debug -vet -strict-style

check:
	$(ODIN) check . -vet -strict-style
	$(ODIN) check term -no-entry-point -vet -strict-style

# test sources live outside the repository
test:
	$(ODIN) test $(TESTS) -collection:votty=. -vet -define:ODIN_TEST_THREADS=1

clean:
	rm -f votty votty-debug

.PHONY: release debug check test clean
