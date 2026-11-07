ODIN ?= odin
TESTS ?= /tmp/votty-tests

release:
	$(ODIN) build . -out:votty -o:speed -vet -strict-style

debug:
	$(ODIN) build . -out:votty-debug -debug -vet -strict-style

check:
	$(ODIN) check . -vet -strict-style

# test sources live outside the repository
test:
	$(ODIN) test $(TESTS) -collection:votty=. -vet

clean:
	rm -f votty votty-debug

.PHONY: release debug check test clean
