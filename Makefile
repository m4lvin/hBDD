HOMEDIR = $(shell (cd && pwd))

CABALFLAGS = --reinstall --force-reinstalls --extra-include-dirs=$(HOMEDIR)/src/cudd-2.5.1/cudd --extra-include-dirs=$(HOMEDIR)/src/cudd-2.5.1/mtr --extra-include-dirs=$(HOMEDIR)/src/cudd-2.5.1/epd --extra-include-dirs=$(HOMEDIR)/src/cudd-2.5.1/st --extra-include-dirs=$(HOMEDIR)/src/cudd-2.5.1/util --extra-lib-dirs=$(HOMEDIR)/src/cudd-2.5.1/cudd --extra-lib-dirs=$(HOMEDIR)/src/cudd-2.5.1/mtr --extra-lib-dirs=$(HOMEDIR)/src/cudd-2.5.1/epd --extra-lib-dirs=$(HOMEDIR)/src/cudd-2.5.1/st --extra-lib-dirs=$(HOMEDIR)/src/cudd-2.5.1/util

install:
	make install-hBDD
	make install-hBDD-CUDD

install-hBDD:
	cabal install

install-hBDD-CUDD:
	mkdir -p $(HOMEDIR)/src
	rm -rf $(HOMEDIR)/src/cudd-2.5.1
	rm -rf $(HOMEDIR)/src/cudd-2.5.1.tar.gz
	wget ftp://vlsi.colorado.edu/pub/cudd-2.5.1.tar.gz -O $(HOMEDIR)/src/cudd-2.5.1.tar.gz
	tar xvf $(HOMEDIR)/src/cudd-2.5.1.tar.gz -C $(HOMEDIR)/src/
	patch $(HOMEDIR)/src/cudd-2.5.1/Makefile ./hBDD-CUDD/cudd-Makefile.patch
	cd $(HOMEDIR)/src/cudd-2.5.1/ && make
	cabal update
	cabal install $(CABALFLAGS)
	cd ./hBDD-CUDD && cabal install $(CABALFLAGS)
	rm -rf $(HOMEDIR)/src/hBDD
	@echo
	@echo !!! Do NOT delete the folder $(HOMEDIR)/src/cudd-2.5.1. !!!
	@echo !!! Your hBDD-CUDD is bound to it.                      !!!
	@echo

clean:
	cabal clean
